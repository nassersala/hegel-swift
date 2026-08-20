// swift-tools-version:6.0
import PackageDescription
import Foundation

// Dogfood harness: property-based tests for adhan-swift, written with
// hegel-swift. Lives inside the hegel-swift repo as a worked example.
//
// The vendored libhegel dylib lives two directories up; the manifest
// computes absolute paths so `swift test` works from anywhere. (This is
// the packaging wart the binaryTarget roadmap item will remove.)
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorDir = "\(packageDir)/../../Vendor/libhegel"

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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorDir)",
                    "-Xlinker", "-rpath", "-Xlinker", vendorDir,
                ])
            ]
        )
    ]
)
