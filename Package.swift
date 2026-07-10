// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GlideBoard",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        // All app logic lives in the library so the checks runner can import
        // it (@testable works in debug builds, where testability is on).
        .target(
            name: "GlideBoardCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/GlideBoardCore"
        ),
        .executableTarget(
            name: "GlideBoard",
            dependencies: ["GlideBoardCore"],
            path: "Sources/GlideBoard"
        ),
        // Self-contained test runner: the CommandLineTools toolchain ships
        // neither XCTest nor swift-testing, so checks run as a plain
        // executable (see Tests/GlideBoardChecks/Harness.swift). Run with
        // ./test.sh (or `swift run GlideBoardChecks` from the repo root, so
        // word lists resolve via cwd).
        .executableTarget(
            name: "GlideBoardChecks",
            dependencies: ["GlideBoardCore"],
            path: "Tests/GlideBoardChecks"
        )
    ]
)
