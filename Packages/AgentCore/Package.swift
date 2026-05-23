// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "82d9cd619a78714dba9d474dbc1c75c65622e710"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            .upToNextMinor(from: "0.31.3")),
        .package(
            url: "https://github.com/huggingface/swift-huggingface",
            .upToNextMajor(from: "0.9.0")),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        .target(
            name: "AgentCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/AgentCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
