// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResearchVaultKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ResearchVaultModel", targets: ["ResearchVaultModel"]),
        .library(name: "ResearchVaultReasoning", targets: ["ResearchVaultReasoning"]),
        .library(name: "ResearchVaultIPCModel", targets: ["ResearchVaultIPCModel"]),
        .library(name: "ResearchVaultSynthesis", targets: ["ResearchVaultSynthesis"]),
        .library(name: "ResearchVaultXPCClient", targets: ["ResearchVaultXPCClient"]),
        .library(name: "ResearchVaultXPC", targets: ["ResearchVaultXPC"]),
        .library(name: "ResearchVaultServiceRuntime", targets: ["ResearchVaultServiceRuntime"]),
        .library(name: "ResearchVaultStore", targets: ["ResearchVaultStore"]),
        .library(name: "ResearchVaultSQLCipher", targets: ["ResearchVaultSQLCipher"]),
        .library(name: "ResearchVaultKeychain", targets: ["ResearchVaultKeychain"]),
        .library(name: "ResearchVaultIngestion", targets: ["ResearchVaultIngestion"]),
        .library(name: "ResearchVaultGateway", targets: ["ResearchVaultGateway"]),
        .library(name: "ResearchVaultMCP", targets: ["ResearchVaultMCP"]),
        .executable(name: "research-vault-crash-probe", targets: ["research-vault-crash-probe"]),
        .executable(name: "research-vault-catalog-probe", targets: ["research-vault-catalog-probe"]),
        .executable(name: "research-vault-benchmark", targets: ["research-vault-benchmark"]),
        .executable(
            name: "research-vault-synthesis-security-probe",
            targets: ["research-vault-synthesis-security-probe"]
        ),
        .executable(name: "research-vault-mcp", targets: ["research-vault-mcp"]),
        .executable(name: "research-vault-agent-hook", targets: ["research-vault-agent-hook"]),
        .executable(
            name: "research-vault-reasoning-differential",
            targets: ["research-vault-reasoning-differential"]
        ),
        .executable(
            name: "research-vault-reasoning-benchmark",
            targets: ["research-vault-reasoning-benchmark"]
        ),
        .executable(name: "research-vault-xpc-service", targets: ["research-vault-xpc-service"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sqlcipher/SQLCipher.swift.git",
            exact: "4.18.0"
        ),
    ],
    targets: [
        .target(name: "ResearchVaultModel"),
        .target(
            name: "ResearchVaultReasoning",
            dependencies: ["ResearchVaultModel"]
        ),
        .target(
            name: "ResearchVaultIPCModel",
            dependencies: ["ResearchVaultModel"]
        ),
        .target(
            name: "ResearchVaultSynthesis",
            dependencies: ["ResearchVaultIPCModel", "ResearchVaultModel"]
        ),
        .target(
            name: "ResearchVaultXPCClient",
            dependencies: ["ResearchVaultIPCModel", "ResearchVaultModel"],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "ResearchVaultXPC",
            dependencies: [
                "ResearchVaultXPCClient", "ResearchVaultIPCModel", "ResearchVaultGateway",
            ]
        ),
        .target(
            name: "ResearchVaultStore",
            dependencies: ["ResearchVaultModel"]
        ),
        .target(
            name: "ResearchVaultSQLCipher",
            dependencies: [
                "ResearchVaultModel",
                "ResearchVaultReasoning",
                "ResearchVaultStore",
                "ResearchVaultIngestion",
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
            ]
        ),
        .target(
            name: "ResearchVaultKeychain",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "ResearchVaultIngestion",
            dependencies: ["ResearchVaultIPCModel", "ResearchVaultModel"]
        ),
        .target(
            name: "ResearchVaultGateway",
            dependencies: [
                "ResearchVaultModel", "ResearchVaultIPCModel", "ResearchVaultIngestion",
                "ResearchVaultReasoning", "ResearchVaultSQLCipher",
            ]
        ),
        .target(
            name: "ResearchVaultServiceRuntime",
            dependencies: [
                "ResearchVaultXPC", "ResearchVaultGateway", "ResearchVaultKeychain",
                "ResearchVaultModel", "ResearchVaultStore", "ResearchVaultSQLCipher",
            ]
        ),
        .target(
            name: "ResearchVaultMCP",
            dependencies: [
                "ResearchVaultGateway", "ResearchVaultIngestion", "ResearchVaultIPCModel",
                "ResearchVaultModel",
                "ResearchVaultSQLCipher",
            ]
        ),
        .executableTarget(
            name: "research-vault-crash-probe",
            dependencies: ["ResearchVaultSQLCipher"]
        ),
        .executableTarget(
            name: "research-vault-catalog-probe",
            dependencies: ["ResearchVaultIngestion"]
        ),
        .executableTarget(
            name: "research-vault-benchmark",
            dependencies: ["ResearchVaultIngestion", "ResearchVaultSQLCipher"]
        ),
        .executableTarget(
            name: "research-vault-synthesis-security-probe",
            dependencies: ["ResearchVaultSynthesis"]
        ),
        .executableTarget(
            name: "research-vault-mcp",
            dependencies: [
                "ResearchVaultMCP", "ResearchVaultGateway", "ResearchVaultKeychain",
                "ResearchVaultStore", "ResearchVaultSQLCipher",
            ]
        ),
        .executableTarget(
            name: "research-vault-agent-hook",
            dependencies: ["ResearchVaultMCP"]
        ),
        .executableTarget(
            name: "research-vault-reasoning-differential",
            dependencies: ["ResearchVaultReasoning"]
        ),
        .executableTarget(
            name: "research-vault-reasoning-benchmark",
            dependencies: ["ResearchVaultReasoning"]
        ),
        .executableTarget(
            name: "research-vault-xpc-service",
            dependencies: ["ResearchVaultServiceRuntime"]
        ),
        .testTarget(
            name: "ResearchVaultModelTests",
            dependencies: ["ResearchVaultModel"]
        ),
        .testTarget(
            name: "ResearchVaultReasoningTests",
            dependencies: ["ResearchVaultReasoning"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "ResearchVaultIPCModelTests",
            dependencies: ["ResearchVaultIPCModel"]
        ),
        .testTarget(
            name: "ResearchVaultSynthesisTests",
            dependencies: ["ResearchVaultSynthesis"]
        ),
        .testTarget(
            name: "ResearchVaultSynthesisSecurityTests",
            dependencies: ["ResearchVaultSynthesis"]
        ),
        .testTarget(
            name: "ResearchVaultXPCTests",
            dependencies: [
                "ResearchVaultXPCClient", "ResearchVaultXPC",
                "ResearchVaultServiceRuntime",
            ]
        ),
        .testTarget(
            name: "ResearchVaultStoreTests",
            dependencies: ["ResearchVaultModel", "ResearchVaultStore"]
        ),
        .testTarget(
            name: "ResearchVaultSQLCipherTests",
            dependencies: [
                "ResearchVaultModel", "ResearchVaultReasoning", "ResearchVaultStore",
                "ResearchVaultSQLCipher",
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            cSettings: [.define("SQLITE_HAS_CODEC")]
        ),
        .testTarget(
            name: "ResearchVaultOwnerSecurityTests",
            dependencies: ["ResearchVaultModel", "ResearchVaultStore", "ResearchVaultSQLCipher"]
        ),
        .testTarget(
            name: "ResearchVaultKeychainTests",
            dependencies: ["ResearchVaultKeychain"]
        ),
        .testTarget(
            name: "ResearchVaultIngestionTests",
            dependencies: ["ResearchVaultIngestion"]
        ),
        .testTarget(
            name: "ResearchVaultGatewayTests",
            dependencies: [
                "ResearchVaultGateway", "ResearchVaultSQLCipher", "ResearchVaultIngestion",
                "ResearchVaultReasoning",
            ]
        ),
        .testTarget(
            name: "ResearchVaultMCPTests",
            dependencies: [
                "ResearchVaultMCP", "ResearchVaultGateway", "ResearchVaultSQLCipher",
                "ResearchVaultIngestion", "ResearchVaultIPCModel",
            ]
        ),
    ]
)
