// swift-tools-version:6.0
import PackageDescription

// Lamport's method, "Thinking Above the Code", applied to sorting: draw one
// behaviour by hand, read the variables and the step off it, write Next as
// a relation, check it on drawn behaviours, then check that code refines
// it. Three fixtures: a sorting network found by the shrinker (the trace is
// the algorithm), the insertion relation above Fung's 2021 "simplest"
// sort, and the 24-program grammar search that is the control. A fourth
// leaves sorting: search-as-you-type as a relation over edits and arrivals
// in any order, and a SwiftUI-free view model that refines it. A fifth is
// token refresh with rotation: the session's promise as a relation over
// sends, 401s and refresh completions in any order, and a UIKit-free
// session that refines it. A sixth is zero-downtime deployment from
// Wlaschin's TLA+ talk: the balancer as the written-in variable, the
// batch and the capacity bound read off the guard, two rollouts refining.
// A seventh is a stream function under the fake clock: the relation says
// what Lively RaTT's three modalities would have said, and the tester
// recovers two of the three guarantees as refutations and the third as a
// step budget.
let package = Package(
    name: "AboveTheCode",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AboveTheCode", targets: ["AboveTheCode"])],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../ScheduleProperties"),  // the controlled scheduler, for "steps are whole"
    ],
    targets: [
        .target(name: "AboveTheCode", dependencies: [.product(name: "Hegel", package: "hegel-swift")]),
        .testTarget(
            name: "AboveTheCodeTests",
            dependencies: [
                "AboveTheCode",
                .product(name: "HegelTesting", package: "hegel-swift"),
                .product(name: "Schedules", package: "ScheduleProperties"),
            ]
        ),
    ]
)
