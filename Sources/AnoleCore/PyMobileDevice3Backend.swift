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
        let modeResult = try await runTool(["amfi", "developer-mode-status"], timeout: 20)
        if modeResult.combined.contains("false") {
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

    private func ensureDeveloperImageMounted() async throws {
        let listed = try await runTool(["mounter", "list"], timeout: 30)
        if listed.succeeded, listed.standardOutput.contains("\"IsMounted\": true") {
            return
        }

        // Mounting requires Internet access: the image is signed by Apple's
        // servers for this precise device.
        let mounted = try await runTool(["mounter", "auto-mount"], timeout: 300)
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

        relayTask = Task { [weak self] in
            await self?.relayEvents(from: channel)
        }

        // The helper announces "ready" once the tunnel and the channel are open.
        try await waitForReady(on: channel)
    }

    private func waitForReady(on channel: NDJSONChannel, timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        for await message in channel.events {
            if message.event == "ready" { return }
            if message.event == "error" {
                throw BackendError.tunnelFailed(message.text ?? message.code ?? "unknown error")
            }
            if Date() > deadline { break }
        }
        throw BackendError.tunnelFailed("No reply from the helper within the time limit.")
    }

    /// Translates helper messages into states for the interface.
    private func relayEvents(from channel: NDJSONChannel) async {
        async let logRelay: Void = {
            for await line in channel.logs {
                eventSink.yield(.log(line))
            }
        }()

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
        await logRelay
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
