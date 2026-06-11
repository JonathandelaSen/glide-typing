// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlideBoard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GlideBoard",
            path: "Sources/GlideBoard"
        )
    ]
)
