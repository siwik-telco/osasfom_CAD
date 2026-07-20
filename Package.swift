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
        .executable(
            name: "osasfom_cad",
            targets: ["osasfom_cad"]
        )
    ],
    targets: [
        .target(
            name: "osasfom_cadCore"
        ),
        .executableTarget(
            name: "osasfom_cad",
            dependencies: ["osasfom_cadCore"]
        )
    ]
)
