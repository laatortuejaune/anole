import SwiftUI
import AnoleCore
import AnoleServices

@main
struct AnoleApp: App {
    // Same logic as on the Mac, with the backend talking directly to this
    // device's services instead of driving a remote daemon.
    @StateObject private var model = TripModel(backend: IDeviceBackend())

    var body: some Scene {
        WindowGroup {
            iOSContentView()
                .environmentObject(model)
        }
    }
}
