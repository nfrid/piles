// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "piles",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PilesCore",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "piles",
            dependencies: ["PilesCore"],
            path: "Entry"
        ),
        .executableTarget(
            name: "piles-ctl",
            dependencies: ["PilesCore"],
            path: "Ctl"
        ),
        .executableTarget(
            name: "piles-tests",
            dependencies: ["PilesCore"],
            path: "Tests"
        ),
    ]
)
