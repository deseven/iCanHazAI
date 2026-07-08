// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iCanHazAI",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
        .package(url: "https://github.com/Frizlab/FSEventsWrapper.git", from: "2.1.0"),
        // Pinned to piersdd's fix branch (upstream PR
        // https://github.com/modelcontextprotocol/swift-sdk/pull/221, approved
        // but not yet merged) instead of the official 0.11.0 release. It fixes
        // a real bug in `Client.connect(transport:)`'s message-handling loop
        .package(url: "https://github.com/piersdd/swift-sdk.git", revision: "1ea8365655f2e7dc25d495b1d75b1de9dfe1975c"),
        .package(path: "shared/ProcessExit")
    ],
    targets: [
        .executableTarget(
            name: "iCanHazAI",
            dependencies: [
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "FSEventsWrapper", package: "FSEventsWrapper"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "src"
        ),
        .testTarget(
            name: "iCanHazAITests",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "tests"
        )
    ]
)
