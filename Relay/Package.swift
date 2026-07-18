// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "agentdeck-relay", targets: ["agentdeck-relay"])
    ],
    dependencies: [
        .package(path: "../Packages/Shared"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3")
    ],
    targets: [
        .executableTarget(
            name: "agentdeck-relay",
            dependencies: [
                "RelayCore",
                .product(name: "Shared", package: "Shared")
            ]
        ),
        .target(
            name: "RelayCore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Shared", package: "Shared")
            ]
        ),
        .testTarget(
            name: "RelayTests",
            dependencies: ["RelayCore"]
        )
    ]
)
