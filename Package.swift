// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GHNotifier",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "GHNotifier",
            path: "Sources/GHNotifier"
        )
    ]
)
