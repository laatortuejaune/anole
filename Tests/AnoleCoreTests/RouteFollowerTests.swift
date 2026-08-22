import Testing
import Foundation
@testable import AnoleCore

@Suite("Route following")
struct RouteFollowerTests {

    /// Straight path heading east, `count` points spaced `spacing` meters apart.
    func straightLine(
        count: Int,
        spacing: Double,
        speedLimit: Double? = nil
    ) -> [RoutePoint] {
        var start = Coordinate(latitude: 37.7793, longitude: -122.4193)
        var points: [RoutePoint] = [RoutePoint(coordinate: start, speedLimit: speedLimit)]
        for _ in 1..<count {
            start = start.destination(bearingDegrees: 90, meters: spacing)
            points.append(RoutePoint(coordinate: start, speedLimit: speedLimit))
        }
        return points
    }

    /// Runs the simulation through to the destination, with a safety guard.
    @discardableResult
    func runToEnd(_ follower: RouteFollower, interval: TimeInterval = 1.0, maxTicks: Int = 20_000) -> (ticks: Int, last: RouteFix) {
        var last = follower.initialFix()
        var ticks = 0
        while !last.isFinished, ticks < maxTicks {
            last = follower.advance(by: interval)
            ticks += 1
        }
        return (ticks, last)
    }

    @Test("A path with fewer than two points is rejected")
    func rejectsTooShort() {
        #expect(RouteFollower(coordinates: [], mode: .driving) == nil)
        #expect(RouteFollower(
            coordinates: [Coordinate(latitude: 37.7793, longitude: -122.4193)],
            mode: .driving
        ) == nil)
    }

    @Test("The total distance matches the sum of the segments")
    func totalDistance() throws {
        let path = straightLine(count: 11, spacing: 100)
        let follower = try #require(RouteFollower(path: path, mode: .driving))
        #expect(abs(follower.totalDistance - 1000) < 1)
    }

    @Test("The trip reaches the end and stops there")
    func reachesTheEnd() throws {
        let path = straightLine(count: 51, spacing: 20, speedLimit: 13.9)
        let follower = try #require(RouteFollower(path: path, mode: .driving))

        let (ticks, last) = runToEnd(follower)
        #expect(last.isFinished)
        #expect(ticks < 500)
        #expect(abs(last.distanceTravelled - follower.totalDistance) < 0.1)
        #expect(last.distanceRemaining < 0.1)
    }

    @Test("The start happens from a standstill, then the speed builds up gradually")
    func acceleratesFromStandstill() throws {
        let path = straightLine(count: 101, spacing: 20, speedLimit: 13.9)
        let follower = try #require(RouteFollower(path: path, mode: .driving))

        #expect(follower.initialFix().speed == 0)

        let first = follower.advance(by: 1.0)
        let second = follower.advance(by: 1.0)

        // Acceleration capped at 1.8 m/s2: no jump to the target speed.
        #expect(first.speed > 0)
        #expect(first.speed <= 1.81)
        #expect(second.speed > first.speed)
    }

    @Test("The arrival happens at a near-zero speed")
    func decelerCloseToArrival() throws {
        let path = straightLine(count: 51, spacing: 20, speedLimit: 13.9)
        let follower = try #require(RouteFollower(path: path, mode: .driving))

        let (_, last) = runToEnd(follower)
        #expect(last.speed < 2.5)
    }

    @Test("The speed limit of the segment is respected")
    func respectsSpeedLimit() throws {
        let limit = 8.0
        let path = straightLine(count: 201, spacing: 20, speedLimit: limit)
        let follower = try #require(RouteFollower(path: path, mode: .driving))

        var peak = 0.0
        var fix = follower.initialFix()
        while !fix.isFinished {
            fix = follower.advance(by: 1.0)
            peak = max(peak, fix.speed)
        }
        #expect(peak <= limit + 0.01)
        // The cruising speed must actually be reached, otherwise the test proves nothing.
        #expect(peak > limit - 1.0)
    }

    @Test("A pedestrian does not travel at highway speed")
    func modeCapsSpeed() throws {
        // 90 km/h limit along the path, but we are moving on foot.
        let path = straightLine(count: 201, spacing: 20, speedLimit: 25.0)
        let follower = try #require(RouteFollower(path: path, mode: .walking))

        var peak = 0.0
        var fix = follower.initialFix()
        var ticks = 0
        while !fix.isFinished, ticks < 20_000 {
            fix = follower.advance(by: 1.0)
            peak = max(peak, fix.speed)
            ticks += 1
        }
        #expect(peak <= TransportMode.walking.maximumSpeed + 0.01)
    }

    @Test("With no known limit, we fall back to the mode speed")
    func fallsBackToModeSpeed() throws {
        let path = straightLine(count: 201, spacing: 20, speedLimit: nil)
        let follower = try #require(RouteFollower(path: path, mode: .cycling))

        var peak = 0.0
        var fix = follower.initialFix()
        var ticks = 0
        while !fix.isFinished, ticks < 20_000 {
            fix = follower.advance(by: 1.0)
            peak = max(peak, fix.speed)
            ticks += 1
        }
        #expect(abs(peak - TransportMode.cycling.defaultSpeed) < 0.2)
    }

    @Test("A sharp corner slows things down")
    func slowsInSharpCorner() throws {
        // Straight line to the east, then a right angle to the north.
        var coordinate = Coordinate(latitude: 37.7793, longitude: -122.4193)
        var path: [RoutePoint] = [RoutePoint(coordinate: coordinate, speedLimit: 13.9)]
        for _ in 0..<40 {
            coordinate = coordinate.destination(bearingDegrees: 90, meters: 10)
            path.append(RoutePoint(coordinate: coordinate, speedLimit: 13.9))
        }
        for _ in 0..<40 {
            coordinate = coordinate.destination(bearingDegrees: 0, meters: 10)
            path.append(RoutePoint(coordinate: coordinate, speedLimit: 13.9))
        }

        let follower = try #require(RouteFollower(path: path, mode: .driving))
        let cornerDistance = 400.0

        var speedInCorner = Double.greatestFiniteMagnitude
        var speedOnStraight = 0.0
        var fix = follower.initialFix()

        while !fix.isFinished {
            fix = follower.advance(by: 0.5)
            if fix.distanceTravelled < cornerDistance - 60 {
                speedOnStraight = max(speedOnStraight, fix.speed)
            } else if abs(fix.distanceTravelled - cornerDistance) < 15 {
                speedInCorner = min(speedInCorner, fix.speed)
            }
        }

        #expect(speedInCorner < speedOnStraight)
    }

    @Test("The interpolated position stays on the path")
    func staysOnPath() throws {
        let path = straightLine(count: 21, spacing: 50, speedLimit: 13.9)
        let follower = try #require(RouteFollower(path: path, mode: .driving))
        let startLatitude = path[0].coordinate.latitude

        var fix = follower.initialFix()
        while !fix.isFinished {
            fix = follower.advance(by: 1.0)
            // Strictly east-west path: the latitude must not drift.
            #expect(abs(fix.coordinate.latitude - startLatitude) < 0.0005)
        }
    }

    @Test("The course follows the direction of the path")
    func courseFollowsPath() throws {
        let path = straightLine(count: 21, spacing: 50, speedLimit: 13.9)
        let follower = try #require(RouteFollower(path: path, mode: .driving))

        let fix = follower.advance(by: 1.0)
        #expect(abs(fix.course - 90) < 2)
    }

    @Test("Resetting makes it possible to replay the trip")
    func resetReplays() throws {
        let path = straightLine(count: 21, spacing: 50, speedLimit: 13.9)
        let follower = try #require(RouteFollower(path: path, mode: .driving))

        runToEnd(follower)
        #expect(follower.isFinished)

        follower.reset()
        #expect(!follower.isFinished)
        #expect(follower.initialFix().distanceTravelled == 0)
        #expect(follower.initialFix().speed == 0)
    }

    @Test("The travel time stays physically plausible")
    func plausibleTravelTime() throws {
        // 2 km at 13.9 m/s: about 144 s at cruising speed, a little more with
        // the acceleration and braking phases.
        let path = straightLine(count: 101, spacing: 20, speedLimit: 13.9)
        let follower = try #require(RouteFollower(path: path, mode: .driving))

        let (ticks, _) = runToEnd(follower, interval: 1.0)
        #expect(ticks > 144)
        #expect(ticks < 200)
    }
}
