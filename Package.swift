// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osasfom_cad",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "osasfom_cadCore",
            targets: ["osasfom_cadCore"]
        ),
        .library(
            name: "osasfom_cadRender",
            targets: ["osasfom_cadRender"]
        ),
        .library(
            name: "osasfom_cadSolver",
            targets: ["osasfom_cadSolver"]
        ),
        .executable(
            name: "osasfom_cad",
            targets: ["osasfom_cad"]
        )
    ],
    targets: [
        // Headless model layer: Foundation only, no AppKit and no SceneKit, so
        // it can be reused by a command-line mesher or solver harness and is
        // fully unit-testable.
        .target(
            name: "osasfom_cadCore"
        ),
        // SceneKit rendering. Split out of Core so Core stays headless.
        .target(
            name: "osasfom_cadRender",
            dependencies: ["osasfom_cadCore"]
        ),
        // FDTD solver: a Swift port of openEMS's Engine/Operator core (GPLv3,
        // see LICENSE) plus a bridge that meshes a ResolvedModel into Yee grid
        // lines and drives the engine. Headless, like Core.
        .target(
            name: "osasfom_cadSolver",
            dependencies: ["osasfom_cadCore"]
        ),
        .executableTarget(
            name: "osasfom_cad",
            dependencies: ["osasfom_cadCore", "osasfom_cadRender", "osasfom_cadSolver"],
            // SwiftPM only bundles resources that live inside the target's own
            // directory, so the launch logo is kept here rather than read from
            // the repository's top-level Images folder.
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "osasfom_cadCoreTests",
            dependencies: ["osasfom_cadCore"]
        ),
        .testTarget(
            name: "osasfom_cadRenderTests",
            dependencies: ["osasfom_cadCore", "osasfom_cadRender"]
        ),
        .testTarget(
            name: "osasfom_cadSolverTests",
            dependencies: ["osasfom_cadCore", "osasfom_cadSolver"]
        )
    ]
)
