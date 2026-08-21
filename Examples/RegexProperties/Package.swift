// swift-tools-version:6.0
import PackageDescription

// Metamorphic relations for the Swift regex engine (_StringProcessing), in
// the style of EMI compiler testing and GraphicsFuzz: rewrite a pattern
// without changing its meaning, and the engine must report the same
// matches. No dependencies beyond hegel-swift; the subject is the standard
// library.
let package = Package(
    name: "RegexProperties",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "RegexPropertyTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift")
            ]
        )
    ]
)
