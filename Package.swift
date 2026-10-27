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
        .executable(name: "TokenBarWidget", targets: ["TokenBarWidget"]),
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
        .target(
            name: "TokenBarWidgetData",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "TokenBar",
            dependencies: [
                "TokenBarCore",
                "TokenBarWidgetData",
                .product(name: "Vortex", package: "Vortex"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        // `package_app.sh` wraps this executable in the app's WidgetKit extension.
        .executableTarget(
            name: "TokenBarWidget",
            dependencies: ["TokenBarWidgetData"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-application-extension"]),
            ],
            // Like Xcode's extension targets, start in Foundation's extension
            // entry point, which sets up the extension before calling `@main`.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-application_extension",
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                ]),
            ]),
    ])
