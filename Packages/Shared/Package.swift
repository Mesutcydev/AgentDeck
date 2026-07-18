// swift-tools-version: 6.2
import PackageDescription

// AgentDeck shared foundations package (SPEC §8 component 3, §29 Phase 1).
// System frameworks only — no third-party dependencies (SPEC §26).
let package = Package(
    name: "Shared",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "Shared", targets: ["Shared"])
    ],
    targets: [
        .target(
            name: "Shared",
            swiftSettings: [
                // Swift 6 language mode (default for tools-version 6.x) already
                // implies complete strict concurrency; kept explicit per SPEC §6.
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SharedTests",
            dependencies: ["Shared"]
        )
    ]
)
