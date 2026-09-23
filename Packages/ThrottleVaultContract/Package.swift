// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThrottleVaultContract",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ThrottleVaultContract", targets: ["ThrottleVaultContract"])],
    targets: [
        .target(name: "ThrottleVaultContract"),
        .testTarget(
            name: "ThrottleVaultContractTests", dependencies: ["ThrottleVaultContract"],
            resources: [.copy("Fixtures")]
        )
    ]
)
