import SwiftUI
import AnoleCore
import AnoleServices

@main
struct AnoleApp: App {
    // The Mac backend drives the Python daemon; the iPhone app injects
    // another one, which talks directly to the device's services.
    @StateObject private var model = TripModel(backend: PyMobileDevice3Backend())

    var body: some Scene {
        WindowGroup("Anole") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
