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
    dependencies: [
        .package(
            url: "https://github.com/zats/Vortex",
            revision: "ef5392088d4aeb255c4eee83157dbdafcd31bf07"),
    ],
    targets: [
        .target(
            name: "TokenBarCore",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "TokenBar",
            dependencies: [
                "TokenBarCore",
                .product(name: "Vortex", package: "Vortex"),
            ],
            resources: [
                .process("Resources"),
            ],
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
        .testTarget(
            name: "TokenBarTests",
            dependencies: ["TokenBar"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]),
    ])
