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
        // FFI layer over the vendored header + prebuilt release dylib in
        // Vendor/libhegel. See README "Getting libhegel".
        .systemLibrary(name: "CHegel", path: "Sources/CHegel"),
        .target(
            name: "Hegel",
            dependencies: ["CHegel"],
            linkerSettings: [
                .unsafeFlags([
                    "-LVendor/libhegel",
                    // Executables land in .build/<triple>/<config>/ (3 levels
                    // below the package root); .xctest bundles nest their
                    // binary 3 levels deeper still. Cover both.
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Vendor/libhegel",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendor/libhegel",
                ])
            ]
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
