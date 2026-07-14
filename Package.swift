// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "TokenBarCore", targets: ["TokenBarCore"]),
        .executable(name: "TokenBar", targets: ["TokenBar"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TokenBarCore",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "TokenBar",
            dependencies: ["TokenBarCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .testTarget(
            name: "TokenBarCoreTests",
            dependencies: ["TokenBarCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]),
    ])
