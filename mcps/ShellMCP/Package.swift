// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShellMCP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "ShellMCP",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            path: "Sources/ShellMCP"
        )
    ]
)
