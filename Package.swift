// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OzWM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OzWM", targets: ["OzWM"]),
    ],
    targets: [
        // Pure logic (layout, gestures, settings). No AppKit, unit-tested.
        .target(name: "OzCore"),
        .executableTarget(
            name: "OzWM",
            dependencies: ["OzCore"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "OzCoreTests", dependencies: ["OzCore"]),
    ]
)
