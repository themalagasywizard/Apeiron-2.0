// swift-tools-version:5.10
import PackageDescription

// Apeiron, native.
//
// ApeironKit   – the agent harness: providers, tools, permissions, hooks,
//                context management, sessions. Pure Foundation, builds on
//                macOS and Linux so the harness is testable anywhere.
// ApeironApp   – the SwiftUI desktop app (macOS 14+).
// apeiron      – a terminal client driving the same harness.

var targets: [Target] = [
    .target(
        name: "ApeironKit",
        path: "Sources/ApeironKit"
    ),
    .executableTarget(
        name: "ApeironCLI",
        dependencies: ["ApeironKit"],
        path: "Sources/ApeironCLI"
    ),
    .testTarget(
        name: "ApeironKitTests",
        dependencies: ["ApeironKit"],
        path: "Tests/ApeironKitTests"
    ),
]

var products: [Product] = [
    .library(name: "ApeironKit", targets: ["ApeironKit"]),
    .executable(name: "apeiron", targets: ["ApeironCLI"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "ApeironApp",
        dependencies: ["ApeironKit"],
        path: "Sources/ApeironApp"
    )
)
products.append(.executable(name: "Apeiron", targets: ["ApeironApp"]))
#endif

let package = Package(
    name: "Apeiron",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
