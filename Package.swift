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
        .executableTarget(
            name: "osasfom_cad",
            dependencies: ["osasfom_cadCore", "osasfom_cadRender"]
        ),
        .testTarget(
            name: "osasfom_cadCoreTests",
            dependencies: ["osasfom_cadCore"]
        )
    ]
)
