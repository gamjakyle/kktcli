// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "kmsg",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "VersionGenTool"
        ),
        .plugin(
            name: "VersionGenPlugin",
            capability: .buildTool(),
            dependencies: [
                "VersionGenTool",
            ]
        ),
        // Pure parsing and policy logic (no Accessibility calls), unit tested by KmsgCoreTests.
        .target(
            name: "KmsgCore"
        ),
        .executableTarget(
            name: "kmsg",
            dependencies: [
                "KmsgCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            plugins: [
                .plugin(name: "VersionGenPlugin"),
            ]
        ),
        // Lives next to the Python contract tests; the explicit path keeps it case-correct on
        // case-sensitive file systems.
        .testTarget(
            name: "KmsgCoreTests",
            dependencies: ["KmsgCore"],
            path: "tests/KmsgCoreTests"
        ),
    ]
)
