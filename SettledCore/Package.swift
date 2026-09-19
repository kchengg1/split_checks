// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SettledCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SettledCore", targets: ["SettledCore"])
    ],
    targets: [
        .target(name: "SettledCore"),
        .testTarget(name: "SettledCoreTests", dependencies: ["SettledCore"])
    ]
)
