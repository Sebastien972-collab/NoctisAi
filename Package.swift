// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Created by Sébastien DAGUIN
import PackageDescription

let package = Package(
    name: "Noctis",
    defaultLocalization: "fr",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
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
        .package(path: "NoctisAgent"),
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
        ),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.99.3"
        ),
    ],
    targets: [
        .target(
            name: "Noctis",
            dependencies: [
                .product(name: "NoctisAgent", package: "NoctisAgent"),
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
                ),
                .product(
                    name: "SwiftTerm",
                    package: "SwiftTerm",
                    condition: .when(platforms: [.macOS])
                ),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "NoctisCLI",
            dependencies: ["Noctis", .product(name: "NoctisAgent", package: "NoctisAgent")],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NoctisTests",
            dependencies: ["Noctis", "NoctisCLI", .product(name: "NoctisAgent", package: "NoctisAgent")]
        )
    ]
)
