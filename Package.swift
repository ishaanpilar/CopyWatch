// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopyWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CopyWatch",
            path: "Sources/CopyWatch",
            exclude: [
                "App/AGENTS.md",
                "Engine/AGENTS.md",
                "Models/AGENTS.md",
                "Store/AGENTS.md",
                "System/AGENTS.md",
                "Views/AGENTS.md",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CopyWatchTests",
            dependencies: ["CopyWatch"],
            path: "Tests/CopyWatchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
