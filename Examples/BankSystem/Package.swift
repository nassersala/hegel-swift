// swift-tools-version:6.0
import PackageDescription

// A system from its specifications (specs/system-from-specifications.md):
// one target per component relation from Phase A, each built by its own
// agent in parallel against a fixed relation; Wire is the calculation form;
// LedgerEq and TellerEq are the second lane, the same components derived
// from an equation with the network as a term. Phase C composes them.
let components = ["Wire", "Ledger", "Teller", "Race", "LedgerEq", "TellerEq"]
// Phase C: the composed system, built from the component targets. The
// module is `Composed` because a Swift module named `System` shadows
// Darwin's System module, which Foundation imports; the directories keep
// the name.
let composed = "Composed"

let package = Package(
    name: "BankSystem",
    platforms: [.macOS(.v15)],
    products: (components + [composed]).map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(path: "../.."),
        .package(path: "../ScheduleProperties"),
    ],
    targets: [
        .target(name: composed, dependencies: ["Wire", "Ledger", "Teller", .product(name: "Hegel", package: "hegel-swift"),
                                                .product(name: "Schedules", package: "ScheduleProperties")],
                path: "Sources/System"),
        .testTarget(
            name: "\(composed)Tests",
            dependencies: [
                .init(stringLiteral: composed), "Race",
                .product(name: "HegelTesting", package: "hegel-swift"),
                .product(name: "Schedules", package: "ScheduleProperties"),
            ],
            path: "Tests/SystemTests"
        ),
    ] + components.flatMap { name -> [Target] in
        [
            .target(name: name, dependencies: [.product(name: "Hegel", package: "hegel-swift")]),
            .testTarget(
                name: "\(name)Tests",
                dependencies: [
                    .init(stringLiteral: name),
                    .product(name: "HegelTesting", package: "hegel-swift"),
                    .product(name: "Schedules", package: "ScheduleProperties"),
                ]
            ),
        ]
    }
)
