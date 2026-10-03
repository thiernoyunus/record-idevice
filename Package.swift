// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecordIDevice",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "RecordIDevice",
            resources: [.copy("Resources/Wallpapers")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
