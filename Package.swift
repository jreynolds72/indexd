// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "indexd",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ABSCore", targets: ["ABSCore"]),
        .executable(name: "indexd", targets: ["ABSClientMac"])
    ],
    targets: [
        .target(
            name: "ABSCore",
            path: "Sources/ABSCore"
        ),
        .executableTarget(
            name: "ABSClientMac",
            dependencies: ["ABSCore"],
            path: "Sources/ABSClientMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ABSCoreTests",
            dependencies: ["ABSCore"],
            path: "Tests/ABSCoreTests"
        )
    ]
)
