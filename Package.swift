// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Launcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Launcher",
            path: "Sources/Launcher"
        )
    ]
)
