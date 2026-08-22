import Foundation

/// An iOS device detected on the machine.
public struct DeviceInfo: Identifiable, Hashable, Sendable {
    public var udid: String
    public var name: String
    /// E.g. "iPhone17,3"
    public var productType: String?
    /// E.g. "27.0"
    public var osVersion: String?
    public var connectionKind: ConnectionKind

    public var id: String { udid }

    public enum ConnectionKind: String, Sendable {
        case usb
        case network
        case unknown
    }

    public init(
        udid: String,
        name: String,
        productType: String? = nil,
        osVersion: String? = nil,
        connectionKind: ConnectionKind = .unknown
    ) {
        self.udid = udid
        self.name = name
        self.productType = productType
        self.osVersion = osVersion
        self.connectionKind = connectionKind
    }

    /// Major iOS version, used to pick the tunnel strategy.
    public var majorOSVersion: Int? {
        guard let osVersion, let first = osVersion.split(separator: ".").first else { return nil }
        return Int(first)
    }

    /// How the device is reachable, in plain words.
    public var connectionLabel: String {
        switch connectionKind {
        case .usb: return "USB"
        case .network: return "Wi-Fi"
        case .unknown: return "unknown"
        }
    }

    /// Whether the device is reached over the network rather than a cable.
    /// Wi-Fi holds up in practice, locked screen included; USB is still
    /// preferred when both are available.
    public var isWireless: Bool { connectionKind == .network }

    public var displayName: String {
        if let osVersion { return "\(name) - iOS \(osVersion)" }
        return name
    }
}
