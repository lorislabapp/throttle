// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThrottleMirrorContract",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ThrottleMirrorContract", targets: ["ThrottleMirrorContract"])],
    targets: [
        .target(name: "ThrottleMirrorContract"),
        .testTarget(
            name: "ThrottleMirrorContractTests", dependencies: ["ThrottleMirrorContract"],
            resources: [.copy("Fixtures")]
        )
    ]
)
