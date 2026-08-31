// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalWebProxy",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LocalWebProxy", targets: ["LocalWebProxy"])],
    dependencies: [
        // Pinned Swift 5.9-compatible dependencies for reproducible builds.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.81.0"),
        // Pin transitive packages as well so resolving with a newer Xcode does not
        // silently raise the package's minimum toolchain requirement.
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.4.2")
    ],
    targets: [
        .target(name: "PortSocketSupport"),
        .target(name: "LocalWebProxy", dependencies: [
            "PortSocketSupport",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            // Keep these constraints reachable when Xcode prunes the package graph.
            .product(name: "Atomics", package: "swift-atomics"),
            .product(name: "DequeModule", package: "swift-collections"),
            .product(name: "SystemPackage", package: "swift-system")
        ]),
        .testTarget(name: "LocalWebProxyTests", dependencies: [
            "LocalWebProxy", "PortSocketSupport",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio")
        ])
    ]
)
