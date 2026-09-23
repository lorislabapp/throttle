// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThrottleMCPContracts",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ThrottleMCPContracts", targets: ["ThrottleMCPContracts"])
    ],
    targets: [
        .target(name: "ThrottleMCPContracts"),
        .testTarget(
            name: "ThrottleMCPContractsTests",
            dependencies: ["ThrottleMCPContracts"],
            resources: [.copy("Fixtures")]
        )
    ]
)
