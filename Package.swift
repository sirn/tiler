// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "tiler",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "TilerApp",
            dependencies: ["TilerCore"]
        ),
        .target(
            name: "CSkyLight",
            linkerSettings: [
                .linkedFramework("ApplicationServices")
            ]
        ),
        .target(
            name: "TilerCore",
            dependencies: ["TOMLKit", "CSkyLight"]
        ),
        .testTarget(
            name: "TilerCoreTests",
            dependencies: ["TilerCore"]
        ),
    ]
)
