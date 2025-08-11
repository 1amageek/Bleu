// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BleuExamples",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18)
    ],
    dependencies: [
        .package(path: "../")  // Bleu library
    ],
    targets: [
        // Basic Usage Examples
        .executableTarget(
            name: "SensorServer",
            dependencies: [
                .product(name: "Bleu", package: "Bleu"),
                "BleuCommon"
            ],
            path: "BasicUsage",
            sources: ["SensorServer.swift"]
        ),
        .executableTarget(
            name: "SensorClient",
            dependencies: [
                .product(name: "Bleu", package: "Bleu"),
                "BleuCommon"
            ],
            path: "BasicUsage",
            sources: ["SensorClient.swift"]
        ),
        
        // SwiftUI Example App
        .executableTarget(
            name: "BleuExampleApp",
            dependencies: [
                .product(name: "Bleu", package: "Bleu"),
                "BleuCommon"
            ],
            path: "SwiftUIApp"
        ),
        
        // Shared Common Types
        .target(
            name: "BleuCommon",
            dependencies: [
                .product(name: "Bleu", package: "Bleu")
            ],
            path: "Common"
        )
    ]
)