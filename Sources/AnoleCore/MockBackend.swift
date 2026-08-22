import Foundation

/// Dummy backend: no real device, everything succeeds after a short delay.
/// It is there to develop and test the interface without an iPhone plugged in,
/// and to check that the UI makes no assumption about the implementation.
public final class MockBackend: LocationBackend {
    public let identifier = "mock"
    public var displayName: String { "Local simulation (no device)" }

    private(set) public var lastLocation: Coordinate?
    private var prepared = false

    public let events: AsyncStream<BackendEvent>
    private let eventSink: AsyncStream<BackendEvent>.Continuation

    public init() {
        var sink: AsyncStream<BackendEvent>.Continuation!
        events = AsyncStream { sink = $0 }
        eventSink = sink
    }

    public func preflight() async -> [String] { [] }

    public func discoverDevices() async throws -> [DeviceInfo] {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return [
            DeviceInfo(
                udid: "00000000-MOCK000000000000",
                name: "Mock iPhone",
                productType: "iPhone17,3",
                osVersion: "27.0",
                connectionKind: .usb
            )
        ]
    }

    public func prepare(
        device: DeviceInfo,
        onProgress: @escaping @Sendable (PreparationStep) -> Void
    ) async throws {
        for step in [
            PreparationStep.checkingTooling,
            .discoveringDevice,
            .pairing,
            .mountingDeveloperImage,
            .startingTunnel,
            .connectingDeveloperServices,
            .ready,
        ] {
            onProgress(step)
            eventSink.yield(.health(.preparing(step)))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        prepared = true
        eventSink.yield(.health(.live(roundTripMillis: 0)))
    }

    public func setLocation(_ coordinate: Coordinate) async throws {
        guard prepared else { throw BackendError.notPrepared }
        guard coordinate.isValid else { throw BackendError.invalidCoordinate }
        lastLocation = coordinate
    }

    public func clearLocation(settlingNear: Coordinate? = nil) async throws {
        guard prepared else { throw BackendError.notPrepared }
        lastLocation = nil
    }

    public func shutdown() async {
        prepared = false
        lastLocation = nil
        eventSink.yield(.health(.idle))
    }
}
