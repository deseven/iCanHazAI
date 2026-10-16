// swift-tools-version: 6.0
import PackageDescription

// The upstream Package.swift of these grammars adds `src/scanner.c` only
// `if FileManager.default.fileExists(atPath: "src/scanner.c")`, a path relative to
// the manifest *process'* working directory, so the external scanner is never compiled and
// linking fails. This package compiles those scanners instead.
//
// Each scanner is an unmodified copy from the grammar release pinned in the app's Package.swift
// (an exact version there, so parser and scanner can't drift apart):
//   python 0.25.0, javascript 0.25.0, css 0.25.0 (tree-sitter org, MIT)
//   lua 0.5.0, yaml 0.7.2 (tree-sitter-grammars org, MIT)
// Each folder carries the grammar's LICENSE.

private func scanner(_ name: String, exclude: [String] = []) -> Target {
    .target(
        name: "Scanner\(name)",
        path: "Sources/Scanner\(name)",
        exclude: ["LICENSE"] + exclude,
        sources: ["scanner.c"],
        publicHeadersPath: "include",
        cSettings: [.headerSearchPath(".")]
    )
}

let package = Package(
    name: "TreeSitterScanners",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "TreeSitterScanners",
            targets: ["ScannerPython", "ScannerJavaScript", "ScannerCSS", "ScannerLua", "ScannerYAML"])
    ],
    targets: [
        scanner("Python"),
        scanner("JavaScript"),
        scanner("CSS"),
        scanner("Lua"),
        // The YAML scanner `#include`s its schema tables.
        scanner("YAML", exclude: ["schema.core.c", "schema.json.c", "schema.legacy.c"]),
    ]
)
