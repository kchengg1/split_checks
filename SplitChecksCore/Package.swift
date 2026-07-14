// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SplitChecksCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SplitChecksCore", targets: ["SplitChecksCore"])
    ],
    targets: [
        .target(name: "SplitChecksCore"),
        .testTarget(name: "SplitChecksCoreTests", dependencies: ["SplitChecksCore"])
    ]
)
