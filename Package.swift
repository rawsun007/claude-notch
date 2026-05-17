// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeNotch", targets: ["ClaudeNotch"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            path: "Sources/ClaudeNotch"
        )
    ]
)
