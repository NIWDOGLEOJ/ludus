// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Ludus",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .library(name: "LudusCore", targets: ["OvercrossCore"]),
        .library(name: "OvercrossCore", targets: ["OvercrossCore"]),
        .executable(name: "Ludus", targets: ["OvercrossApp"]),
        .executable(name: "Overcross", targets: ["OvercrossApp"]),
        .executable(name: "LudusTestRunner", targets: ["OvercrossTestRunner"]),
        .executable(name: "OvercrossTestRunner", targets: ["OvercrossTestRunner"])
    ],
    targets: [
        .target(
            name: "OvercrossCore",
            path: "Sources/OvercrossCore",
            swiftSettings: [
                .unsafeFlags(["-enable-testing"])
            ]
        ),
        .executableTarget(
            name: "OvercrossApp",
            dependencies: ["OvercrossCore"],
            path: "Sources/OvercrossApp"
        ),
        .executableTarget(
            name: "OvercrossTestRunner",
            dependencies: ["OvercrossCore"],
            path: "Tests/OvercrossTestRunner"
        )
    ]
)
