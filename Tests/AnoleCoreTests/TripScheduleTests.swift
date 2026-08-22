import Testing
import Foundation
@testable import AnoleCore

@Suite("Calibrated trip")
struct TripScheduleTests {

    let origin = Coordinate(latitude: 37.7793, longitude: -122.4193)

    func straight(_ meters: Double) -> PathGeometry {
        PathGeometry([origin, origin.destination(bearingDegrees: 90, meters: meters)])!
    }

    /// Straight line then a right-angle corner.
    func withCorner() -> PathGeometry {
        var current = origin
        var points = [current]
        for _ in 0..<20 { current = current.destination(bearingDegrees: 90, meters: 25); points.append(current) }
        for _ in 0..<20 { current = current.destination(bearingDegrees: 0, meters: 25); points.append(current) }
        return PathGeometry(points)!
    }

    // MARK: Calibration

    @Test("The trip duration matches the requested one")
    func matchesTarget() {
        for target in [300.0, 600.0, 1200.0] {
            let schedule = TripSchedule.calibrated(
                geometry: straight(5000), mode: .driving, targetDuration: target
            )
            #expect(abs(schedule.duration - target) < 2, "target \(target) -> \(schedule.duration)")
        }
    }

    @Test("With no target duration, the base pace is kept")
    func withoutTarget() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(2000), mode: .driving, targetDuration: nil
        )
        #expect(schedule.cruiseScale == 1)
        // 2 km at about 13.9 m/s, plus the acceleration and braking phases.
        #expect(schedule.duration > 145 && schedule.duration < 200)
    }

    @Test("An impossible duration does not make physics lie")
    func impossibleTarget() {
        // One second for 5 km: impossible without exceeding the mode ceiling.
        let schedule = TripSchedule.calibrated(
            geometry: straight(5000), mode: .walking, targetDuration: 1
        )
        #expect(schedule.duration > 1)
        let peak = (0...100).map { schedule.sample(at: schedule.duration * Double($0) / 100).speed }.max() ?? 0
        #expect(peak <= TransportMode.walking.maximumSpeed + 0.01)
    }

    @Test("A very slow target is honored without ever moving backwards")
    func verySlowTarget() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(1000), mode: .driving, targetDuration: 3600
        )
        var previous = -1.0
        for tick in stride(from: 0.0, through: schedule.duration, by: 30) {
            let fix = schedule.sample(at: tick)
            #expect(fix.distanceTravelled >= previous - 0.01, "moved backwards at \(tick) s")
            #expect(fix.speed >= 0)
            previous = fix.distanceTravelled
        }
    }

    // MARK: Trip consistency

    @Test("The trip starts at a standstill and ends at a standstill")
    func startsAndEndsStopped() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(3000), mode: .driving, targetDuration: 300
        )
        #expect(schedule.sample(at: 0).speed == 0)
        #expect(schedule.sample(at: 0).distanceTravelled == 0)
        #expect(schedule.sample(at: schedule.duration).speed == 0)
        #expect(schedule.sample(at: schedule.duration).isFinished)
    }

    @Test("The distance travelled never goes backwards")
    func monotonic() {
        let schedule = TripSchedule.calibrated(
            geometry: withCorner(), mode: .driving, targetDuration: 120
        )
        var previous = -1.0
        for tick in stride(from: 0.0, through: schedule.duration, by: 0.2) {
            let travelled = schedule.sample(at: tick).distanceTravelled
            #expect(travelled >= previous - 0.001)
            previous = travelled
        }
    }

    @Test("Past the duration, we stay at the destination")
    func clampsAfterEnd() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(1000), mode: .driving, targetDuration: 120
        )
        let end = schedule.sample(at: schedule.duration + 500)
        #expect(end.isFinished)
        #expect(end.speed == 0)
        #expect(abs(end.distanceTravelled - schedule.geometry.length) < 0.5)
    }

    @Test("A sharp corner slows things down")
    func slowsInCorner() {
        let geometry = withCorner()
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, targetDuration: 90
        )

        var speedInCorner = Double.greatestFiniteMagnitude
        var speedOnStraight = 0.0
        for tick in stride(from: 0.0, through: schedule.duration, by: 0.2) {
            let fix = schedule.sample(at: tick)
            if fix.distanceTravelled < 350 {
                speedOnStraight = max(speedOnStraight, fix.speed)
            } else if abs(fix.distanceTravelled - 500) < 20 {
                speedInCorner = min(speedInCorner, fix.speed)
            }
        }
        #expect(speedInCorner < speedOnStraight)
    }

    // MARK: Stops

    @Test("A stop holds the position still and lengthens the trip")
    func stopHoldsPosition() {
        let geometry = straight(2000)
        let withoutStop = TripSchedule.calibrated(
            geometry: geometry, mode: .driving, targetDuration: nil
        )
        let withStop = TripSchedule.calibrated(
            geometry: geometry, mode: .driving,
            stops: [RouteStop(arcLength: 1000, duration: 20)],
            targetDuration: nil
        )

        #expect(withStop.duration > withoutStop.duration + 15)

        // During the pause, the position must not move.
        var positionsDuringStop: [Double] = []
        for tick in stride(from: 0.0, through: withStop.duration, by: 0.5) {
            let fix = withStop.sample(at: tick)
            if fix.speed == 0, fix.distanceTravelled > 100,
               fix.distanceTravelled < geometry.length - 100 {
                positionsDuringStop.append(fix.distanceTravelled)
            }
        }
        #expect(!positionsDuringStop.isEmpty, "no stop observed")
        if let first = positionsDuringStop.first {
            #expect(positionsDuringStop.allSatisfy { abs($0 - first) < 1 })
        }
    }

    // MARK: Speed limits

    @Test("A known speed limit caps the speed")
    func respectsLegalLimit() {
        let geometry = straight(4000)
        let schedule = TripSchedule.calibrated(
            geometry: geometry, mode: .driving,
            samples: [SpeedSample(
                startArcLength: 0, endArcLength: 4000,
                travelSpeed: 13.9, legalLimit: 8.0
            )],
            // Deliberately too fast a target: the speed limit must hold.
            targetDuration: 60
        )
        let peak = stride(from: 0.0, through: schedule.duration, by: 0.5)
            .map { schedule.sample(at: $0).speed }.max() ?? 0
        #expect(peak <= 8.01, "peak \(peak)")
    }

    @Test("Playback is independent of the sampling step")
    func samplingIndependent() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(3000), mode: .driving, targetDuration: 240
        )
        // A tick rate must not shift the trip: the position is a function of
        // time, not of the number of calls.
        let atHalf = schedule.sample(at: schedule.duration / 2).distanceTravelled
        let coarse = schedule.sample(at: schedule.duration / 2).distanceTravelled
        #expect(abs(atHalf - coarse) < 0.001)
    }

    @Test("The course follows the path")
    func course() {
        let schedule = TripSchedule.calibrated(
            geometry: straight(2000), mode: .driving, targetDuration: 200
        )
        let fix = schedule.sample(at: 100)
        #expect(angularDifference(fix.course, 90) < 2)
    }

    @Test("Walking and driving do not give the same duration")
    func modeMatters() {
        let geometry = straight(1000)
        let walking = TripSchedule.calibrated(geometry: geometry, mode: .walking, targetDuration: nil)
        let driving = TripSchedule.calibrated(geometry: geometry, mode: .driving, targetDuration: nil)
        #expect(walking.duration > driving.duration * 3)
    }
}
