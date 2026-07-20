// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AntennaCAD",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AntennaCADCore",
            targets: ["AntennaCADCore"]
        ),
        .executable(
            name: "AntennaCADApp",
            targets: ["AntennaCADApp"]
        )
    ],
    targets: [
        .target(
            name: "AntennaCADCore"
        ),
        .executableTarget(
            name: "AntennaCADApp",
            dependencies: ["AntennaCADCore"]
        )
    ]
)
