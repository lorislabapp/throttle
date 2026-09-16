// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThrottlePeerProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ThrottlePeerProtocol", targets: ["ThrottlePeerProtocol"])
    ],
    targets: [
        .target(name: "ThrottlePeerProtocol"),
        .testTarget(name: "ThrottlePeerProtocolTests", dependencies: ["ThrottlePeerProtocol"])
    ]
)
