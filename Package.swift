// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OzWC",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OzWC", targets: ["OzWC"]),
    ],
    targets: [
        // Pure logic (layout, gestures, settings). No AppKit, unit-tested.
        .target(name: "OzCore"),
        .executableTarget(
            name: "OzWC",
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
