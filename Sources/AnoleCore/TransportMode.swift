import Foundation

/// Transport mode asked of the user.
/// Determines both the kind of route computed and the physical behavior.
public enum TransportMode: String, CaseIterable, Sendable, Identifiable {
    case walking
    case cycling
    case driving

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .driving: return "Driving"
        }
    }

    /// Symbol to show in menus and buttons.
    public var symbolName: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        }
    }

    /// Speed used when no limit is known for the segment.
    public var defaultSpeed: Double {
        switch self {
        case .walking: return 1.4    // 5 km/h
        case .cycling: return 8.3    // 30 km/h
        case .driving: return 13.9   // 50 km/h
        }
    }

    /// Absolute ceiling: a pedestrian will never move at 50 km/h, even on a main road.
    public var maximumSpeed: Double {
        switch self {
        case .walking: return 2.0    // 7 km/h
        case .cycling: return 12.5   // 45 km/h, reachable downhill
        case .driving: return 36.1   // 130 km/h
        }
    }

    /// Comfortable acceleration and braking, in m/s2.
    public var acceleration: Double {
        switch self {
        case .walking: return 0.6
        case .cycling: return 1.0
        case .driving: return 1.8
        }
    }

    /// Lateral acceleration acceptable in a turn, in m/s2.
    /// This is what causes the slowdown in sharp bends.
    public var lateralAcceleration: Double {
        switch self {
        case .walking: return 1.5
        case .cycling: return 2.0
        case .driving: return 2.5
        }
    }
}
