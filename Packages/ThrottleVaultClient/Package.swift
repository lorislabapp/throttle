// swift-tools-version: 6.0
import PackageDescription

// Thin NSXPC client for Throttle's Research Vault, built on the contract
// package only. macOS: mach-service XPC and Code Signing Services are not
// available on iOS.
let package = Package(
    name: "ThrottleVaultClient",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ThrottleVaultClient", targets: ["ThrottleVaultClient"])],
    dependencies: [.package(path: "../ThrottleVaultContract")],
    targets: [
        .target(
            name: "ThrottleVaultClient",
            dependencies: [.product(name: "ThrottleVaultContract", package: "ThrottleVaultContract")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "ThrottleVaultClientTests", dependencies: ["ThrottleVaultClient"],
            resources: [.copy("Fixtures")]
        )
    ]
)
