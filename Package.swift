// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beacon",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Beacon", targets: ["Beacon"]),
        .library(name: "BeaconTesting", targets: ["BeaconTesting"]),
    ],
    targets: [
        .target(name: "Beacon"),
        .target(name: "BeaconTesting", dependencies: ["Beacon"]),
        .testTarget(name: "BeaconTests", dependencies: ["Beacon", "BeaconTesting"]),
    ]
)
