// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iCanHazAI",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
        .package(url: "https://github.com/deseven/Swift-OpenAI.git", branch: "main"),
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", from: "2.0.0"),
        .package(url: "https://github.com/Frizlab/FSEventsWrapper.git", from: "2.1.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "iCanHazAI",
            dependencies: [
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "OpenAI", package: "Swift-OpenAI"),
                .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
                .product(name: "FSEventsWrapper", package: "FSEventsWrapper"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "src"
        )
    ]
)
