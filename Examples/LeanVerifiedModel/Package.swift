// swift-tools-version:6.0
import Foundation
import PackageDescription

// A Lean-verified model with a counter, consumed as an evaluator: Lean
// proves theorems about `step`, `lake build` compiles it to C, and the Swift
// test calls `otp_step` through a C module as the oracle for a Command.
//
// Needs Lean (elan) and a prior `lake build Otp:static` in ./Lean; see
// README. Set LEAN_SYSROOT to the toolchain prefix (`lean --print-prefix`),
// or the default elan toolchain is used.
let env = ProcessInfo.processInfo.environment
let home = env["HOME"] ?? NSHomeDirectory()
let leanSysroot: String = env["LEAN_SYSROOT"] ?? {
    let toolchains = "\(home)/.elan/toolchains"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: toolchains)) ?? []
    return names.sorted().last.map { "\(toolchains)/\($0)" } ?? "/usr/local"
}()
let lakeLib = "\(Context.packageDirectory)/Lean/.lake/build/lib"

let package = Package(
    name: "LeanVerifiedModel",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "LoginUI", targets: ["LoginUI"])
    ],
    dependencies: [.package(path: "../.."), .package(path: "../ScheduleProperties")],
    targets: [
        // The screen: view model + SwiftUI view. Ships without Lean.
        .target(name: "LoginUI"),
        .target(
            name: "COtp",
            cSettings: [.unsafeFlags(["-I", "\(leanSysroot)/include"])]),
        .testTarget(
            name: "LeanVerifiedModelTests",
            dependencies: [
                "COtp", "LoginUI",
                .product(name: "Hegel", package: "hegel-swift"),
                .product(name: "Schedules", package: "ScheduleProperties"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", lakeLib, "-L", "\(leanSysroot)/lib/lean", "-L", "\(leanSysroot)/lib",
                    "-lotp_Otp", "-lotp_Bank", "-lInit", "-lleanrt", "-luv", "-lgmp", "-lc++",
                ])
            ]),
    ]
)
