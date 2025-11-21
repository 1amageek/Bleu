// swift-tools-version: 6.2
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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-actor-runtime", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/1amageek/CoreBluetoothEmulator", branch: "main")
    ],
    targets: [
        .target(
            name: "Bleu",
            dependencies: [
                .product(name: "ActorRuntime", package: "swift-actor-runtime"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/Bleu"
        ),
        .testTarget(
            name: "BleuTests",
            dependencies: [
                "Bleu",
                .product(name: "CoreBluetoothEmulator", package: "CoreBluetoothEmulator")
            ],
            path: "Tests/BleuTests"
        ),
    ]
)
