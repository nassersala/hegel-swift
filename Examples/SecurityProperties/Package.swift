// swift-tools-version:6.0
import PackageDescription

// Security properties as metamorphic relations, after Chen et al.,
// "Metamorphic Testing for Cybersecurity" (IEEE Computer 2016) and Mai,
// Pastore, Goknil, Briand, "Metamorphic Security Testing for Web Systems"
// (ICST 2020): a secure decision must not change when the attacker-
// controlled part of the input changes. Subjects are Apple's own: CryptoKit
// and Foundation's URL handling. No dependencies beyond hegel-swift.
let package = Package(
    name: "SecurityProperties",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "SecurityPropertyTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift")
            ]
        )
    ]
)
