import Foundation

/// A simulated geographic location.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Altitude in meters. Not every backend reports it.
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public var isValid: Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }

    /// Formatted the way pymobiledevice3 expects it: two floats separated by a space.
    public var cliArguments: [String] {
        [String(format: "%.7f", latitude), String(format: "%.7f", longitude)]
    }
}

// MARK: - Geodesy

private let earthRadiusMeters = 6_371_000.0

extension Coordinate {
    /// Great-circle distance in meters (haversine).
    public func distance(to other: Coordinate) -> Double {
        let phi1 = latitude * .pi / 180
        let phi2 = other.latitude * .pi / 180
        let dPhi = (other.latitude - latitude) * .pi / 180
        let dLambda = (other.longitude - longitude) * .pi / 180

        let a = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadiusMeters * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial bearing to another coordinate, in degrees from north.
    public func bearing(to other: Coordinate) -> Double {
        let phi1 = latitude * .pi / 180
        let phi2 = other.latitude * .pi / 180
        let dLambda = (other.longitude - longitude) * .pi / 180

        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        // atan2 already returns (-180, 180]: a modulo 360 remainder would change nothing.
        // The 360 offset is what brings the value into [0, 360); without it a bearing
        // due west reads -90 and every comparison between bearings goes wrong.
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point reached by travelling `meters` along the `bearingDegrees` bearing.
    /// This is the core of the joystick: one step forward on every tick.
    public func destination(bearingDegrees: Double, meters: Double) -> Coordinate {
        let delta = meters / earthRadiusMeters
        let theta = bearingDegrees * .pi / 180
        let phi1 = latitude * .pi / 180
        let lambda1 = longitude * .pi / 180

        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(
            sin(theta) * sin(delta) * cos(phi1),
            cos(delta) - sin(phi1) * sin(phi2)
        )

        return Coordinate(
            latitude: phi2 * 180 / .pi,
            // Brings the longitude back into [-180, 180].
            longitude: (lambda2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180,
            altitude: altitude
        )
    }
}

/// Difference between two bearings, in degrees, within [0, 180].
///
/// A plain subtraction is wrong near north: between 359 and 1 degree the gap is
/// 2 degrees, not 358. The planner further down the line uses it to spot the
/// turns at the boundary between two segments.
public func angularDifference(_ first: Double, _ second: Double) -> Double {
    let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
    return raw > 180 ? 360 - raw : raw
}
