// swift-tools-version:6.0
import PackageDescription

// An LLM agent's tool policy written once as a sequence-based enumeration
// table (Cleanroom; Aaron Hsu's form), then consumed four ways: a
// completeness check, hegel rules (one per cell), the static gate that walks
// a proposed plan before anything runs (Meijer, "Guardians of the Agents"),
// and the runtime monitor that walks one tool call at a time. The planner is
// untrusted: a generator in CI, a local model behind LLM_PLANNER=1.
let package = Package(
    name: "AgentProperties",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "AgentPropertyTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
