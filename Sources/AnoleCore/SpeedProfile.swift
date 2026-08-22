import Foundation

/// Speed known over a portion of the track.
public struct SpeedSample: Sendable, Hashable {
    public var startArcLength: Double
    public var endArcLength: Double
    /// Realistic travel speed, in m/s. This is what drives the movement.
    public var travelSpeed: Double
    /// Legal limit, in m/s. Display and hard ceiling; often unknown.
    public var legalLimit: Double?
    public var roadName: String?

    public init(
        startArcLength: Double,
        endArcLength: Double,
        travelSpeed: Double,
        legalLimit: Double? = nil,
        roadName: String? = nil
    ) {
        self.startArcLength = startArcLength
        self.endArcLength = endArcLength
        self.travelSpeed = travelSpeed
        self.legalLimit = legalLimit
        self.roadName = roadName
    }
}

/// A stop marked on the track: intersection, traffic light, tight maneuver.
public struct RouteStop: Sendable, Hashable {
    public var arcLength: Double
    public var duration: TimeInterval

    public init(arcLength: Double, duration: TimeInterval) {
        self.arcLength = arcLength
        self.duration = duration
    }
}

/// Plans the speed along a track.
///
/// Everything that does not depend on the cruise scale is computed once at
/// construction: the calibration tries dozens of values, and recomputing the
/// curvature on every attempt would be absurd.
public struct SpeedPlanner: Sendable {

    public let step: Double
    public let mode: TransportMode
    /// Speed sustainable at each node given the turn alone.
    private let curvatureCeiling: [Double]
    /// Reference speed at each node, before scaling.
    private let baseSpeed: [Double]
    /// Legal ceiling at each node, when it is known.
    private let legalCeiling: [Double?]
    private let stopAtNode: [Int: TimeInterval]
    public let nodeCount: Int
    /// Speed below which we do not want to drop once up to speed.
    public let minimumSpeed: Double
    /// Effective ceiling. It is the one of the mode, unless the user explicitly
    /// asks for a higher speed: that is their choice, and not for the backend
    /// to correct.
    public let speedCeiling: Double

    public init(
        geometry: PathGeometry,
        mode: TransportMode,
        samples: [SpeedSample] = [],
        stops: [RouteStop] = [],
        minimumSpeed: Double = 0,
        speedCeiling: Double? = nil
    ) {
        // Grid step matched to the pace: fine on foot, wider when driving.
        let step = min(max(mode.defaultSpeed / 5, 1), 5)
        let grid = geometry.resample(step: step)

        self.step = step
        self.mode = mode
        self.nodeCount = grid.count
        let ceiling = max(speedCeiling ?? mode.maximumSpeed, 0.5)
        self.speedCeiling = ceiling
        self.minimumSpeed = max(min(minimumSpeed, ceiling), 0)
        self.curvatureCeiling = Self.curvature(grid: grid, mode: mode, ceiling: ceiling)

        var base = [Double](repeating: mode.defaultSpeed, count: grid.count)
        var legal = [Double?](repeating: nil, count: grid.count)
        if !samples.isEmpty {
            for index in 0..<grid.count {
                let distance = Double(index) * step
                if let sample = samples.first(where: { distance >= $0.startArcLength && distance <= $0.endArcLength }) {
                    base[index] = sample.travelSpeed
                    legal[index] = sample.legalLimit
                }
            }
        }
        self.baseSpeed = base
        self.legalCeiling = legal

        var stopMap: [Int: TimeInterval] = [:]
        for stop in stops {
            let index = min(max(Int((stop.arcLength / step).rounded()), 0), grid.count - 1)
            stopMap[index, default: 0] += stop.duration
        }
        self.stopAtNode = stopMap
    }

    /// Speed at each node for a given cruise scale.
    ///
    /// The scale only multiplies the free-flowing component: turns and stops
    /// stay physical whatever its value. That is what guarantees the duration
    /// decreases monotonically as the scale grows, and hence that the binary
    /// search converges.
    public func speeds(cruiseScale: Double) -> [Double] {
        var speeds = [Double](repeating: 0, count: nodeCount)

        for index in 0..<nodeCount {
            var value = min(baseSpeed[index] * cruiseScale, speedCeiling)
            value = min(value, curvatureCeiling[index])
            if let legal = legalCeiling[index] { value = min(value, legal) }
            // The floor applies to the setpoint, not to the final result: the
            // acceleration and braking passes that follow must stay free to go
            // below it, otherwise the moving point could neither start, nor
            // stop, nor negotiate a sharp turn.
            speeds[index] = max(value, max(minimumSpeed, 0.1))
        }

        // Start, destination and stops: zero speed.
        speeds[0] = 0
        speeds[nodeCount - 1] = 0
        for (index, _) in stopAtNode { speeds[index] = 0 }

        // These two passes alone produce the trapezoidal profile, the early
        // slowdown before each turn and the final braking.
        // It is the trajectory planner of a CNC controller.
        for index in stride(from: nodeCount - 2, through: 0, by: -1) {
            let reachable = (speeds[index + 1] * speeds[index + 1] + 2 * mode.acceleration * step).squareRoot()
            speeds[index] = min(speeds[index], reachable)
        }
        for index in 1..<nodeCount {
            let reachable = (speeds[index - 1] * speeds[index - 1] + 2 * mode.acceleration * step).squareRoot()
            speeds[index] = min(speeds[index], reachable)
        }

        return speeds
    }

    /// Total duration of the trip for this scale, stops included.
    public func duration(cruiseScale: Double) -> TimeInterval {
        let speeds = speeds(cruiseScale: cruiseScale)
        var total = stopAtNode.values.reduce(0, +)
        for index in 1..<nodeCount {
            total += segmentDuration(from: speeds[index - 1], to: speeds[index])
        }
        return total
    }

    /// Time taken to cross one grid step between two speeds.
    ///
    /// `2 ds / (v0 + v1)` is exact for a constant acceleration over the step:
    /// it is not an approximation.
    func segmentDuration(from start: Double, to end: Double) -> TimeInterval {
        let sum = start + end
        guard sum > 1e-6 else { return 0 }
        return min(2 * step / sum, 60)
    }

    func stopDuration(atNode index: Int) -> TimeInterval {
        stopAtNode[index] ?? 0
    }

    /// Ceiling imposed by the local curvature, estimated on the regular grid.
    ///
    /// On the raw vertices of a route, spaced very irregularly, this computation
    /// would give nothing but noise; that is precisely why we work on a grid.
    private static func curvature(
        grid: [Coordinate],
        mode: TransportMode,
        ceiling: Double
    ) -> [Double] {
        var ceilings = [Double](repeating: ceiling, count: grid.count)
        guard grid.count >= 3 else { return ceilings }

        for index in 1..<(grid.count - 1) {
            let a = grid[index - 1].distance(to: grid[index])
            let b = grid[index].distance(to: grid[index + 1])
            let c = grid[index - 1].distance(to: grid[index + 1])
            guard a > 0.01, b > 0.01, c > 0.01 else { continue }

            // Radius of the circumscribed circle: abc / 4A, the area by Heron's formula.
            let s = (a + b + c) / 2
            let squared = s * (s - a) * (s - b) * (s - c)
            guard squared > 0 else { continue }
            let area = squared.squareRoot()
            guard area > 1e-6 else { continue }

            let radius = (a * b * c) / (4 * area)
            ceilings[index] = min(ceiling, max((mode.lateralAcceleration * radius).squareRoot(), 0.5))
        }
        return ceilings
    }
}
