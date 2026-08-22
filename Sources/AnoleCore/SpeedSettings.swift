import Foundation

/// Speed settings for a trip.
public struct SpeedSettings: Sendable, Equatable {

    /// Imposed average speed, in m/s. `nil` lets the routing service decide,
    /// which remains the most believable choice: its duration accounts for
    /// traffic, lights and slowdowns.
    public var averageSpeed: Double?
    /// Minimum speed once up to speed, in m/s. Zero to impose nothing.
    public var minimumSpeed: Double

    public init(averageSpeed: Double? = nil, minimumSpeed: Double = 0) {
        self.averageSpeed = averageSpeed
        self.minimumSpeed = minimumSpeed
    }

    public static let automatic = SpeedSettings()

    public var isAutomatic: Bool { averageSpeed == nil && minimumSpeed == 0 }

    /// Duration to aim for to cover `distance`, if an average is imposed.
    public func targetDuration(forDistance distance: Double) -> TimeInterval? {
        guard let averageSpeed, averageSpeed > 0 else { return nil }
        return distance / averageSpeed
    }

    /// Checks the internal consistency of the settings.
    ///
    /// No ceiling is imposed: if the user wants to cross the Bay Area at 300 km/h
    /// on a bicycle, that is their business. Only the contradiction is fixed,
    /// a floor above the average making the duration impossible to hold.
    public func clamped(to mode: TransportMode) -> SpeedSettings {
        var result = self
        if let average = averageSpeed {
            result.averageSpeed = max(average, 0.3)
        }
        let ceiling = result.averageSpeed ?? .greatestFiniteMagnitude
        result.minimumSpeed = min(max(minimumSpeed, 0), ceiling)
        return result
    }

    /// Ceiling to hand to the backend: the one of the mode, raised if needed to
    /// honor a higher imposed speed.
    public func speedCeiling(for mode: TransportMode) -> Double? {
        guard let averageSpeed else { return nil }
        // Some headroom above the average: without it, the moving point could
        // never make up the time lost in turns and stops.
        let needed = averageSpeed * 1.6
        return needed > mode.maximumSpeed ? needed : nil
    }
}

public extension Double {
    /// Convenience conversion: the interface speaks in km/h, the backend in m/s.
    var kmhToMetersPerSecond: Double { self / 3.6 }
    var metersPerSecondToKmh: Double { self * 3.6 }
}
