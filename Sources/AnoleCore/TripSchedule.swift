import Foundation

/// A fully precomputed trip: every instant maps to a location.
///
/// The whole trip is solved once and for all, before setting off. The emission
/// loop then only has to read a table. Three important consequences: no numerical
/// drift accumulates; a send that drags does not shift the trip, it simply skips
/// a point like a real reception gap; and the duration and arrival time can be
/// announced before even starting.
public struct TripSchedule: Sendable {

    public let geometry: PathGeometry
    public let mode: TransportMode
    /// Factor found by calibration. 1 means "base pace unchanged".
    public let cruiseScale: Double
    /// Total duration of the trip, stops included.
    public let duration: TimeInterval
    /// Effective average speed over the whole trip, in m/s.
    public var averageSpeed: Double {
        duration > 0 ? geometry.length / duration : 0
    }

    private let step: Double
    private let speeds: [Double]
    /// Arrival instant at each node.
    private let arrival: [TimeInterval]
    /// Departure instant from each node: same as the arrival, except at stops.
    private let departure: [TimeInterval]

    public init(geometry: PathGeometry, planner: SpeedPlanner, cruiseScale: Double) {
        self.geometry = geometry
        self.mode = planner.mode
        self.cruiseScale = cruiseScale
        self.step = planner.step

        let speeds = planner.speeds(cruiseScale: cruiseScale)
        self.speeds = speeds

        var arrival = [TimeInterval](repeating: 0, count: speeds.count)
        var departure = [TimeInterval](repeating: 0, count: speeds.count)
        departure[0] = planner.stopDuration(atNode: 0)

        for index in 1..<speeds.count {
            arrival[index] = departure[index - 1]
                + planner.segmentDuration(from: speeds[index - 1], to: speeds[index])
            departure[index] = arrival[index] + planner.stopDuration(atNode: index)
        }

        self.arrival = arrival
        self.departure = departure
        self.duration = arrival[speeds.count - 1]
    }

    // MARK: - Reading

    /// State of the moving point after `elapsed` seconds of travel.
    public func sample(at elapsed: TimeInterval) -> RouteFix {
        guard elapsed > 0 else { return fix(atNode: 0, extraDistance: 0, speed: 0) }
        guard elapsed < duration else {
            return fix(atNode: speeds.count - 1, extraDistance: 0, speed: 0)
        }

        let index = nodeIndex(at: elapsed)

        // At a stop, the position does not move for as long as the pause lasts.
        if elapsed <= departure[index] {
            return fix(atNode: index, extraDistance: 0, speed: 0)
        }

        let startSpeed = speeds[index]
        let endSpeed = speeds[index + 1]
        let segment = arrival[index + 1] - departure[index]
        let into = elapsed - departure[index]

        guard segment > 1e-9 else {
            return fix(atNode: index, extraDistance: 0, speed: startSpeed)
        }

        // Constant acceleration over the step: both formulas are exact.
        let acceleration = (endSpeed - startSpeed) / segment
        let travelled = startSpeed * into + 0.5 * acceleration * into * into
        let speed = startSpeed + acceleration * into

        return fix(atNode: index, extraDistance: travelled, speed: max(speed, 0))
    }

    /// Location alone, without the rest of the state.
    public func coordinate(at elapsed: TimeInterval) -> Coordinate {
        sample(at: elapsed).coordinate
    }

    private func fix(atNode index: Int, extraDistance: Double, speed: Double) -> RouteFix {
        let distance = min(Double(index) * step + extraDistance, geometry.length)
        return RouteFix(
            coordinate: geometry.point(at: distance),
            course: geometry.course(at: distance),
            speed: speed,
            distanceTravelled: distance,
            distanceRemaining: max(geometry.length - distance, 0),
            isFinished: distance >= geometry.length - 0.01
        )
    }

    /// Last node whose arrival instant precedes `elapsed`, by binary search.
    private func nodeIndex(at elapsed: TimeInterval) -> Int {
        var low = 0
        var high = arrival.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if arrival[middle] <= elapsed { low = middle } else { high = middle - 1 }
        }
        return min(low, speeds.count - 2)
    }

    // MARK: - Calibration

    /// Builds a trip whose duration equals the one announced by the routing
    /// service.
    ///
    /// This is the core of a believable movement. Driving at the legal limit
    /// everywhere produces a trip about 48% too fast: the limit ignores
    /// roundabouts, lights and traffic. By pinning the total duration to the one
    /// from the routing service, we get a speed that varies along the trip AND a
    /// correct arrival time.
    ///
    /// The duration decreases monotonically as the scale grows, so a binary
    /// search converges without surprises.
    public static func calibrated(
        geometry: PathGeometry,
        mode: TransportMode,
        samples: [SpeedSample] = [],
        stops: [RouteStop] = [],
        minimumSpeed: Double = 0,
        speedCeiling: Double? = nil,
        targetDuration: TimeInterval?
    ) -> TripSchedule {
        let planner = SpeedPlanner(
            geometry: geometry, mode: mode,
            samples: samples, stops: stops,
            minimumSpeed: minimumSpeed, speedCeiling: speedCeiling
        )

        guard let target = targetDuration, target > 0 else {
            return TripSchedule(geometry: geometry, planner: planner, cruiseScale: 1)
        }

        var low = 0.05
        var high = 20.0

        // Target unreachable even at full tilt: turns or the mode ceiling
        // dominate. We return the fastest possible rather than cheat on physics.
        if planner.duration(cruiseScale: high) > target {
            return TripSchedule(geometry: geometry, planner: planner, cruiseScale: high)
        }
        if planner.duration(cruiseScale: low) < target {
            return TripSchedule(geometry: geometry, planner: planner, cruiseScale: low)
        }

        var scale = 1.0
        for _ in 0..<45 {
            scale = (low + high) / 2
            let duration = planner.duration(cruiseScale: scale)
            if abs(duration - target) < 0.5 { break }
            if duration > target { low = scale } else { high = scale }
        }

        return TripSchedule(geometry: geometry, planner: planner, cruiseScale: scale)
    }
}
