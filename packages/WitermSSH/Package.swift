// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WitermSSH",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "WitermSSH", targets: ["WitermSSH"])],
    dependencies: [
        .package(path: "../../vendor/Citadel"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(name: "WitermSSH", dependencies: [
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .testTarget(name: "WitermSSHTests", dependencies: [
            "WitermSSH", .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "Citadel", package: "Citadel")
        ])
    ]
)
