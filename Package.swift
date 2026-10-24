// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GitHubMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GitHubMonitor", path: "Sources/GitHubMonitor")
    ]
)
