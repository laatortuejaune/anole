import Foundation

/// A computed route, independent of the service that produced it.
public struct RoutePlan: Sendable, Identifiable {
    public var id: String
    /// Name of the main road, for example "US 101".
    public var name: String
    public var coordinates: [Coordinate]
    public var distance: Double
    /// Duration announced by the routing service. It is the calibration
    /// reference: it accounts for traffic, lights and slowdowns.
    public var expectedTravelTime: TimeInterval
    /// Arc length of the end of each step, used to place the stops.
    public var stepEndArcLengths: [Double]
    public var mode: TransportMode
    /// Mode the routing service actually used to compute the duration.
    /// It differs from `mode` for cycling, which no Apple service knows about.
    public var routingBasis: TransportMode
    public var hasTolls: Bool
    public var hasHighways: Bool
    /// Speed limits recovered for this route, one entry per stretch of constant
    /// limit. Empty when they could not be fetched, which is not an error: the
    /// planner then falls back on the pace of the mode.
    public var speedSamples: [SpeedSample]

    public init(
        id: String,
        name: String,
        coordinates: [Coordinate],
        distance: Double,
        expectedTravelTime: TimeInterval,
        stepEndArcLengths: [Double] = [],
        mode: TransportMode,
        routingBasis: TransportMode? = nil,
        hasTolls: Bool = false,
        hasHighways: Bool = false,
        speedSamples: [SpeedSample] = []
    ) {
        self.id = id
        self.name = name
        self.coordinates = coordinates
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.stepEndArcLengths = stepEndArcLengths
        self.mode = mode
        self.routingBasis = routingBasis ?? mode
        self.hasTolls = hasTolls
        self.hasHighways = hasHighways
        self.speedSamples = speedSamples
    }

    public var geometry: PathGeometry? { PathGeometry(coordinates) }

    /// Duration to aim for with this transport mode.
    ///
    /// MapKit does not compute cycling routes: we ask it for a walking trip,
    /// whose announced duration therefore matches a walking pace. Using it as is
    /// would make the bike ride at 5 km/h - the speed of the mode would be
    /// entirely overridden by the calibration. So we transpose the duration by
    /// the ratio of the two paces.
    public var targetDuration: TimeInterval {
        guard routingBasis != mode else { return expectedTravelTime }
        let ratio = routingBasis.defaultSpeed / mode.defaultSpeed
        return expectedTravelTime * ratio
    }

    /// Duration actually simulated, shown next to the one from the service.
    public var targetDurationLabel: String {
        let minutes = Int((targetDuration / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Duration formatted for display.
    public var durationLabel: String {
        let minutes = Int((expectedTravelTime / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    public var distanceLabel: String {
        distance < 1000
            ? "\(Int(distance)) m"
            : String(format: "%.1f km", distance / 1000)
    }
}

/// Infers the stops of a route from its geometry alone.
///
/// We could read the navigation instructions, but those are translated
/// sentences: parsing them would break the first time the system language
/// changes. The course variation at the boundary between two steps says the
/// same thing and depends on no language.
public enum StopDetector {

    public static func stops(
        geometry: PathGeometry,
        stepEnds: [Double],
        mode: TransportMode
    ) -> [RouteStop] {
        guard mode != .walking else {
            // On foot we only mark the genuinely sharp turns.
            return stepEnds.compactMap { position in
                let turn = turnAngle(geometry: geometry, at: position)
                return turn > 100 ? RouteStop(arcLength: position, duration: 2) : nil
            }
        }

        return stepEnds.compactMap { position in
            let turn = turnAngle(geometry: geometry, at: position)
            switch turn {
            case ..<20: return nil                                    // keep going straight
            case 20..<100: return RouteStop(arcLength: position, duration: 4)
            default: return RouteStop(arcLength: position, duration: 9)
            }
        }
    }

    /// Course difference on either side of a point of the track.
    static func turnAngle(geometry: PathGeometry, at arcLength: Double, window: Double = 15) -> Double {
        guard arcLength > window, arcLength < geometry.length - window else { return 0 }
        let before = geometry.course(at: arcLength - window)
        let after = geometry.course(at: arcLength + window)
        return angularDifference(before, after)
    }
}
