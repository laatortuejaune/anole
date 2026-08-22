// This file drives subprocesses, which iOS does not allow: the iPhone app talks
// to the device directly through the idevice library. The core therefore stays
// a single module, shared by both applications.
#if os(macOS)

import Foundation

/// Two-way channel with a long-running process, one JSON line per message.
///
/// Each command carries a sequence number; the reply carrying the same number
/// wakes the caller. Messages without a number are spontaneous events
/// (progress, link health) and go out through `events`.
public actor NDJSONChannel {

    public enum ChannelError: Error, LocalizedError {
        case notRunning
        case processExited(Int32, String)
        case timeout(String)
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning:
                return "The helper is not running."
            case .processExited(let code, let detail):
                return "The helper stopped (code \(code)). \(detail)"
            case .timeout(let op):
                return "No reply from the helper for \"\(op)\"."
            case .decodingFailed(let line):
                return "Unreadable reply from the helper: \(line)"
            }
        }
    }

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]?

    private var process: Process?
    private var inputPipe: Pipe?
    private var buffer = Data()
    private var nextSequence = 1

    private var waiters: [Int: CheckedContinuation<Helper.Message, Error>] = [:]
    private var eventContinuation: AsyncStream<Helper.Message>.Continuation?
    private var logContinuation: AsyncStream<String>.Continuation?
    /// Last error output, to explain a premature exit.
    private var recentErrorOutput: [String] = []

    public let events: AsyncStream<Helper.Message>
    public let logs: AsyncStream<String>

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment

        var eventSink: AsyncStream<Helper.Message>.Continuation!
        events = AsyncStream { eventSink = $0 }
        var logSink: AsyncStream<String>.Continuation!
        logs = AsyncStream { logSink = $0 }

        eventContinuation = eventSink
        logContinuation = logSink
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    public func start() throws {
        guard process == nil else { return }

        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        if let environment {
            task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            Task { await self.ingest(data) }
        }

        // The helper redirects the pymobiledevice3 logs to stderr to keep stdout
        // strictly NDJSON. We relay them without ever interpreting them.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self.ingestErrorOutput(text) }
        }

        task.terminationHandler = { [weak self] finished in
            guard let self else { return }
            Task { await self.handleTermination(code: finished.terminationStatus) }
        }

        try task.run()
        process = task
        inputPipe = stdin
    }

    /// Sends a command and waits for the reply carrying the same number.
    @discardableResult
    public func request(
        _ make: (Int) -> Helper.Command,
        timeout: TimeInterval = 30
    ) async throws -> Helper.Message {
        guard isRunning, let inputPipe else { throw ChannelError.notRunning }

        let sequence = nextSequence
        nextSequence += 1
        let command = make(sequence)

        var line = try JSONEncoder().encode(command)
        line.append(0x0A)

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.failWaiter(sequence, with: ChannelError.timeout(command.op))
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            waiters[sequence] = continuation
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: line)
            } catch {
                waiters.removeValue(forKey: sequence)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Sends without waiting for a reply. Used for the location stream: waiting
    /// for every acknowledgement would build up lag.
    public func send(_ make: (Int) -> Helper.Command) throws {
        guard isRunning, let inputPipe else { throw ChannelError.notRunning }
        let sequence = nextSequence
        nextSequence += 1
        var line = try JSONEncoder().encode(make(sequence))
        line.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: line)
    }

    public func stop() {
        guard let process else { return }
        if process.isRunning {
            // Give a clean shutdown a chance: the helper has to release the
            // channel and the tunnel before it dies.
            try? send(Helper.Command.quit)
            process.terminate()
        }
        // NEVER read terminationStatus here. terminate() is asynchronous: the
        // process is still alive at this point, and asking for its exit code
        // then raises an Objective-C exception that Swift cannot catch, which
        // brings the application down. The real exit code arrives through
        // terminationHandler anyway.
        cleanUp(code: 0)
    }

    // MARK: - Internal

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            dispatch(lineData)
        }
    }

    private func dispatch(_ lineData: Data) {
        let message: Helper.Message
        do {
            message = try JSONDecoder().decode(Helper.Message.self, from: lineData)
        } catch {
            // A non-JSON line on stdout is a fault in the helper, not a reply:
            // we log it without breaking the session.
            logContinuation?.yield("[non-JSON stdout] " + String(decoding: lineData, as: UTF8.self))
            return
        }

        if let sequence = message.seq, let waiter = waiters.removeValue(forKey: sequence) {
            if message.isError {
                waiter.resume(throwing: ChannelError.processExited(0, message.text ?? message.code ?? "error"))
            } else {
                waiter.resume(returning: message)
            }
            return
        }
        eventContinuation?.yield(message)
    }

    private func ingestErrorOutput(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = String(line)
            recentErrorOutput.append(entry)
            if recentErrorOutput.count > 40 { recentErrorOutput.removeFirst() }
            logContinuation?.yield(entry)
        }
    }

    private func failWaiter(_ sequence: Int, with error: Error) {
        guard let waiter = waiters.removeValue(forKey: sequence) else { return }
        waiter.resume(throwing: error)
    }

    private func handleTermination(code: Int32) {
        cleanUp(code: code)
    }

    private func cleanUp(code: Int32) {
        let detail = recentErrorOutput.suffix(5).joined(separator: " | ")
        for (_, waiter) in waiters {
            waiter.resume(throwing: ChannelError.processExited(code, detail))
        }
        waiters.removeAll()

        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        buffer.removeAll()

        // Whoever is iterating these has to learn that nothing more is coming.
        // Without it, a helper that dies before announcing itself - unplugged
        // cable, Python traceback - left `for await` suspended forever: the
        // caller neither returned nor threw, and the interface sat on "Opening
        // tunnel" until it was quit.
        eventContinuation?.finish()
        logContinuation?.finish()
        eventContinuation = nil
        logContinuation = nil
    }
}

#endif
