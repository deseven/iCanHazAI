// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageTools",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ImageTools", targets: ["ImageTools"])
    ],
    targets: [
        .target(
            name: "ImageTools",
            path: "Sources/ImageTools"
        )
    ]
)
