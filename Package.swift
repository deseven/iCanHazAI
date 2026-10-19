// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iCanHazAI",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),

        // Pinned to piersdd's fix branch (upstream PR
        // https://github.com/modelcontextprotocol/swift-sdk/pull/221, approved
        // but not yet merged) instead of the official 0.11.0 release. It fixes
        // a real bug in `Client.connect(transport:)`'s message-handling loop
        .package(url: "https://github.com/piersdd/swift-sdk.git", revision: "1ea8365655f2e7dc25d495b1d75b1de9dfe1975c"),
        // Line-level diffing for rendering write_file tool calls.
        .package(url: "https://github.com/tonyarnold/Differ.git", from: "1.4.4"),

        // CommonMark/GFM parser for the native chat renderer (walked directly).
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.9.0"),
        // Syntax highlighting: tree-sitter bindings plus one grammar package per language
        // (their highlight queries are copied to res/syntax).
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", from: "0.25.0"),
        // Python, JavaScript, CSS, Lua and YAML are pinned exactly: their scanners are
        // vendored in shared/TreeSitterScanners (see there) and must match the parser version.
        .package(url: "https://github.com/tree-sitter/tree-sitter-python.git", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript.git", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java.git", from: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c.git", from: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go.git", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust.git", from: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-php.git", from: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby.git", from: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash.git", from: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html.git", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css.git", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json.git", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml.git", exact: "0.7.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml.git", from: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-lua.git", exact: "0.5.0"),
        // The Swift grammar's releases without generated parser sources are unusable via SwiftPM.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift.git", exact: "0.7.4-with-generated-files"),
        .package(path: "shared/TreeSitterScanners"),
        .package(path: "shared/ProcessExit"),
        .package(path: "shared/LoginShell"),
    ],
    targets: [
        .executableTarget(
            name: "iCanHazAI",
            dependencies: [
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit"),
                .product(name: "LoginShell", package: "LoginShell"),
                .product(name: "Differ", package: "Differ"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterPHP", package: "tree-sitter-php"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterScanners", package: "TreeSitterScanners"),
            ],
            path: "src"
        ),
        .testTarget(
            name: "iCanHazAITests",
            dependencies: [
                .target(name: "iCanHazAI"),
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ProcessExit", package: "ProcessExit"),
                .product(name: "Differ", package: "Differ"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "tests"
        ),
    ]
)
