// swift-tools-version:6.0
import PackageDescription

// Algebraic laws on swift-numerics' Complex<Double>: the field laws under
// the library's own approximate equality, the laws that fail for a reason
// (branch cuts, cancellation), and probes at the edges of the
// representation. No oracle anywhere; every property is a law.
let package = Package(
    name: "ComplexProperties",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
    ],
    targets: [
        .testTarget(
            name: "ComplexPropertyTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift"),
                .product(name: "ComplexModule", package: "swift-numerics"),
                .product(name: "RealModule", package: "swift-numerics"),
            ]
        )
    ]
)
