// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndOnMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AndOnMac",
            targets: ["AndOnMac"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AndOnMac",
            path: "Sources/AndOnMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AndOnMacTests",
            dependencies: ["AndOnMac"],
            path: "Tests/AndOnMacTests"
        )
    ]
)
