// This file drives subprocesses, which iOS does not allow: the iPhone app talks
// to the device directly through the idevice library. The core therefore stays
// a single module, shared by both applications.
#if os(macOS)

import Foundation

/// Messages exchanged with the Python helper, one JSON line per message.
///
/// The helper keeps the tunnel and the developer service channel open for the
/// whole session. Apple's protocol forces this: the simulated location dies
/// with the channel, so restarting a command line tool on every movement would
/// lose the location every time.
public enum Helper {

    /// Mac -> Python.
    public struct Command: Encodable, Sendable {
        public var op: String
        public var seq: Int
        public var lat: Double?
        public var lon: Double?
        public var udid: String?
        public var near: Point?
        public var n: Int?

        public struct Point: Encodable, Sendable {
            public var lat: Double
            public var lon: Double

            public init(_ coordinate: Coordinate) {
                lat = coordinate.latitude
                lon = coordinate.longitude
            }
        }

        public init(op: String, seq: Int) {
            self.op = op
            self.seq = seq
        }

        public static func ping(seq: Int) -> Command {
            Command(op: "ping", seq: seq)
        }

        public static func prepare(seq: Int, udid: String?) -> Command {
            var command = Command(op: "prepare", seq: seq)
            command.udid = udid
            return command
        }

        public static func set(seq: Int, _ coordinate: Coordinate) -> Command {
            var command = Command(op: "set", seq: seq)
            command.lat = coordinate.latitude
            command.lon = coordinate.longitude
            return command
        }

        public static func clear(seq: Int, near: Coordinate?) -> Command {
            var command = Command(op: "clear", seq: seq)
            command.near = near.map(Point.init)
            return command
        }

        public static func bench(seq: Int, samples: Int) -> Command {
            var command = Command(op: "bench", seq: seq)
            command.n = samples
            return command
        }

        public static func quit(seq: Int) -> Command {
            Command(op: "quit", seq: seq)
        }
    }

    /// Python -> Mac.
    public struct Message: Decodable, Sendable {
        public var event: String
        public var seq: Int?
        public var step: String?
        public var udid: String?
        public var iosVersion: String?
        public var roundTripMillis: Double?
        public var code: String?
        public var text: String?
        public var state: String?
        public var p50: Double?
        public var p95: Double?
        public var worst: Double?

        enum CodingKeys: String, CodingKey {
            case event = "ev"
            case seq
            case step
            case udid
            case iosVersion = "ios"
            case roundTripMillis = "rtt_ms"
            case code
            case text = "msg"
            case state
            case p50
            case p95
            case worst = "max"
        }

        /// Reply to a specific command, as opposed to a spontaneous event.
        public var isReply: Bool { seq != nil }
        public var isError: Bool { event == "error" }
    }
}

#endif
