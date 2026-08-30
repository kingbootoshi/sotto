// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "Sotto",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Sotto"
        )
    ]
)
