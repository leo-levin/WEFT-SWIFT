// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WEFT",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WEFT", targets: ["WEFTApp"]),
        .library(name: "WEFTLib", targets: ["WEFTLib"])
    ],
    targets: [
        .target(
            name: "WEFTLib",
            dependencies: [],
            path: "Sources/WEFTLib",
            resources: [
                .copy("stdlib")
            ]
        ),
        .executableTarget(
            name: "WEFTApp",
            dependencies: ["WEFTLib"],
            path: "Sources/WEFTApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "WEFTTests",
            dependencies: ["WEFTLib"],
            path: "Tests/WEFTTests"
        )
    ]
)
