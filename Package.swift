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
        .package(path: "shared/ProcessExit"),
        .package(path: "shared/LoginShell"),
        .package(path: "shared/ImageTools")
    ],
    targets: [
        .executableTarget(
            name: "iCanHazAI",
            dependencies: [
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "FSEventsWrapper", package: "FSEventsWrapper"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit"),
                .product(name: "LoginShell", package: "LoginShell")
            ],
            path: "src"
        ),
        // Bundled stdio MCP servers. Each is an independent executable copied
        // into the app bundle under Contents/Resources/MCPServers/. Built as
        // one SwiftPM graph with the app; build a single server on demand with
        // `swift build --target iCanHazAI-UtilsMCP`. Product names are prefixed
        // with `iCanHazAI-` so the spawned processes are distinguishable from
        // unrelated system processes in `ps` / Activity Monitor.
        .executableTarget(
            name: "iCanHazAI-UtilsMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "mcps/UtilsMCP/Sources/UtilsMCP"
        ),
        .executableTarget(
            name: "iCanHazAI-FilesystemMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ImageTools", package: "ImageTools"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "mcps/FilesystemMCP/Sources/FilesystemMCP"
        ),
        .executableTarget(
            name: "iCanHazAI-CodeMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit")
            ],
            path: "mcps/CodeMCP/Sources/CodeMCP"
        ),
        .executableTarget(
            name: "iCanHazAI-ShellMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit"),
                .product(name: "LoginShell", package: "LoginShell")
            ],
            path: "mcps/ShellMCP/Sources/ShellMCP"
        ),
        .testTarget(
            name: "iCanHazAITests",
            dependencies: [
                .target(name: "iCanHazAI"),
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit"),
                .product(name: "FSEventsWrapper", package: "FSEventsWrapper")
            ],
            path: "tests"
        )
    ]
)
