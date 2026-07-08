// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeMCP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../../shared/ProcessExit")
    ],
    targets: [
        .executableTarget(
            name: "CodeMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "Sources/CodeMCP"
        )
    ]
)
