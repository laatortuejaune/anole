// This file drives subprocesses, which iOS does not allow: the iPhone app talks
// to the device directly through the idevice library. The core therefore stays
// a single module, shared by both applications.
#if os(macOS)

import Foundation

/// Decoding of the `pymobiledevice3 usbmux list` output.
///
/// The format is stable and documented by the tool; we decode it strictly
/// rather than reading through text, so we do not depend on messages that
/// change from one version to the next.
struct UsbmuxEntry: Decodable {
    let buildVersion: String?
    let connectionType: String?
    let deviceClass: String?
    let deviceName: String?
    let productType: String?
    let productVersion: String?
    let uniqueDeviceID: String

    enum CodingKeys: String, CodingKey {
        case buildVersion = "BuildVersion"
        case connectionType = "ConnectionType"
        case deviceClass = "DeviceClass"
        case deviceName = "DeviceName"
        case productType = "ProductType"
        case productVersion = "ProductVersion"
        case uniqueDeviceID = "UniqueDeviceID"
    }

    var connectionKind: DeviceInfo.ConnectionKind {
        switch connectionType?.lowercased() {
        case "usb": return .usb
        case "network": return .network
        default: return .unknown
        }
    }

    var deviceInfo: DeviceInfo {
        DeviceInfo(
            udid: uniqueDeviceID,
            name: deviceName ?? deviceClass ?? "iOS device",
            productType: productType,
            osVersion: productVersion,
            connectionKind: connectionKind
        )
    }
}

enum DeviceListing {

    /// The same device is listed several times when it is reachable over both
    /// cable and network. We keep a single entry per device, preferring USB:
    /// the tunnel is far more stable there, and the link does not drop when the
    /// screen locks.
    static func parse(_ jsonOutput: String) throws -> [DeviceInfo] {
        guard let data = jsonOutput.data(using: .utf8) else { return [] }
        let entries = try JSONDecoder().decode([UsbmuxEntry].self, from: data)

        var best: [String: UsbmuxEntry] = [:]
        for entry in entries {
            guard let existing = best[entry.uniqueDeviceID] else {
                best[entry.uniqueDeviceID] = entry
                continue
            }
            if existing.connectionKind != .usb, entry.connectionKind == .usb {
                best[entry.uniqueDeviceID] = entry
            }
        }

        return best.values
            .map(\.deviceInfo)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

#endif
