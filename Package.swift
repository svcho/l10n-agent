// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "l10n-agent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "l10n-agent", targets: ["l10n-agent"]),
        .library(name: "L10nCore", targets: ["L10nCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(
            name: "L10nCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "L10nMCP",
            dependencies: [
                "L10nCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "l10n-agent",
            dependencies: [
                "L10nCore",
                "L10nMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "L10nCoreTests",
            dependencies: ["L10nCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "L10nMCPTests",
            dependencies: [
                "L10nMCP",
                "L10nCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
