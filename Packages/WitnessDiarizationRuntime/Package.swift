// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WitnessDiarizationRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WitnessDiarizationRuntime", targets: ["WitnessDiarizationRuntime"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.17.7",
            traits: []
        )
    ],
    targets: [
        .target(
            name: "WitnessDiarizationRuntime",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
