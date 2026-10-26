// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LocalAgentSmoke", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../packages/WitermCore")],
    targets: [
        .executableTarget(name: "LocalAgentSmoke", dependencies: [.product(name: "WitermCore", package: "WitermCore")]),
        .executableTarget(name: "RegisteredServiceProbe", dependencies: [.product(name: "WitermCore", package: "WitermCore")])
    ]
)
