// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoginShell",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LoginShell", targets: ["LoginShell"])
    ],
    targets: [
        .target(
            name: "LoginShell",
            path: "Sources/LoginShell"
        )
    ]
)
