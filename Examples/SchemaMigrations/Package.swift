// swift-tools-version:6.0
import PackageDescription

// Schema migrations as a category, with real SQLite as the meaning: objects
// are schemas, arrows are migrations, composition squashes, and "run it"
// is a functor into what SQLite actually does.
let package = Package(
    name: "SchemaMigrations",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "SchemaMigrationsTests",
            dependencies: [
                .product(name: "Hegel", package: "hegel-swift")
            ],
            linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
