// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SWeft",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SWeft", targets: ["SWeftApp"]),
        .library(name: "SWeftLib", targets: ["SWeftLib"])
    ],
    targets: [
        .target(
            name: "SWeftLib",
            dependencies: [],
            path: "Sources/SWeftLib",
            resources: [
                .copy("JSCompiler/ohm.js"),
                .copy("JSCompiler/weft-compiler.js")
            ]
        ),
        .executableTarget(
            name: "SWeftApp",
            dependencies: ["SWeftLib"],
            path: "Sources/SWeftApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "SWeftTests",
            dependencies: ["SWeftLib"],
            path: "Tests/SWeftTests"
        )
    ]
)
