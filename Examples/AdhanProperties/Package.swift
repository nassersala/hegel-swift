// swift-tools-version:6.0
import PackageDescription

// Dogfood harness: property-based tests for adhan-swift, written with
// hegel-swift. Lives inside the hegel-swift repo as a worked example.
// libhegel arrives through hegel-swift's CHegel binary target — no linker
// flags or rpaths needed here.
let package = Package(
    name: "AdhanProperties",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/batoulapps/adhan-swift", from: "1.5.0"),
    ],
    targets: [
        .testTarget(
            name: "AdhanPropertyTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift"),
                .product(name: "HegelTesting", package: "hegel-swift"),
                .product(name: "Adhan", package: "adhan-swift"),
            ]
        )
    ]
)
