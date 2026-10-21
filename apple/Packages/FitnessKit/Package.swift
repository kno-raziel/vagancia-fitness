// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FitnessKit",
    defaultLocalization: "es",
    platforms: [.iOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "FitnessCore", targets: ["FitnessCore"]),
        .library(name: "FitnessRuntime", targets: ["FitnessRuntime"]),
    ],
    targets: [
        .target(name: "FitnessCore", resources: [.process("Resources")]),
        .target(
            name: "FitnessRuntime", dependencies: ["FitnessCore"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "FitnessCoreTests", dependencies: ["FitnessCore"]),
        .testTarget(
            name: "FitnessRuntimeTests", dependencies: ["FitnessCore", "FitnessRuntime"],
            resources: [.process("Fixtures")]),
    ]
)
