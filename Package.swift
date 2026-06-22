// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iCanHazAI",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
        .package(url: "https://github.com/LimChihi/OpenAI.git", branch: "feature/vendor-parameters"),
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", from: "2.0.0"),
        .package(url: "https://github.com/gonzalezreal/textual.git", from: "0.5.0"),
        .package(url: "https://github.com/Frizlab/FSEventsWrapper.git", from: "2.1.0")
    ],
    targets: [
        .executableTarget(
            name: "iCanHazAI",
            dependencies: [
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
                .product(name: "Textual", package: "textual"),
                .product(name: "FSEventsWrapper", package: "FSEventsWrapper")
            ],
            path: "src"
        )
    ]
)
