// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WitermCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "WitermCore", targets: ["WitermCore"])],
    targets: [
        .target(name: "WitermCore"),
        .testTarget(name: "WitermCoreTests", dependencies: ["WitermCore"])
    ]
)

