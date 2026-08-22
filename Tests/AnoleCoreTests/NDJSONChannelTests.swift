import Testing
import Foundation
@testable import AnoleCore

@Suite("Helper channel")
struct NDJSONChannelTests {

    /// A fake helper: answers in NDJSON then stays alive.
    static func fakeHelper(_ body: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anole-fake-\(UUID().uuidString).sh")
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("Stopping a channel that is still running does not bring the app down")
    func stopWhileRunning() async throws {
        // This is the exact scenario of the observed crash: terminate() is
        // asynchronous, the process is still alive when stop() returns.
        let script = try Self.fakeHelper("""
        echo '{"ev":"ready","udid":"test"}'
        while true; do sleep 1; done
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let channel = NDJSONChannel(executable: script, arguments: [])
        try await channel.start()
        #expect(await channel.isRunning)

        await channel.stop()
        #expect(!(await channel.isRunning))
    }

    @Test("Stopping twice in a row has no effect")
    func doubleStop() async throws {
        let script = try Self.fakeHelper("while true; do sleep 1; done")
        defer { try? FileManager.default.removeItem(at: script) }

        let channel = NDJSONChannel(executable: script, arguments: [])
        try await channel.start()
        await channel.stop()
        await channel.stop()
        #expect(!(await channel.isRunning))
    }

    @Test("Stopping a channel that was never started has no effect")
    func stopNeverStarted() async {
        let channel = NDJSONChannel(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: []
        )
        await channel.stop()
        #expect(!(await channel.isRunning))
    }

    @Test("Helper events are decoded correctly")
    func decodesEvents() async throws {
        let script = try Self.fakeHelper("""
        echo '{"ev":"progress","step":"startingTunnel"}'
        echo '{"ev":"ready","udid":"ABC","ios":"27.0"}'
        while true; do sleep 1; done
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let channel = NDJSONChannel(executable: script, arguments: [])
        try await channel.start()

        var seen: [String] = []
        for await message in await channel.events {
            seen.append(message.event)
            if message.event == "ready" {
                #expect(message.udid == "ABC")
                #expect(message.iosVersion == "27.0")
                break
            }
        }
        await channel.stop()
        #expect(seen == ["progress", "ready"])
    }

    @Test("A non-JSON line does not break the session")
    func toleratesGarbage() async throws {
        let script = try Self.fakeHelper("""
        echo 'this is not json'
        echo '{"ev":"ready","udid":"ABC"}'
        while true; do sleep 1; done
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let channel = NDJSONChannel(executable: script, arguments: [])
        try await channel.start()

        for await message in await channel.events where message.event == "ready" {
            #expect(message.udid == "ABC")
            break
        }
        await channel.stop()
    }
}
