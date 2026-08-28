// swift-tools-version:6.0
import PackageDescription

// Lamport's transaction commit (TCommit) as the specification, and
// two-phase commit as its implementation, under the controlled scheduler
// with the network's faults as a second drawn schedule. The property is
// his theorem, TPSpec => TC!TCSpec, checked of the code: every run's
// projected steps are TCommit steps. Liveness has the protocol's known
// counterexample, the coordinator crashing after the votes, and hegel
// shrinks to it.
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
