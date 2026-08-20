// swift-tools-version:6.0
import PackageDescription

// Affordance-correctness example: property-tests that a UI's enabled/disabled
// state tells the truth about the underlying state machine. Lives inside the
// hegel-swift repo as a worked example, like AdhanProperties.
let package = Package(
    name: "AffordanceProperties",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "AffordancePropertyTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift")
            ]
        )
    ]
)
