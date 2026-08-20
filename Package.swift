// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "hegel-swift",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "Hegel", targets: ["Hegel"]),
        // Swift Testing sugar (expectAll). A separate product so importing
        // Hegel never links the Testing framework.
        .library(name: "HegelTesting", targets: ["HegelTesting"]),
    ],
    targets: [
        // libhegel v0.32.5 built from the pinned hegel-rust tag and wrapped
        // as a dynamic CHegel.framework per slice (header + module map
        // inside), so consumers need no linker flags, rpaths, or install-
        // name surgery. Rebuild with Scripts/build-xcframework.sh.
        .binaryTarget(name: "CHegel", path: "Vendor/CHegel.xcframework"),
        .target(
            name: "Hegel",
            dependencies: ["CHegel"]
        ),
        .target(
            name: "HegelTesting",
            dependencies: ["Hegel"]
        ),
        .testTarget(
            name: "HegelTests",
            dependencies: ["Hegel", "HegelTesting", "CHegel"]
        ),
    ]
)
