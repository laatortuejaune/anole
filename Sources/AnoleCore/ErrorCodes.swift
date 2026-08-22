import Foundation

/// Numbered errors.
///
/// A short code carries over and is found again without ambiguity: quoting it is
/// enough to pin down the exact failure, where a translated message gets
/// paraphrased and lost along the way. The hundreds group by domain.
public enum AnoleError: Error, LocalizedError, Equatable {

    // 1xx — tooling and prerequisites
    case toolingMissing(String)             // 101
    case helperMissing                      // 102
    case pairingFileMissing                 // 103

    // 2xx — device
    case noDeviceFound                      // 201
    case deviceNotPaired(String)            // 202
    case developerModeDisabled              // 203
    case developerImageUnavailable(String)  // 204

    // 3xx — link
    case tunnelFailed(String)               // 301
    case connectionLost(String)             // 302
    case notPrepared                        // 303
    case helperCrashed(Int32, String)       // 304
    case helperTimeout(String)              // 305
    case helperUnreadable(String)           // 306

    // 4xx — developer services
    case serviceUnavailable(String)         // 401
    case locationRejected(String)           // 402
    case invalidCoordinate                  // 403

    // 5xx — real location
    case locationDenied                     // 501
    case locationReducedAccuracy            // 502
    case locationTooImprecise(Int)          // 503
    case locationUnavailable(String)        // 504

    // 6xx — route
    case routeNotFound                      // 601
    case routeTimedOut                      // 602
    case routeFailed(String)                // 603
    case noDestination                      // 604
    case noOrigin                           // 605

    // 9xx — miscellaneous
    case commandFailed(String, Int32, String) // 901
    case unsupported(String)                  // 902

    /// Stable number of the error.
    public var code: Int {
        switch self {
        case .toolingMissing: return 101
        case .helperMissing: return 102
        case .pairingFileMissing: return 103
        case .noDeviceFound: return 201
        case .deviceNotPaired: return 202
        case .developerModeDisabled: return 203
        case .developerImageUnavailable: return 204
        case .tunnelFailed: return 301
        case .connectionLost: return 302
        case .notPrepared: return 303
        case .helperCrashed: return 304
        case .helperTimeout: return 305
        case .helperUnreadable: return 306
        case .serviceUnavailable: return 401
        case .locationRejected: return 402
        case .invalidCoordinate: return 403
        case .locationDenied: return 501
        case .locationReducedAccuracy: return 502
        case .locationTooImprecise: return 503
        case .locationUnavailable: return 504
        case .routeNotFound: return 601
        case .routeTimedOut: return 602
        case .routeFailed: return 603
        case .noDestination: return 604
        case .noOrigin: return 605
        case .commandFailed: return 901
        case .unsupported: return 902
        }
    }

    /// Short explanation, without the technical detail.
    public var summary: String {
        switch self {
        case .toolingMissing: return "Missing tooling."
        case .helperMissing: return "Helper not found."
        case .pairingFileMissing: return "No pairing file."
        case .noDeviceFound: return "No device detected."
        case .deviceNotPaired: return "Device not paired."
        case .developerModeDisabled: return "Developer Mode is off."
        case .developerImageUnavailable: return "Developer disk image unavailable."
        case .tunnelFailed: return "The tunnel could not be opened."
        case .connectionLost: return "Link lost."
        case .notPrepared: return "Device not connected."
        case .helperCrashed: return "The helper stopped."
        case .helperTimeout: return "The helper is no longer responding."
        case .helperUnreadable: return "Unreadable response from the helper."
        case .serviceUnavailable: return "Developer service unavailable."
        case .locationRejected: return "Location refused by the device."
        case .invalidCoordinate: return "Invalid coordinate."
        case .locationDenied: return "Location access denied."
        case .locationReducedAccuracy: return "Precise Location is off."
        case .locationTooImprecise: return "Location too imprecise."
        case .locationUnavailable: return "Location unavailable."
        case .routeNotFound: return "No route found."
        case .routeTimedOut: return "Route calculation did not answer."
        case .routeFailed: return "Route calculation failed."
        case .noDestination: return "No destination chosen."
        case .noOrigin: return "No start point."
        case .commandFailed: return "A command failed."
        case .unsupported: return "Unsupported operation."
        }
    }

    /// What the user can do, when there is something to do.
    public var advice: String? {
        switch self {
        case .toolingMissing, .helperMissing:
            return "Run Scripts/setup-backend.sh."
        case .pairingFileMissing:
            return "Pair again from the Developer Mode settings."
        case .noDeviceFound:
            return "Plug in the iPhone and unlock it."
        case .deviceNotPaired:
            return "Accept \"Trust This Computer\" on the iPhone."
        case .developerModeDisabled:
            return "Settings > Privacy & Security > Developer Mode."
        case .tunnelFailed:
            return "Check that the local tunnel is up."
        case .notPrepared:
            return "Connect the device first."
        case .locationDenied:
            return "Allow location access in Settings."
        case .locationReducedAccuracy:
            return "Turn on Precise Location for this app."
        case .locationTooImprecise:
            return "Turn on Wi-Fi to sharpen the location."
        case .noOrigin:
            return "Allow location access, or set a start point by hand."
        default:
            return nil
        }
    }

    /// Technical detail, useful for diagnosis.
    public var detail: String? {
        switch self {
        case .toolingMissing(let text), .deviceNotPaired(let text),
             .developerImageUnavailable(let text), .tunnelFailed(let text),
             .connectionLost(let text), .serviceUnavailable(let text),
             .locationRejected(let text), .locationUnavailable(let text),
             .routeFailed(let text), .unsupported(let text),
             .helperTimeout(let text), .helperUnreadable(let text):
            return text
        case .helperCrashed(let status, let text):
            return "code \(status): \(text)"
        case .locationTooImprecise(let meters):
            return "±\(meters) m"
        case .commandFailed(let command, let status, let output):
            return "\(command) (code \(status))\n\(output)"
        default:
            return nil
        }
    }

    /// Message shown to the user: the code first, so it is easy to quote.
    public var errorDescription: String? {
        var text = "[\(code)] \(summary)"
        if let advice { text += " " + advice }
        return text
    }

    /// Full message, technical detail included.
    public var fullDescription: String {
        var text = "[\(code)] \(summary)"
        if let advice { text += "\n" + advice }
        if let detail { text += "\n\n" + detail }
        return text
    }
}
