// swift-tools-version:6.0
import PackageDescription

// A small bank: a ledger service and teller apps that talk over a network
// that can delay, duplicate, or drop messages. Everything is a value in a
// discrete-time simulation driven by a seeded generator, so every run is
// reproducible from its seed and the tests can check invariants after every
// tick.
let package = Package(
    name: "BankControl",
    platforms: [.macOS(.v15)],
    products: [.library(name: "BankControl", targets: ["BankControl"])],
    targets: [
        .target(name: "BankControl"),
        .testTarget(name: "BankControlTests", dependencies: ["BankControl"]),
    ]
)
