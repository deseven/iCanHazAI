// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FilesystemMCP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../../shared/ImageTools"),
        .package(path: "../../shared/ProcessExit")
    ],
    targets: [
        .executableTarget(
            name: "FilesystemMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ImageTools", package: "ImageTools"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "Sources/FilesystemMCP"
        )
    ]
)
