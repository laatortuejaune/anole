// This file drives subprocesses, which iOS does not allow: the iPhone app talks
// to the device directly through the idevice library. The core therefore stays
// a single module, shared by both applications.
#if os(macOS)

import Foundation

/// Result of a finished subprocess.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }

    /// stdout when not empty, otherwise stderr: many Python tools write everything to stderr.
    public var combined: String {
        let out = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return err }
        if err.isEmpty { return out }
        return out + "\n" + err
    }
}

/// Subprocess execution, either as a single pass or as a long-running task.
public enum ProcessRunner {

    /// Runs a command and waits for it to finish.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Read both pipes concurrently: reading them in sequence can block if
        // one of them fills its buffer while we drain the other.
        async let outData = readToEnd(outPipe)
        async let errData = readToEnd(errPipe)

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM is a request. A child that ignores it - or a grandchild
            // still holding the pipe open - would keep the read alive well past
            // the deadline this watchdog exists to enforce.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        let out = await outData
        let err = await errData
        process.waitUntilExit()
        watchdog.cancel()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    /// Starts a long-running task (the tunnel) and streams its output lines.
    /// The returned `Process` must be kept by the caller so it can be killed.
    public static func launchStreaming(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                onLine(String(line))
            }
        }

        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        return process
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// Looks for an executable in the current PATH, plus the usual Homebrew locations.
    public static func which(_ name: String) -> URL? {
        var searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        // An app launched from the Finder inherits a minimal PATH.
        searchPaths.append(contentsOf: [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ])

        for path in searchPaths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

#endif
