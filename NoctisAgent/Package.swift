// swift-tools-version: 6.4
// Created by Sébastien DAGUIN

import PackageDescription

let package = Package(
    name: "NoctisAgent",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [.library(name: "NoctisAgent", targets: ["NoctisAgent"])],
    targets: [
        .target(name: "NoctisAgent"),
        .testTarget(name: "NoctisAgentTests", dependencies: ["NoctisAgent"])
    ]
)
