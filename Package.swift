// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Bleu",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18)
    ],
    products: [
        .library(
            name: "Bleu",
            targets: ["Bleu"]
        ),
        .executable(
            name: "BleuDemo",
            targets: ["BleuDemo"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-actor-runtime", branch: "main")
    ],
    targets: [
        .target(
            name: "Bleu",
            dependencies: [
                .product(name: "ActorRuntime", package: "swift-actor-runtime")
            ],
            path: "Sources/Bleu"
        ),
        .executableTarget(
            name: "BleuDemo",
            dependencies: ["Bleu"],
            path: "Sources/BleuDemo"
        ),
        .testTarget(
            name: "BleuTests",
            dependencies: [
                "Bleu"
            ],
            path: "Tests/BleuTests"
        ),
    ]
)
