// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShellMCP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../../shared/ProcessExit")
    ],
    targets: [
        .executableTarget(
            name: "ShellMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "Sources/ShellMCP"
        )
    ]
)
