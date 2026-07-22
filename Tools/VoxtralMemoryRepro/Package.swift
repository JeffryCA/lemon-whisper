// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoxtralMemoryRepro",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "voxtral-memory-repro", targets: ["VoxtralMemoryRepro"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.6"
        ),
        .package(
            url: "https://github.com/VincentGourbin/mlx-voxtral-swift",
            exact: "2.2.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "VoxtralMemoryRepro",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "VoxtralCore", package: "mlx-voxtral-swift")
            ]
        ),
        .testTarget(
            name: "VoxtralMemoryReproTests",
            dependencies: ["VoxtralMemoryRepro"]
        )
    ]
)
