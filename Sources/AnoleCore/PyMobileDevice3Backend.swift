// This file drives subprocesses, which iOS does not allow: the iPhone app talks
// to the device directly through the idevice library. The core therefore stays
// a single module, shared by both applications.
#if os(macOS)

import Foundation

/// Real backend: drives the persistent Python helper, which talks to the iPhone.
///
/// Division of roles:
///  - one-off, stateless operations (listing devices, checking developer mode,
///    mounting the image) go through the command line tool;
///  - the location stream goes through the helper, which keeps the channel open.
///
/// This split matters: the simulated location dies with the service channel, so
/// only a process that lives as long as the session can hold on to it.
public actor PyMobileDevice3Backend: LocationBackend {

    public nonisolated let identifier = "pymobiledevice3"
    public nonisolated var displayName: String { "pymobiledevice3 (USB)" }
    public nonisolated let events: AsyncStream<BackendEvent>

    private nonisolated let eventSink: AsyncStream<BackendEvent>.Continuation

    private let paths: Paths
    private var channel: NDJSONChannel?
    private var device: DeviceInfo?
    private var relayTask: Task<Void, Never>?
    private var logRelayTask: Task<Void, Never>?

    public init(paths: Paths = .default) {
        self.paths = paths
        var sink: AsyncStream<BackendEvent>.Continuation!
        events = AsyncStream { sink = $0 }
        eventSink = sink
    }

    // MARK: - Paths

    public struct Paths: Sendable {
        public var pythonExecutable: URL
        public var commandLineTool: URL
        public var helperScript: URL?

        public static let `default` = Paths(
            pythonExecutable: Self.home.appending(path: ".local/share/anole/venv/bin/python"),
            commandLineTool: Self.home.appending(path: ".local/share/anole/venv/bin/pymobiledevice3"),
            helperScript: Self.locateHelper()
        )

        private static var home: URL {
            URL(fileURLWithPath: NSHomeDirectory())
        }

        /// The helper is copied into the bundle at build time. When running from
        /// `.build` during development that bundle does not exist, so we fall
        /// back to the source tree.
        /// The helper is copied into the bundle at build time. When running
        /// from `.build` during development that bundle does not exist, so
        /// ANOLE_HELPER_PATH provides a way out.
        ///
        /// Note the absence of any hardcoded path: `#filePath` would have been
        /// convenient here, but the compiler expands it to an absolute path
        /// that ends up verbatim in the shipped binary, exposing the build
        /// machine's user name to anyone running `strings` on it.
        private static func locateHelper() -> URL? {
            if let bundled = Bundle.main.url(forResource: "anoled", withExtension: "py") {
                return bundled
            }
            if let override = ProcessInfo.processInfo.environment["ANOLE_HELPER_PATH"] {
                let url = URL(fileURLWithPath: override)
                if FileManager.default.isReadableFile(atPath: url.path) { return url }
            }
            // Last resort: alongside the running executable, which covers a
            // plain `swift run` from a checkout.
            let sibling = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appending(path: "Helper/anoled.py")
            return FileManager.default.isReadableFile(atPath: sibling.path) ? sibling : nil
        }
    }

    // MARK: - Preflight checks

    public func preflight() async -> [String] {
        var problems: [String] = []

        if !FileManager.default.isExecutableFile(atPath: paths.pythonExecutable.path) {
            problems.append("Python environment missing. Run Scripts/setup-backend.sh.")
        }
        if !FileManager.default.isExecutableFile(atPath: paths.commandLineTool.path) {
            problems.append("pymobiledevice3 missing. Run Scripts/setup-backend.sh.")
        }
        if paths.helperScript == nil {
            problems.append("Helper anoled.py not found.")
        }
        return problems
    }

    // MARK: - Devices

    public func discoverDevices() async throws -> [DeviceInfo] {
        let result = try await runTool(["usbmux", "list"], timeout: 20)
        guard result.succeeded else {
            throw BackendError.commandFailed("usbmux list", result.exitCode, result.combined)
        }
        return try DeviceListing.parse(result.standardOutput)
    }

    // MARK: - Preparation

    public func prepare(
        device: DeviceInfo,
        onProgress: @escaping @Sendable (PreparationStep) -> Void
    ) async throws {
        self.device = device

        func step(_ value: PreparationStep) {
            onProgress(value)
            eventSink.yield(.health(.preparing(value)))
        }

        step(.checkingTooling)
        let problems = await preflight()
        if let first = problems.first { throw BackendError.toolingMissing(first) }

        // Developer mode can only be enabled from the device itself.
        step(.discoveringDevice)
        let modeResult = try await runTool(targeted(["amfi", "developer-mode-status"]), timeout: 20)
        // Only a run that succeeded says anything. A failed one leaves the
        // state unknown, and finding "false" somewhere in an error message
        // would report developer mode as off when it may well be on - while
        // the mount just below fails with a clear message if it truly is.
        if modeResult.succeeded, modeResult.standardOutput.lowercased().contains("false") {
            throw BackendError.developerModeDisabled
        }

        // The developer disk image unmounts every time the iPhone reboots.
        step(.mountingDeveloperImage)
        try await ensureDeveloperImageMounted()

        step(.startingTunnel)
        try await startHelper()

        step(.connectingDeveloperServices)
        step(.ready)
    }

    /// Adds `--udid` when a device is selected.
    ///
    /// Without it these checks answer for whichever device the tool happens to
    /// pick, which is the wrong one as soon as two iPhones are plugged in - and
    /// the helper below was already being told which one to use.
    private func targeted(_ arguments: [String]) -> [String] {
        guard let udid = device?.udid else { return arguments }
        return arguments + ["--udid", udid]
    }

    private func ensureDeveloperImageMounted() async throws {
        let listed = try await runTool(targeted(["mounter", "list"]), timeout: 30)
        if listed.succeeded, listed.standardOutput.contains("\"IsMounted\": true") {
            return
        }

        // Mounting requires Internet access: the image is signed by Apple's
        // servers for this precise device.
        let mounted = try await runTool(targeted(["mounter", "auto-mount"]), timeout: 300)
        guard mounted.succeeded else {
            throw BackendError.developerImageUnavailable(mounted.combined)
        }
    }

    private func startHelper() async throws {
        guard let helperScript = paths.helperScript else {
            throw BackendError.helperMissing
        }

        await stopHelper()

        var arguments = [helperScript.path]
        if let udid = device?.udid {
            arguments.append(contentsOf: ["--udid", udid])
        }

        let channel = NDJSONChannel(
            executable: paths.pythonExecutable,
            arguments: arguments,
            // Unbuffered Python output: without it the NDJSON lines would
            // arrive in blocks and the first message would keep us waiting.
            environment: ["PYTHONUNBUFFERED": "1"]
        )
        self.channel = channel
        try await channel.start()

        // Only the log relay starts now. Two tasks iterating the same
        // AsyncStream share it: whichever asks first takes the message, so the
        // "ready" - or worse, the "error" explaining why the tunnel failed -
        // landed in the relay while `prepare()` waited for something that had
        // already been delivered elsewhere. The event relay therefore starts
        // once the handshake is over, and until then `waitForReady` reads the
        // stream alone.
        logRelayTask = Task { [weak self] in
            await self?.relayLogs(from: channel)
        }

        // The helper announces "ready" once the tunnel and the channel are open.
        try await waitForReady(on: channel)

        relayTask = Task { [weak self] in
            await self?.relayEvents(from: channel)
        }
    }

    /// Waits for the helper to announce itself, or gives up out loud.
    ///
    /// The deadline is raced against the read rather than checked inside it: a
    /// test at the bottom of `for await` only runs when a message arrives, so a
    /// helper that was alive but silent - a tunnel stuck mid-handshake - was
    /// never timed out at all. `NDJSONChannel.request` already does it this way.
    private func waitForReady(on channel: NDJSONChannel, timeout: TimeInterval = 90) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await message in channel.events {
                    if message.event == "ready" { return }
                    if message.event == "error" {
                        throw BackendError.tunnelFailed(message.text ?? message.code ?? "unknown error")
                    }
                }
                // The stream ended: the helper died before saying anything.
                throw BackendError.tunnelFailed("The helper stopped before the tunnel was open.")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BackendError.tunnelFailed("No reply from the helper within the time limit.")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Helper logs, relayed from the moment the process starts.
    ///
    /// Kept apart from the events so it can run during the handshake: a tunnel
    /// that fails explains itself on stderr, and that is exactly when the user
    /// needs to see it.
    private func relayLogs(from channel: NDJSONChannel) async {
        for await line in channel.logs {
            eventSink.yield(.log(line))
        }
    }

    /// Translates helper messages into states for the interface.
    private func relayEvents(from channel: NDJSONChannel) async {
        for await message in channel.events {
            switch message.event {
            case "health":
                switch message.state {
                case "live": eventSink.yield(.health(.live(roundTripMillis: nil)))
                case "lost": eventSink.yield(.health(.lost(message.text ?? "channel closed")))
                case "idle": eventSink.yield(.health(.idle))
                default: break
                }
            case "ok":
                if let rtt = message.roundTripMillis {
                    eventSink.yield(.health(.live(roundTripMillis: rtt)))
                }
            case "error":
                eventSink.yield(.health(.degraded(message.text ?? message.code ?? "error")))
            default:
                break
            }
        }
    }

    // MARK: - Locations

    public func setLocation(_ coordinate: Coordinate) async throws {
        guard coordinate.isValid else { throw BackendError.invalidCoordinate }
        guard let channel else { throw BackendError.notPrepared }

        // Send without waiting for the acknowledgement: the helper only keeps
        // the last requested location. Waiting here would build up lag as soon
        // as the interface pushes faster than the device applies.
        do {
            try await channel.send { Helper.Command.set(seq: $0, coordinate) }
        } catch {
            eventSink.yield(.health(.lost(error.localizedDescription)))
            throw error
        }
    }

    public func clearLocation(settlingNear: Coordinate? = nil) async throws {
        guard let channel else { throw BackendError.notPrepared }
        _ = try await channel.request({ Helper.Command.clear(seq: $0, near: settlingNear) }, timeout: 30)
    }

    /// Measures the round trip time, to tune the send rate.
    public func measureRoundTrip(samples: Int = 20) async throws -> (p50: Double, p95: Double) {
        guard let channel else { throw BackendError.notPrepared }
        let reply = try await channel.request({ Helper.Command.bench(seq: $0, samples: samples) }, timeout: 60)
        return (reply.p50 ?? 0, reply.p95 ?? 0)
    }

    // MARK: - Shutdown

    public func shutdown() async {
        await stopHelper()
        eventSink.yield(.health(.idle))
    }

    private func stopHelper() async {
        relayTask?.cancel()
        relayTask = nil
        logRelayTask?.cancel()
        logRelayTask = nil
        if let channel { await channel.stop() }
        channel = nil
    }

    // MARK: - Command line tool

    private func runTool(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: paths.commandLineTool,
            arguments: arguments,
            timeout: timeout
        )
    }
}

#endif
