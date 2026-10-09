// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Underlay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Underlay",
            path: "Sources/Underlay"
        ),
    ]
)
