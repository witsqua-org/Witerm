// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WitermAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "witerm-agent", targets: ["WitermAgent"])],
    dependencies: [.package(path: "../../packages/WitermCore")],
    targets: [
        .executableTarget(name: "WitermAgent", dependencies: [.product(name: "WitermCore", package: "WitermCore")]),
        .testTarget(name: "WitermAgentTests", dependencies: ["WitermAgent", .product(name: "WitermCore", package: "WitermCore")])
    ]
)
