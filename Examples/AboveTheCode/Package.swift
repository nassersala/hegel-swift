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
// session that refines it.
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
