// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "locally-remote",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LocallyRemoteCore",
            targets: ["LocallyRemoteCore"]
        ),
        .executable(
            name: "locally-remote",
            targets: ["locally-remote"]
        )
    ],
    targets: [
        .target(
            name: "LocallyRemoteCore",
            linkerSettings: [
                .linkedLibrary("System", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "locally-remote",
            dependencies: ["LocallyRemoteCore"]
        ),
        .testTarget(
            name: "LocallyRemoteCoreTests",
            dependencies: ["LocallyRemoteCore"]
        )
    ]
)
