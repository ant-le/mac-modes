// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MacModes", platforms: [.macOS(.v13)], products: [
    .executable(name: "MacModes", targets: ["MacModes"]),
    .executable(name: "modectl", targets: ["modectl"]),
    .executable(name: "ModeLauncher", targets: ["ModeLauncher"])
], targets: [
    .target(name: "MacModesCore"),
    .executableTarget(name: "MacModes", dependencies: ["MacModesCore"]),
    .executableTarget(name: "modectl", dependencies: ["MacModesCore"]),
    .executableTarget(name: "ModeLauncher"),
    .executableTarget(name: "ModeTests", dependencies: ["MacModesCore"], path: "tests/MacModesCoreTests")
])
