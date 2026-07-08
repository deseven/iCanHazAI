// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcessExit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ProcessExit", targets: ["ProcessExit"])
    ],
    targets: [
        .target(
            name: "ProcessExit",
            path: "Sources/ProcessExit"
        )
    ]
)
