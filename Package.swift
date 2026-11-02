// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "Noctis",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "Noctis",
            targets: ["Noctis"]
        )
    ],
    dependencies: [
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
        )
    ],
    targets: [
        .executableTarget(
            name: "Noctis",
            dependencies: [
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
                )
            ]
        ),
        .testTarget(
            name: "NoctisTests",
            dependencies: ["Noctis"]
        )
    ]
)
