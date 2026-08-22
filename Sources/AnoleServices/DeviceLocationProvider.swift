import Foundation
import CoreLocation
import AnoleCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Real location of the device the application runs on.
///
/// A Mac has no GPS chip: the location comes from Wi-Fi positioning, accurate
/// to a few dozen meters at best. On iPhone it is far finer. In both cases it
/// serves as a plausible starting point.
@MainActor
public final class DeviceLocationProvider: NSObject, ObservableObject {

    public struct Fix: Equatable {
        public var coordinate: Coordinate
        /// Uncertainty radius in meters.
        public var accuracy: Double
        public var date: Date
    }

    public enum State: Equatable {
        case idle
        case waitingForPermission
        case locating
        case ready(Fix)
        case denied
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var fix: Fix?

    private let manager = CLLocationManager()
    /// A request has been made and is waiting for the authorization to be settled.
    private var requestPending = false

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Asks for the location. Without authorization, the request is put on hold
    /// and will resume on its own once the user has answered.
    public func request() {
        requestPending = true

        // Never read authorizationStatus synchronously to decide: at launch it
        // reads "not determined" for one or two seconds even when the
        // authorization is already granted. The delegate is what counts.
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .waitingForPermission
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
            requestPending = false
        case .authorizedAlways, .authorizedWhenInUse:
            startLocating()
        @unknown default:
            state = .waitingForPermission
            manager.requestWhenInUseAuthorization()
        }
    }

    private func startLocating() {
        guard requestPending else { return }
        // At reduced accuracy, the location is rounded to several kilometers
        // and can be several minutes old: unusable as a starting point.
        guard manager.accuracyAuthorization == .fullAccuracy else {
            state = .failed(AnoleError.locationReducedAccuracy.errorDescription ?? "")
            requestPending = false
            return
        }
        state = .locating
        manager.requestLocation()
    }

    /// Asks for the location and waits for it to arrive.
    ///
    /// The first fix takes one or two seconds: the authorization gets settled,
    /// then Wi-Fi positioning has to succeed. A route that starts from "home"
    /// must therefore be able to wait.
    public func currentFix(timeout: TimeInterval = 8) async -> Fix? {
        if let fix, Date().timeIntervalSince(fix.date) < 120 { return fix }

        request()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let fix { return fix }
            if case .denied = state { return nil }
            if case .failed = state { return nil }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return fix
    }

    /// Opens the settings where the user can fix the authorization.
    public static func openSettings() {
        #if os(macOS)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        if let url { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

extension DeviceLocationProvider: CLLocationManagerDelegate {

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                self.startLocating()
            case .denied, .restricted:
                self.state = .denied
                self.requestPending = false
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        let horizontal = location.horizontalAccuracy
        let coordinate = Coordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            // On a Mac the vertical accuracy is -1: copying the altitude over
            // would inject a bogus value of 0 m.
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
        )
        let timestamp = location.timestamp

        MainActor.assumeIsolated {
            self.requestPending = false

            guard horizontal > 0 else {
                self.state = .failed(AnoleError.locationUnavailable("zero accuracy").errorDescription ?? "")
                return
            }
            // Without a Wi-Fi radio, macOS falls back on IP address
            // geolocation, accurate to the city, and reports no error.
            guard horizontal <= 500 else {
                self.state = .failed(
                    AnoleError.locationTooImprecise(Int(horizontal)).errorDescription ?? ""
                )
                return
            }

            let fix = Fix(coordinate: coordinate, accuracy: horizontal, date: timestamp)
            self.fix = fix
            self.state = .ready(fix)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let message = (error as NSError).localizedDescription
        MainActor.assumeIsolated {
            self.requestPending = false
            self.state = .failed(message)
        }
    }
}

