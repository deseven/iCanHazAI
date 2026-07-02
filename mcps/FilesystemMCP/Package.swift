// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FilesystemMCP",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../Shared/ImageTools")
    ],
    targets: [
        .executableTarget(
            name: "FilesystemMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ImageTools", package: "ImageTools")
            ],
            path: "Sources/FilesystemMCP"
        )
    ]
)
