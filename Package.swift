// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndOnMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AndroidShadowGraphKit",
            targets: ["AndroidShadowGraphKit"]
        ),
        .executable(
            name: "AndOnMac",
            targets: ["AndOnMac"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AndroidShadowGraphKit",
            path: "Sources/AndroidShadowGraphKit"
        ),
        .executableTarget(
            name: "AndOnMac",
            dependencies: ["AndroidShadowGraphKit"],
            path: "Sources/AndOnMac",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AndOnMacTests",
            dependencies: ["AndOnMac", "AndroidShadowGraphKit"],
            path: "Tests/AndOnMacTests"
        ),
        .testTarget(
            name: "AndroidShadowGraphKitTests",
            dependencies: ["AndroidShadowGraphKit"],
            path: "Tests/AndroidShadowGraphKitTests"
        )
    ]
)
