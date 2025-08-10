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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.4.0")
    ],
    targets: [
        .target(
            name: "Bleu",
            dependencies: [],
            path: "Sources/Bleu"
        ),
        .testTarget(
            name: "BleuTests",
            dependencies: [
                "Bleu",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/BleuTests"
        ),
    ]
)