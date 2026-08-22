import SwiftUI
import AnoleCore
import AnoleServices

@main
struct AnoleApp: App {
    // Same logic as on the Mac, with the backend talking directly to this
    // device's services instead of driving a remote daemon.
    @StateObject private var model = TripModel(backend: IDeviceBackend())

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            iOSContentView()
                .environmentObject(model)
        }
        // The whole point of the on-device app is to affect *other* apps, which
        // means leaving this one. iOS suspends us then, and the location stops
        // being pushed - unavoidable without a background mode, which a free
        // developer account cannot have. What is avoidable is coming back to a
        // trip that jumped forward by however long the phone was elsewhere.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.applicationDidBecomeActive()
            case .inactive, .background: model.applicationWillResignActive()
            @unknown default: break
            }
        }
    }
}
