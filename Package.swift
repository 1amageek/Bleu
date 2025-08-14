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
        // Swift Testing is now included in Swift 6 toolchain
    ],
    targets: [
        .target(
            name: "Bleu",
            dependencies: [],
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