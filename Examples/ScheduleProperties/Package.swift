// swift-tools-version:6.0
import PackageDescription

// E2 of specs/async-experiments.md: schedules as inputs. `Schedules` is a
// controlled scheduler built on public API only (custom actor executors,
// task executor preference, clocks): every job an actor or task under
// test enqueues lands in one ready queue, and a policy decides which
// ready job runs next. E2a: fixed policies make a real race deterministic.
let package = Package(
    name: "ScheduleProperties",
    platforms: [
        .macOS(.v15)  // TaskExecutor and ExecutorJob.runSynchronously(on: UnownedTaskExecutor)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(name: "Schedules"),
        .testTarget(
            name: "SchedulePropertyTests",
            dependencies: [
                "Schedules",
                .product(name: "HegelTesting", package: "hegel-swift"),
            ]
        ),
    ]
)
