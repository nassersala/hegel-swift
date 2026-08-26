// swift-tools-version:6.0
import PackageDescription

// Laws for swift-async-algorithms operators, checked on the library's own
// deterministic validation runtime (a fake clock and a controlled job
// queue), so every failure shrinks and replays like any hegel test.
//
// `AsyncSequenceValidation` is vendored from swift-async-algorithms 1.1.5
// (Vendor/, Apache-2.0 with Runtime Library Exception; see
// Vendor/LICENSE.txt): upstream ships it as a test-only target, not a
// product. The one file added on top is Vendor/AsyncSequenceValidation/
// Programmatic.swift, which exposes the runtime to generated scripts.
// The runtime installs the process-global `swift_task_enqueueGlobal_hook`
// while a diagram runs, so tests that use it are serialized.

let availabilityMacros: [SwiftSetting] = [
    .enableExperimentalFeature(
        "AvailabilityMacro=AsyncAlgorithms 1.0:macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0"),
    .enableExperimentalFeature(
        "AvailabilityMacro=AsyncAlgorithms 1.1:macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0"),
    .enableExperimentalFeature(
        "AvailabilityMacro=AsyncAlgorithms 1.2:macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0"),
    .enableExperimentalFeature(
        "AvailabilityMacro=AsyncAlgorithms 1.3:macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0"),
]

let package = Package(
    name: "AsyncProperties",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.1.5"),
    ],
    targets: [
        .systemLibrary(
            name: "_CAsyncSequenceValidationSupport",
            path: "Vendor/_CAsyncSequenceValidationSupport"),
        .target(
            name: "AsyncSequenceValidation",
            dependencies: [
                "_CAsyncSequenceValidationSupport",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            path: "Vendor/AsyncSequenceValidation",
            swiftSettings: availabilityMacros),
        .testTarget(
            name: "AsyncPropertyTests",
            dependencies: [
                "AsyncSequenceValidation",
                .product(name: "HegelTesting", package: "hegel-swift"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            swiftSettings: availabilityMacros),
    ]
)
