// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Paceline",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Paceline", path: "Sources/Paceline")
    ]
)
