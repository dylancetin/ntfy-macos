// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ntfy-macos",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ntfy-macos",
            targets: ["ntfy-macos"]
        )
    ],
    dependencies: [
        // Official Yams 5.4.0; keep the immutable revision and Package.resolved in sync.
        .package(url: "https://github.com/jpsim/Yams.git", revision: "3d6871d5b4a5cd519adf233fbb576e0a2af71c17")
    ],
    targets: [
        .executableTarget(
            name: "ntfy-macos",
            dependencies: ["Yams"],
            path: "Sources"
        ),
        .testTarget(
            name: "ntfy-macosTests",
            dependencies: ["ntfy-macos", "Yams"],
            path: "Tests/ntfy-macosTests"
        )
    ]
)
