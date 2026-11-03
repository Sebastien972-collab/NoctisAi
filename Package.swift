// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "Noctis",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Noctis",
            targets: ["Noctis"]
        ),
        .executable(
            name: "NoctisCLI",
            targets: ["NoctisCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/adamtheturtle/SafeURLKit.git", exact: "0.2.0"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            from: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            from: "1.3.0"
        ),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/wolfyy970/swift-readability.git",
            .upToNextMinor(from: "0.3.3")
        )
    ],
    targets: [
        .target(
            name: "Noctis",
            dependencies: [
                .product(name: "SafeURLKit", package: "SafeURLKit"),
                .product(
                    name: "MLXLMCommon",
                    package: "mlx-swift-lm"
                ),
                .product(
                    name: "MLXVLM",
                    package: "mlx-swift-lm"
                ),
                .product(
                    name: "MLXHuggingFace",
                    package: "mlx-swift-lm"
                ),
                .product(
                    name: "HuggingFace",
                    package: "swift-huggingface"
                ),
                .product(
                    name: "Tokenizers",
                    package: "swift-transformers"
                ),
                .product(
                    name: "SwiftSoup",
                    package: "SwiftSoup"
                ),
                .product(
                    name: "SwiftReadability",
                    package: "swift-readability"
                )
            ]
        ),
        .executableTarget(
            name: "NoctisCLI",
            dependencies: ["Noctis"]
        ),
        .testTarget(
            name: "NoctisTests",
            dependencies: ["Noctis", "NoctisCLI"]
        )
    ]
)
