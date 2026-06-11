// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hive",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HiveEngine", path: "Sources/HiveEngine"),
        .executableTarget(
            name: "Hive",
            dependencies: ["HiveEngine"],
            path: "Sources/Hive",
            resources: [.copy("Resources/Pieces")]
        ),
        .testTarget(
            name: "HiveEngineTests",
            dependencies: ["HiveEngine"],
            path: "Tests/HiveEngineTests"
        ),
    ]
)
