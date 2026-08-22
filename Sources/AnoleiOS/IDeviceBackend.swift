import Foundation
import IDeviceFFI
import AnoleCore

/// Backend of the iPhone app: talks directly to the device's services.
///
/// On the Mac, a Python daemon does this job. Here there is no subprocess and
/// no Python: we call the idevice library, written in Rust, through its C
/// interface. The path is nevertheless the same as on the Mac, service for
/// service:
///
///     pairing file -> tunnel -> developer server -> simulation
///
/// One iOS peculiarity forces a detour: an app cannot reach 127.0.0.1 to talk
/// to the services of its own device. It has to go through a virtual network
/// interface, provided by a local tunnel app, hence the address 10.7.0.1
/// rather than the loopback.
actor IDeviceBackend: LocationBackend {

    nonisolated let identifier = "idevice"
    nonisolated var displayName: String { "Developer services (on device)" }
    nonisolated let events: AsyncStream<BackendEvent>
    private nonisolated let eventSink: AsyncStream<BackendEvent>.Continuation

    /// The device's address as seen through the local tunnel.
    private let host: String
    private let port: UInt16

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var simulation: OpaquePointer?

    init(host: String = "10.7.0.1", port: UInt16 = 49152) {
        self.host = host
        self.port = port
        var sink: AsyncStream<BackendEvent>.Continuation!
        events = AsyncStream { sink = $0 }
        eventSink = sink
    }

    // MARK: - Prerequisites

    func preflight() async -> [String] {
        var problems: [String] = []
        if pairingFileURL == nil {
            problems.append("No pairing file. Pair the device from Settings.")
        }
        return problems
    }

    /// Pairing is a file dropped into the app's container.
    private nonisolated var pairingFileURL: URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = documents?.appendingPathComponent("pairing.plist") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func discoverDevices() async throws -> [DeviceInfo] {
        // Only one device is possible: the one we are running on.
        [DeviceInfo(
            udid: "local",
            name: UIDeviceName.current,
            osVersion: UIDeviceName.systemVersion,
            connectionKind: .usb
        )]
    }

    // MARK: - Opening the link

    func prepare(
        device: DeviceInfo,
        onProgress: @escaping @Sendable (PreparationStep) -> Void
    ) async throws {
        func step(_ value: PreparationStep) {
            onProgress(value)
            eventSink.yield(.health(.preparing(value)))
        }

        step(.checkingTooling)
        guard let pairingPath = pairingFileURL?.path else {
            throw BackendError.toolingMissing("pairing file")
        }

        await shutdown()

        step(.pairing)
        var pairingFile: OpaquePointer?
        try check(
            pairingPath.withCString { rp_pairing_file_read($0, &pairingFile) },
            "reading the pairing file"
        )
        defer { if let pairingFile { rp_pairing_file_free(pairingFile) } }

        step(.startingTunnel)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw BackendError.tunnelFailed("invalid address '\(host)'")
        }

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try host.withCString { hostname in
                    try check(
                        tunnel_create_rppairing(
                            sockaddrPointer,
                            socklen_t(MemoryLayout<sockaddr_in>.size),
                            hostname,
                            pairingFile,
                            nil,      // no code to enter: pairing is already done
                            nil,
                            &newAdapter,
                            &newHandshake
                        ),
                        "opening the tunnel"
                    )
                }
            }
        }
        adapter = newAdapter
        handshake = newHandshake

        step(.mountingDeveloperImage)
        // A failure here is not fatal: the image is often already mounted, iOS
        // 27 providing it itself through a system cryptex. It is the connection
        // to the developer server, just after, that really settles it.
        do {
            try mountDeveloperImageIfNeeded(adapter: newAdapter, handshake: newHandshake)
        } catch {
            eventSink.yield(.log("Mount skipped: \(error.localizedDescription)"))
        }

        step(.connectingDeveloperServices)
        var newServer: OpaquePointer?
        try check(
            remote_server_connect_rsd(newAdapter, newHandshake, &newServer),
            "connecting to the developer server"
        )
        server = newServer

        var newSimulation: OpaquePointer?
        try check(
            location_simulation_new(newServer, &newSimulation),
            "opening the simulation service"
        )
        simulation = newSimulation

        step(.ready)
        eventSink.yield(.health(.live(roundTripMillis: nil)))
    }

    // MARK: - Developer disk image

    /// Mounts the developer disk image if it is not mounted already.
    ///
    /// It unmounts on every device restart. Without it, the developer services
    /// simply do not exist, and the simulation service cannot be found.
    private func mountDeveloperImageIfNeeded(
        adapter: OpaquePointer?,
        handshake: OpaquePointer?
    ) throws {
        var mounter: OpaquePointer?
        try check(
            image_mounter_connect_rsd(adapter, handshake, &mounter),
            "connecting to the image mounter"
        )
        defer { if let mounter { image_mounter_free(mounter) } }

        // An already mounted image returns a signature: no need to do it again.
        // The type varies with the system version, hence trying several names
        // before concluding that nothing is mounted.
        for imageType in ["Personalized", "DeveloperDiskImage", "Developer"] {
            var signature: UnsafeMutablePointer<UInt8>?
            var signatureLength = 0
            let lookup = imageType.withCString {
                image_mounter_lookup_image(mounter, $0, &signature, &signatureLength)
            }
            if let lookup {
                idevice_error_free(lookup)   // absent: this is not a failure
                continue
            }
            if signatureLength > 0 {
                if let signature { free(signature) }
                eventSink.yield(.log("Developer disk image already mounted (\(imageType))."))
                return
            }
        }

        guard let files = developerImageFiles() else {
            throw BackendError.developerImageUnavailable(
                "Files missing. Drop Image.dmg, Image.dmg.trustcache and "
                + "BuildManifest.plist into the app's documents."
            )
        }

        let chipID = try uniqueChipID(mounter: mounter)
        eventSink.yield(.log("Mounting the developer disk image..."))

        try files.image.withUnsafeBytes { imageBytes in
            try files.trustCache.withUnsafeBytes { trustBytes in
                try files.manifest.withUnsafeBytes { manifestBytes in
                    try check(
                        image_mounter_mount_personalized_with_callback_rsd(
                            mounter, adapter, handshake,
                            imageBytes.bindMemory(to: UInt8.self).baseAddress,
                            files.image.count,
                            trustBytes.bindMemory(to: UInt8.self).baseAddress,
                            files.trustCache.count,
                            manifestBytes.bindMemory(to: UInt8.self).baseAddress,
                            files.manifest.count,
                            nil,
                            chipID,
                            // The library calls this callback without checking
                            // that it exists: passing it a null pointer makes it
                            // jump to address zero, and the system kills the
                            // app for an invalid page.
                            mountProgressCallback,
                            nil
                        ),
                        "mounting the developer disk image"
                    )
                }
            }
        }
        eventSink.yield(.log("Developer disk image mounted."))
    }

    /// Unique chip identifier, required to personalize the image.
    private func uniqueChipID(mounter: OpaquePointer?) throws -> UInt64 {
        var identifiers: plist_t?
        try check(
            "Developer".withCString {
                image_mounter_query_personalization_identifiers(mounter, $0, &identifiers)
            },
            "reading the personalization identifiers"
        )
        defer { if let identifiers { plist_free(identifiers) } }

        guard let identifiers,
              let item = "UniqueChipID".withCString({ plist_dict_get_item(identifiers, $0) })
        else {
            throw BackendError.developerImageUnavailable("chip identifier not found")
        }
        var value: UInt64 = 0
        plist_get_uint_val(item, &value)
        return value
    }

    private struct DeveloperImageFiles {
        var image: Data
        var trustCache: Data
        var manifest: Data
    }

    private nonisolated func developerImageFiles() -> DeveloperImageFiles? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }

        func read(_ name: String) -> Data? {
            try? Data(contentsOf: documents.appendingPathComponent(name))
        }
        guard let image = read("Image.dmg"),
              let trustCache = read("Image.dmg.trustcache"),
              let manifest = read("BuildManifest.plist") else { return nil }
        return DeveloperImageFiles(image: image, trustCache: trustCache, manifest: manifest)
    }

    // MARK: - Locations

    func setLocation(_ coordinate: Coordinate) async throws {
        guard coordinate.isValid else { throw BackendError.invalidCoordinate }
        guard let simulation else { throw BackendError.notPrepared }
        // The modern interface takes floats; the one on older iOS versions
        // expected strings.
        try check(
            location_simulation_set(simulation, coordinate.latitude, coordinate.longitude),
            "sending the location"
        )
    }

    func clearLocation(settlingNear: Coordinate?) async throws {
        guard let simulation else { throw BackendError.notPrepared }
        if let near = settlingNear {
            // Setting a point close to the real one before stopping speeds up
            // the reacquisition of the real signal.
            try? check(location_simulation_set(simulation, near.latitude, near.longitude), "")
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        try check(location_simulation_clear(simulation), "returning to the real location")
    }

    func shutdown() async {
        if let simulation { location_simulation_free(simulation) }
        if let server { remote_server_free(server) }
        simulation = nil
        server = nil
        adapter = nil
        handshake = nil
        eventSink.yield(.health(.idle))
    }

    // MARK: - Errors

    /// Turns a library error code into a Swift error.
    ///
    /// The caller has to free the error, otherwise it leaks on every failure.
    private func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, _ what: String) throws {
        guard let error else { return }
        let code = error.pointee.code
        let message = error.pointee.message.map { String(cString: $0) } ?? "error \(code)"
        idevice_error_free(error)

        eventSink.yield(.health(.lost("\(what): \(message)")))
        throw BackendError.tunnelFailed("\(what) — \(message)")
    }
}

/// Mount progress callback.
///
/// It has to exist even if it does nothing with what it gets: the library calls
/// it systematically while the image is being transferred.
private let mountProgressCallback: @convention(c) (Int, Int, UnsafeMutableRawPointer?) -> Void = {
    progress, total, _ in
    _ = progress
    _ = total
}

/// Small access to the device name and system version, without importing UIKit
/// everywhere.
private enum UIDeviceName {
    static var current: String {
        ProcessInfo.processInfo.hostName
    }
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
