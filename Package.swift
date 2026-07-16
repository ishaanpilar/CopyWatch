// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopyWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CopyWatch",
            path: "Sources/CopyWatch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
