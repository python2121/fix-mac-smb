// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SMBKeeper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "smbkeeper", targets: ["smbkeeper"]),
        .executable(name: "SMBKeeperApp", targets: ["SMBKeeperApp"]),
        .executable(name: "smbkeeper-tests", targets: ["smbkeeper-tests"]),
        .library(name: "SMBKeeperCore", targets: ["SMBKeeperCore"]),
    ],
    targets: [
        .target(
            name: "SMBKeeperCore",
            linkerSettings: [
                .linkedFramework("NetFS"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(name: "smbkeeper", dependencies: ["SMBKeeperCore"]),
        .executableTarget(
            name: "SMBKeeperApp",
            dependencies: ["SMBKeeperCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "smbkeeper-tests", dependencies: ["SMBKeeperCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
