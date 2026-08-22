import Testing
import Foundation
@testable import AnoleCore

@Suite("Speed settings")
struct SpeedSettingsTests {

    let origin = Coordinate(latitude: 37.7793, longitude: -122.4193)

    func straight(_ meters: Double) -> PathGeometry {
        PathGeometry([origin, origin.destination(bearingDegrees: 90, meters: meters)])!
    }

    func averageSpeed(_ schedule: TripSchedule) -> Double {
        schedule.geometry.length / schedule.duration
    }

    // MARK: Forced average speed

    @Test("The requested average is actually held")
    func honoursAverage() {
        let geometry = straight(10_000)
        for kmh in [20.0, 50.0, 90.0] {
            let settings = SpeedSettings(averageSpeed: kmh.kmhToMetersPerSecond)
            let schedule = TripSchedule.calibrated(
                geometry: geometry, mode: .driving,
                minimumSpeed: settings.minimumSpeed,
                targetDuration: settings.targetDuration(forDistance: geometry.length)
            )
            let measured = averageSpeed(schedule) * 3.6
            #expect(abs(measured - kmh) < 2, "asked \(kmh), got \(measured)")
        }
    }

    @Test("With no setting, the service duration is authoritative")
    func automaticKeepsServiceDuration() {
        let settings = SpeedSettings.automatic
        #expect(settings.isAutomatic)
        #expect(settings.targetDuration(forDistance: 10_000) == nil)
    }

    // MARK: Speed floor

    @Test("The floor raises the speed at steady state")
    func minimumRaisesCruise() {
        let geometry = straight(6000)
        let withoutFloor = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, targetDuration: 1200
        )
        let withFloor = TripSchedule.calibrated(
            geometry: geometry, mode: .driving,
            minimumSpeed: 15.0,
            targetDuration: 1200
        )
        #expect(withFloor.duration < withoutFloor.duration)
    }

    @Test("The floor prevents neither starting nor stopping")
    func minimumStillAllowsStops() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(3000), mode: .driving,
            minimumSpeed: 20.0,
            targetDuration: nil
        )
        // Start and destination stay at a standstill despite a high floor.
        #expect(schedule.sample(at: 0).speed == 0)
        #expect(schedule.sample(at: schedule.duration).speed == 0)
    }

    @Test("The floor respects a stop marked along the trip")
    func minimumRespectsStops() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(4000), mode: .driving,
            stops: [RouteStop(arcLength: 2000, duration: 15)],
            minimumSpeed: 20.0,
            targetDuration: nil
        )
        var stopped = false
        var elapsed = 0.0
        while elapsed <= schedule.duration {
            let fix = schedule.sample(at: elapsed)
            let inMiddle = fix.distanceTravelled > 100 && fix.distanceTravelled < 3900
            if fix.speed == 0 && inMiddle {
                stopped = true
                break
            }
            elapsed += 0.5
        }
        #expect(stopped, "the intermediate stop disappeared")
    }

    // MARK: Bounds

    @Test("No ceiling is imposed on the requested speed")
    func noCeilingImposed() {
        // A pedestrian at 200 km/h makes no physical sense, but it is a
        // deliberate user choice: the backend honors it instead of fixing it.
        let asked = 200.0.kmhToMetersPerSecond
        let settings = SpeedSettings(averageSpeed: asked).clamped(to: .walking)
        #expect(settings.averageSpeed == asked)
    }

    @Test("The backend ceiling is raised to honor a high speed")
    func raisesEngineCeiling() {
        let asked = 200.0.kmhToMetersPerSecond
        let settings = SpeedSettings(averageSpeed: asked)
        let ceiling = settings.speedCeiling(for: .walking)
        #expect(ceiling != nil)
        #expect(ceiling! > asked)
    }

    @Test("A reasonable speed leaves the mode ceiling in place")
    func keepsModeCeilingWhenModest() {
        let settings = SpeedSettings(averageSpeed: 30.0.kmhToMetersPerSecond)
        #expect(settings.speedCeiling(for: .driving) == nil)
    }

    @Test("A very high speed is actually reached")
    func reachesHighSpeed() {
        let geometry = straight(20_000)
        let asked = 200.0.kmhToMetersPerSecond
        let settings = SpeedSettings(averageSpeed: asked).clamped(to: .driving)
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving,
            minimumSpeed: settings.minimumSpeed,
            speedCeiling: settings.speedCeiling(for: .driving),
            targetDuration: settings.targetDuration(forDistance: geometry.length)
        )
        let measured = averageSpeed(schedule) * 3.6
        #expect(abs(measured - 200) < 5, "got \(measured) km/h")
    }

    @Test("A floor above the average is brought back down to the average")
    func clampsFloorToAverage() {
        let settings = SpeedSettings(
            averageSpeed: 10.0, minimumSpeed: 30.0
        ).clamped(to: .driving)
        #expect(settings.minimumSpeed <= settings.averageSpeed!)
    }

    @Test("A zero or negative average is rejected")
    func rejectsNonPositive() {
        #expect(SpeedSettings(averageSpeed: 0).targetDuration(forDistance: 1000) == nil)
        #expect(SpeedSettings(averageSpeed: -5).targetDuration(forDistance: 1000) == nil)
    }

    @Test("The km/h and m/s conversions are reciprocal")
    func conversions() {
        #expect(abs(50.0.kmhToMetersPerSecond - 13.888) < 0.01)
        #expect(abs(13.888.metersPerSecondToKmh - 50.0) < 0.01)
    }
}
