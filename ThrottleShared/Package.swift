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
        .library(name: "ThrottleShared", targets: ["ThrottleShared"])
    ],
    targets: [
        .target(
            name: "ThrottleShared",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ThrottleSharedTests",
            dependencies: ["ThrottleShared"]
        )
    ]
)
