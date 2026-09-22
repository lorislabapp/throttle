// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ThrottleCoreEvidence", platforms: [.macOS(.v14)], targets: [
    .target(name: "Throttle", dependencies: ["ThrottleShared", "ThrottleMCPContracts"]),
    .executableTarget(name: "VerificationCrashWorker", dependencies: ["Throttle"]),
    .target(name: "ThrottleShared"),
    .target(name: "ThrottleMCPContracts"),
    .target(name: "ThrottleVaultContract"),
    .target(name: "ResearchVaultModel", dependencies: ["ThrottleVaultContract"]),
    .target(name: "ResearchVaultIPCModel", dependencies: ["ResearchVaultModel", "ThrottleVaultContract"]),
    .target(name: "ResearchVaultIngestion", dependencies: ["ResearchVaultIPCModel"]),
    .testTarget(name: "ThrottleTests", dependencies: ["Throttle", "ThrottleMCPContracts", "VerificationCrashWorker"]),
    .testTarget(name: "ThrottleSharedTests", dependencies: ["ThrottleShared"]),
    .testTarget(name: "ResearchVaultIngestionTests", dependencies: ["ResearchVaultIngestion"]),
])
