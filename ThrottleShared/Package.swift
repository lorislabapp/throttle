// swift-tools-version: 6.0
import PackageDescription

// Shared contract between the Throttle macOS app (publisher) and the
// Throttle iOS companion (subscriber). Pure Foundation + CloudKit mapping —
// NO AppKit/UIKit/SwiftTerm, so it compiles identically on both platforms and
// the snapshot payload can never drift between the two ends of the mirror.
let package = Package(
    name: "ThrottleShared",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ThrottleShared", targets: ["ThrottleShared"]),
        // LAN peer link (Bonjour + TLS-PSK) that mirrors the same snapshot to the
        // iOS companion sub-second on the same network. Separate target so the
        // Network/CryptoKit deps stay out of the pure contract library.
        .library(name: "ThrottlePeer", targets: ["ThrottlePeer"])
    ],
    targets: [
        .target(
            name: "ThrottleShared",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ThrottlePeer",
            dependencies: ["ThrottleShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThrottleSharedTests",
            dependencies: ["ThrottleShared"]
        ),
        .testTarget(
            name: "ThrottlePeerTests",
            dependencies: ["ThrottlePeer"]
        )
    ]
)
