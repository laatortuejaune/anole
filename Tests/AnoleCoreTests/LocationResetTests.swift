import XCTest
import AnoleCore
import AnoleServices

final class LocationResetTests: XCTestCase {
    @MainActor
    func testFailedResetPreservesPositionForRetry() async throws {
        let backend = MockBackend()
        let model = TripModel(backend: backend)
        await model.refreshDevices()
        await model.prepare()
        let point = Coordinate(latitude: 37.82, longitude: -122.48)
        model.moveTo(point)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.pushedCoordinate == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.pushedCoordinate, point)

        await backend.shutdown()
        await model.resetEverything()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.pushedCoordinate, point)
        XCTAssertTrue(model.hasSomethingToReset)

        await model.prepare()
        await model.resetEverything()
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.pushedCoordinate)
        XCTAssertFalse(model.hasSomethingToReset)
    }
}
