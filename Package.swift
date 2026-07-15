// swift-tools-version: 5.10
import PackageDescription

// Note: tests are a plain executable runner (swift run maceq-tests) because the
// Command Line Tools toolchain ships neither XCTest nor swift-testing.
let package = Package(
    name: "MacEQ",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .target(
            name: "MacEQCore",
            path: "Sources/MacEQCore"
        ),
        .executableTarget(
            name: "MacEQ",
            dependencies: ["MacEQCore"],
            path: "Sources/MacEQ"
        ),
        .executableTarget(
            name: "maceq-tests",
            dependencies: ["MacEQCore"],
            path: "Tests/MacEQTests"
        ),
    ]
)
