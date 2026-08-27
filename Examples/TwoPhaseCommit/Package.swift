// swift-tools-version:6.0
import PackageDescription

// Two-phase commit under the controlled scheduler, with the network's
// faults as a second drawn schedule: a coordinator, n participants, and
// a `Network` that drops or duplicates messages by index under a `Faults`
// list hegel draws and shrinks (empty = reliable). Safety holds on every
// schedule; liveness has the protocol's known counterexample, the
// coordinator crashing after the votes, and hegel shrinks to it.
let package = Package(
    name: "TwoPhaseCommit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "TwoPhaseCommit", targets: ["TwoPhaseCommit"])],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../ScheduleProperties"),
    ],
    targets: [
        .target(name: "TwoPhaseCommit", dependencies: [.product(name: "Schedules", package: "ScheduleProperties")]),
        .testTarget(
            name: "TwoPhaseCommitTests",
            dependencies: [
                "TwoPhaseCommit",
                .product(name: "HegelTesting", package: "hegel-swift"),
                .product(name: "Schedules", package: "ScheduleProperties"),
            ]
        ),
    ]
)
