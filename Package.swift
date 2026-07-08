// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GlideBoard",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "GlideBoard",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/GlideBoard"
        ),
        .testTarget(
            name: "GlideBoardTests",
            dependencies: ["GlideBoard"],
            path: "Tests/GlideBoardTests"
        )
    ]
)
