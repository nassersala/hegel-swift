// swift-tools-version:6.0
import PackageDescription

// Differential-conformance harness: emits a deterministic draw transcript
// (seed 42, derandomized, database off) to compare byte-for-byte against
// the hegel-go harness next door. See Scripts/conformance.sh.
let package = Package(
    name: "transcript-swift",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "transcript-swift",
            dependencies: [.product(name: "Hegel", package: "hegel-swift")]
        )
    ]
)
