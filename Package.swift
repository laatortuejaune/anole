// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Anole",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Anole", targets: ["AnoleMac"]),
        .library(name: "AnoleCore", targets: ["AnoleCore"]),
        .library(name: "AnoleServices", targets: ["AnoleServices"]),
    ],
    targets: [
        // Core: model, backends. No UI import, testable without a device.
        .target(
            name: "AnoleCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Map and location services, shared with the iPhone application.
        .target(
            name: "AnoleServices",
            dependencies: ["AnoleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SwiftUI + MapKit interface.
        .executableTarget(
            name: "AnoleMac",
            dependencies: ["AnoleCore", "AnoleServices"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AnoleCoreTests",
            dependencies: ["AnoleCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
