import Foundation

/// Preparation step, reported to the UI to show progress.
/// Deliberately descriptive rather than prescriptive: not every backend goes
/// through the same steps (the Rust backend will handle its tunnel internally).
public enum PreparationStep: Sendable, Equatable {
    case checkingTooling
    case discoveringDevice
    case pairing
    case mountingDeveloperImage
    case startingTunnel
    case connectingDeveloperServices
    case ready
    case message(String)

    public var label: String {
        switch self {
        case .checkingTooling: return "Checking tooling"
        case .discoveringDevice: return "Detecting device"
        case .pairing: return "Pairing"
        case .mountingDeveloperImage: return "Mounting developer disk image"
        case .startingTunnel: return "Opening tunnel"
        case .connectingDeveloperServices: return "Connecting to developer services"
        case .ready: return "Ready"
        case .message(let text): return text
        }
    }
}

/// Backend errors are the numbered ones from `AnoleError`.
public typealias BackendError = AnoleError

/// Link health, pushed continuously to the interface.
public enum BackendHealth: Sendable, Equatable {
    case idle
    case preparing(PreparationStep)
    /// Channel open, locations applied. `roundTripMillis` is used to tune the rate.
    case live(roundTripMillis: Double?)
    /// The link still answers, but poorly: warn without shutting everything down.
    case degraded(String)
    /// Tunnel or channel down: the device has been returned to its real location.
    case lost(String)

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .preparing(let step): return step.label
        case .live(let rtt):
            guard let rtt else { return "Connected" }
            return String(format: "Connected - %.0f ms", rtt)
        case .degraded(let reason): return "Unstable: \(reason)"
        case .lost(let reason): return "Link lost: \(reason)"
        }
    }
}

public enum BackendEvent: Sendable {
    case health(BackendHealth)
    case log(String)
}

/// The single contract between the interface and the backend that talks to the iPhone.
///
/// Two implementations are planned:
///  - `PyMobileDevice3Backend`: drives the pymobiledevice3 CLI in a subprocess.
///  - `IDeviceBackend` (upcoming): links the Rust lib jkcoxson/idevice through its C bindings.
///
/// The UI must NEVER know anything beyond this protocol.
public protocol LocationBackend: AnyObject {
    /// Short identifier, shown in the settings.
    var identifier: String { get }
    var displayName: String { get }

    /// Stream of state and logs. The interface subscribes to it to show a
    /// banner, without ever querying the backend.
    var events: AsyncStream<BackendEvent> { get }

    /// Checks that the machine prerequisites are there (binaries, libs, permissions).
    /// Returns a list of readable problems; empty if all is well.
    func preflight() async -> [String]

    func discoverDevices() async throws -> [DeviceInfo]

    /// Puts the device in a state where it can receive simulated locations.
    /// Idempotent: calling it twice must not break the state.
    func prepare(device: DeviceInfo, onProgress: @escaping @Sendable (PreparationStep) -> Void) async throws

    /// Callable at high frequency. The implementation must never let a queue
    /// build up: if the device has not finished applying the previous location,
    /// the intermediate locations are dropped.
    /// A transient loss goes through `events`, not through a thrown error.
    func setLocation(_ coordinate: Coordinate) async throws

    /// `settlingNear` is a point close to the real location, set just before
    /// stopping. Without it, the device can stay stuck for a long while on the
    /// last simulated location before it finds the real GPS again.
    func clearLocation(settlingNear: Coordinate?) async throws

    /// Releases tunnel and subprocesses.
    func shutdown() async
}

public extension LocationBackend {
    var displayName: String { identifier }
}
