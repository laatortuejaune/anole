import Testing
import Foundation
@testable import AnoleCore

@Suite("Pace by mode")
struct CyclingSpeedTests {

    let origin = Coordinate(latitude: 37.7793, longitude: -122.4193)

    func line(_ meters: Double) -> [Coordinate] {
        [origin, origin.destination(bearingDegrees: 90, meters: meters)]
    }

    /// A 10 km route as the service would return it.
    ///
    /// The service reports a duration computed with ITS own pace: walking for
    /// a walking route, driving for a driving route. Cycling is the only case
    /// where the two differ, since it rides a walking route, and that is
    /// precisely where the bug comes from.
    func plan(mode: TransportMode) -> RoutePlan {
        let basis: TransportMode = mode == .cycling ? .walking : mode
        return RoutePlan(
            id: "test",
            name: "Test",
            coordinates: line(10_000),
            distance: 10_000,
            expectedTravelTime: 10_000 / basis.defaultSpeed,
            mode: mode,
            routingBasis: basis
        )
    }

    @Test("Cycling really runs at about 30 km/h, not at a walking pace")
    func cyclingIsNotWalking() throws {
        // Observed bug: cycling moved at 5 km/h. The duration reported by the
        // service was the walking one and completely overrode the mode pace.
        let route = plan(mode: .cycling)
        let geometry = try #require(route.geometry)
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .cycling, targetDuration: route.targetDuration
        )

        let averageSpeed = geometry.length / schedule.duration
        #expect(averageSpeed > 7.0, "average \(averageSpeed * 3.6) km/h, too slow")
        #expect(averageSpeed < 9.5, "average \(averageSpeed * 3.6) km/h, too fast")
    }

    @Test("The cycling duration is much shorter than the reported walking duration")
    func cyclingIsFasterThanWalking() {
        let route = plan(mode: .cycling)
        #expect(route.targetDuration < route.expectedTravelTime / 4)
    }

    @Test("Walking and driving keep the reported duration as is")
    func othersKeepAnnouncedDuration() {
        for mode in [TransportMode.walking, .driving] {
            let route = plan(mode: mode)
            #expect(route.targetDuration == route.expectedTravelTime, "\(mode)")
        }
    }

    @Test("Each mode has a pace distinct from the others")
    func modesDiffer() throws {
        var averages: [TransportMode: Double] = [:]
        for mode in TransportMode.allCases {
            let route = plan(mode: mode)
            let geometry = try #require(route.geometry)
            let schedule = TripSchedule.calibrated(
                geometry: geometry, mode: mode, targetDuration: route.targetDuration
            )
            averages[mode] = geometry.length / schedule.duration
        }

        let walking = try #require(averages[.walking])
        let cycling = try #require(averages[.cycling])
        let driving = try #require(averages[.driving])

        #expect(walking < cycling, "cycling must be faster than walking")
        #expect(cycling < driving, "driving must be faster than cycling")
        // A bicycle goes about six times faster than a pedestrian.
        #expect(cycling / walking > 4)
    }

    @Test("The nominal paces match the expected speeds")
    func nominalSpeeds() {
        #expect(abs(TransportMode.walking.defaultSpeed * 3.6 - 5) < 1)
        #expect(abs(TransportMode.cycling.defaultSpeed * 3.6 - 30) < 1)
        #expect(abs(TransportMode.driving.defaultSpeed * 3.6 - 50) < 1)
    }

    @Test("Each mode ceiling stays above its nominal pace")
    func ceilingsAboveNominal() {
        for mode in TransportMode.allCases {
            #expect(mode.maximumSpeed > mode.defaultSpeed, "\(mode)")
        }
    }
}
