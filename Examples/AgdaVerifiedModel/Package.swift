// swift-tools-version:6.0
import PackageDescription

// A proof-carrying-model experiment: Agda checks the abstract transition
// function and its safety theorems, exports the complete finite table, and
// Hegel checks that a Swift implementation refines that exact table.
let package = Package(
    name: "AgdaVerifiedModel",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "AgdaVerifiedModelTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
