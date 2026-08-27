// swift-tools-version:6.0
import PackageDescription

// Lamport's quicksort ("Thinking Above the Code", 2014): the algorithm as
// a nondeterministic next-state relation over (A, U), where U is the set
// of index ranges still to partition. The three "pick any"s are draws;
// a concrete quicksort must refine the relation.
let package = Package(
    name: "Quicksort",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Quicksort", targets: ["Quicksort"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "Quicksort", dependencies: [.product(name: "Hegel", package: "hegel-swift")]),
        .testTarget(
            name: "QuicksortTests",
            dependencies: ["Quicksort", .product(name: "HegelTesting", package: "hegel-swift")]
        ),
    ]
)
