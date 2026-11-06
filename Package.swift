// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Zbar", path: "Sources/Zbar")
    ]
)
