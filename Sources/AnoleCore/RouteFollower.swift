import Foundation

/// A point of the track, with the speed allowed there when it is known.
public struct RoutePoint: Sendable, Hashable {
    public var coordinate: Coordinate
    /// Speed limit in m/s. `nil` when the data is missing: we then fall back
    /// on the default speed of the transport mode.
    public var speedLimit: Double?

    public init(coordinate: Coordinate, speedLimit: Double? = nil) {
        self.coordinate = coordinate
        self.speedLimit = speedLimit
    }
}

/// State of the moving point at a given instant.
public struct RouteFix: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Course in degrees from north.
    public var course: Double
    /// Instantaneous speed in m/s.
    public var speed: Double
    public var distanceTravelled: Double
    public var distanceRemaining: Double
    public var isFinished: Bool
}

/// Follows a track at varying speed, in a physically plausible way.
///
/// The backend only knows how to set a fixed point: to give the illusion of
/// movement, a location is pushed to it at regular intervals. This type computes
/// where the moving point is at each interval.
///
/// Three effects make the result believable rather than mechanical:
///  - the target speed follows the limit of the current segment,
///  - acceleration is bounded, so no jump from 0 to 50 km/h,
///  - it brakes when approaching sharp turns and the destination.
public final class RouteFollower {

    public let mode: TransportMode
    private let points: [RoutePoint]
    /// Cumulative distance from the start, for each point of the track.
    private let cumulative: [Double]
    /// Speed ceiling at each point, turns included.
    private let ceilings: [Double]

    private var travelled: Double = 0
    private var currentSpeed: Double = 0

    public var totalDistance: Double { cumulative.last ?? 0 }
    public var isFinished: Bool { travelled >= totalDistance - 0.01 }

    /// - Parameters:
    ///   - path: the track, at least two points.
    ///   - mode: the transport mode, which sets acceleration and ceilings.
    ///   - startSpeed: initial speed, zero by default (start from a standstill).
    public init?(path: [RoutePoint], mode: TransportMode, startSpeed: Double = 0) {
        guard path.count >= 2 else { return nil }
        self.points = path
        self.mode = mode
        self.currentSpeed = startSpeed

        var distances: [Double] = [0]
        distances.reserveCapacity(path.count)
        for index in 1..<path.count {
            let step = path[index - 1].coordinate.distance(to: path[index].coordinate)
            distances.append(distances[index - 1] + step)
        }
        self.cumulative = distances
        self.ceilings = Self.computeCeilings(path: path, mode: mode)
    }

    public convenience init?(coordinates: [Coordinate], mode: TransportMode) {
        self.init(path: coordinates.map { RoutePoint(coordinate: $0) }, mode: mode)
    }

    /// Advances by `interval` seconds and returns the new state.
    public func advance(by interval: TimeInterval) -> RouteFix {
        guard interval > 0, !isFinished else { return currentFix() }

        let target = targetSpeed(at: travelled)
        let remaining = max(totalDistance - travelled, 0)

        // Speed bounded by the braking needed to stop at the destination.
        // The continuous form sqrt(2 a d) is too permissive when advancing in
        // one-second steps: it ignores the distance covered during the step.
        // So we solve v * dt + v^2 / (2 a) <= d, whose positive root is
        // -a dt + sqrt(a^2 dt^2 + 2 a d).
        let acceleration = mode.acceleration
        let braking = acceleration * interval
        let stoppingLimit = -braking + (braking * braking + 2 * acceleration * remaining).squareRoot()
        let allowed = max(min(target, stoppingLimit), 0)

        // Bounded acceleration: the setpoint is only reached gradually.
        if currentSpeed < allowed {
            currentSpeed = min(allowed, currentSpeed + braking)
        } else {
            currentSpeed = max(allowed, currentSpeed - braking)
        }
        currentSpeed = max(currentSpeed, 0)

        travelled = min(travelled + currentSpeed * interval, totalDistance)

        // This braking converges towards the destination without ever quite
        // reaching it. We cut it off at the last half-meter: at the destination
        // the moving point is at a standstill.
        if totalDistance - travelled < 0.5 {
            travelled = totalDistance
            currentSpeed = 0
        }

        return currentFix()
    }

    /// Position at the start, without advancing.
    public func initialFix() -> RouteFix {
        currentFix()
    }

    public func reset() {
        travelled = 0
        currentSpeed = 0
    }

    // MARK: - Internal

    private func currentFix() -> RouteFix {
        let coordinate = interpolate(at: travelled)
        return RouteFix(
            coordinate: coordinate,
            course: courseHeading(at: travelled),
            speed: currentSpeed,
            distanceTravelled: travelled,
            distanceRemaining: max(totalDistance - travelled, 0),
            isFinished: isFinished
        )
    }

    /// Speed aimed for at a given distance: the limit of the segment, capped by
    /// what the mode allows, and lowered in turns.
    private func targetSpeed(at distance: Double) -> Double {
        let index = segmentIndex(for: distance)
        let limit = points[index].speedLimit ?? mode.defaultSpeed
        return min(limit, mode.maximumSpeed, ceilings[index])
    }

    /// Index of the segment holding this cumulative distance.
    private func segmentIndex(for distance: Double) -> Int {
        guard distance > 0 else { return 0 }
        // Binary search: the track can hold thousands of points.
        var low = 0
        var high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] < distance { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    private func interpolate(at distance: Double) -> Coordinate {
        guard distance > 0 else { return points[0].coordinate }
        guard distance < totalDistance else { return points[points.count - 1].coordinate }

        let index = segmentIndex(for: distance)
        let start = points[index].coordinate
        let end = points[index + 1].coordinate
        let segmentLength = cumulative[index + 1] - cumulative[index]
        guard segmentLength > 0.001 else { return start }

        let into = distance - cumulative[index]
        return start.destination(bearingDegrees: start.bearing(to: end), meters: into)
    }

    private func courseHeading(at distance: Double) -> Double {
        let index = min(segmentIndex(for: distance), points.count - 2)
        return points[index].coordinate.bearing(to: points[index + 1].coordinate)
    }

    /// Speed ceiling imposed by the local curvature of the track.
    ///
    /// We estimate the radius of the circle through three consecutive points;
    /// the smaller it is, the sharper the turn. The sustainable speed is then
    /// sqrt(lateral acceleration * radius).
    private static func computeCeilings(path: [RoutePoint], mode: TransportMode) -> [Double] {
        var ceilings = [Double](repeating: mode.maximumSpeed, count: path.count)
        guard path.count >= 3 else { return ceilings }

        for index in 1..<(path.count - 1) {
            let previous = path[index - 1].coordinate
            let current = path[index].coordinate
            let next = path[index + 1].coordinate

            let a = previous.distance(to: current)
            let b = current.distance(to: next)
            let c = previous.distance(to: next)
            guard a > 0.5, b > 0.5, c > 0.5 else { continue }

            // Triangle area by Heron's formula; the circumscribed radius is
            // abc / 4A. A near-zero area means three collinear points, hence
            // no turn.
            let s = (a + b + c) / 2
            let squared = s * (s - a) * (s - b) * (s - c)
            guard squared > 0 else { continue }
            let area = sqrt(squared)
            guard area > 0.01 else { continue }

            let radius = (a * b * c) / (4 * area)
            let cornering = sqrt(mode.lateralAcceleration * radius)
            ceilings[index] = min(mode.maximumSpeed, max(cornering, 1.0))
        }

        // A turn also slows down what comes before it: propagate the ceiling upstream.
        for index in stride(from: path.count - 2, through: 0, by: -1) {
            let segment = path[index].coordinate.distance(to: path[index + 1].coordinate)
            let reachable = sqrt(ceilings[index + 1] * ceilings[index + 1] + 2 * mode.acceleration * segment)
            ceilings[index] = min(ceilings[index], reachable)
        }

        return ceilings
    }
}
