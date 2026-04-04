// swift-tools-version: 5.4
// Prefer `./build.sh` if `swift build` fails (SwiftPM may require full Xcode / xctest).
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "ClaudeNotch", targets: ["ClaudeNotch"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            path: "Sources/ClaudeNotch"
        ),
    ]
)
