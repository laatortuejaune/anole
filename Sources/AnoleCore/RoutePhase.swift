import Foundation

/// Stage reached while a route is being prepared.
///
/// Preparing a route used to be a single call and a short wait. It is now three
/// steps, and the middle one crosses the network - long enough that a spinner
/// with no words reads as an application that has stopped responding. Naming
/// the step is what turns a wait into progress.
public enum RoutePhase: Sendable, Equatable, CaseIterable {
    /// Asking the routing service for the path and its duration.
    case routing
    /// Reading the speed limits of the roads it crosses.
    case speedLimits
    /// Matching, then calibrating the speed profile.
    case profile

    public var label: String {
        switch self {
        case .routing: return "Computing the route"
        case .speedLimits: return "Reading the speed limits"
        case .profile: return "Building the speed profile"
        }
    }

    /// Progress already behind when the step begins.
    public var startFraction: Double {
        switch self {
        case .routing: return 0
        case .speedLimits: return 0.3
        case .profile: return 0.85
        }
    }

    /// Progress the bar may creep up to while the step runs, never past it.
    ///
    /// Stopping short of the next step is deliberate: a bar that reaches the end
    /// and then waits is worse than one that is still visibly moving.
    public var ceilingFraction: Double {
        switch self {
        case .routing: return 0.3
        case .speedLimits: return 0.85
        case .profile: return 1
        }
    }

    /// Roughly how long the step takes. The bar paces itself against this.
    ///
    /// These are measured, not guessed in equal thirds: the routing service
    /// answers in about a second, Overpass takes most of the wait, and the
    /// profile is pure arithmetic.
    public var expectedDuration: TimeInterval {
        switch self {
        case .routing: return 1.5
        case .speedLimits: return 3
        case .profile: return 0.4
        }
    }
}
