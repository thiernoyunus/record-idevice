// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecordIDevice",
    platforms: [.macOS(.v15)],
    dependencies: [
        // In-app updates (direct download, not the App Store).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "RecordIDevice",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/Wallpapers")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // build.sh copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
