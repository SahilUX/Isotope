// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "IsotopeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IsotopeCore", targets: ["IsotopeCore"])
    ],
    targets: [
        // Platform-agnostic: Foundation only. No SwiftUI/AppKit/CryptoKit/DiskArbitration,
        // so a future Linux client can reuse this target unchanged.
        .target(name: "IsotopeCore"),
        // Developer-only live catalog check (DESIGN §7); not part of the app product.
        .executableTarget(name: "verify-catalog", dependencies: ["IsotopeCore"], path: "Sources/VerifyCatalog"),
        .testTarget(name: "IsotopeCoreTests", dependencies: ["IsotopeCore"],
                    resources: [.copy("Fixtures")])
    ]
)
