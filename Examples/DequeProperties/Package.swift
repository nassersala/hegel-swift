// swift-tools-version:6.0
import PackageDescription

// Model-based testing of swift-collections' Deque against [Int]: the
// Hughes/Quviq shape with a real library as the subject.
let package = Package(
    name: "DequeProperties",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
    ],
    targets: [
        .testTarget(
            name: "DequePropertiesTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift"),
                .product(name: "DequeModule", package: "swift-collections"),
            ])
    ]
)
