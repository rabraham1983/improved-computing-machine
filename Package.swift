// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeScope",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodeScope", targets: ["CodeScope"]),
        .library(name: "CodeScopeCore", targets: ["CodeScopeCore"])
    ],
    targets: [
        // Platform-independent engine: indexing, Claude API client, analysis & optimization services.
        .target(
            name: "CodeScopeCore",
            path: "Sources/CodeScopeCore"
        ),
        // The macOS application (SwiftUI).
        .executableTarget(
            name: "CodeScope",
            dependencies: ["CodeScopeCore"],
            path: "Sources/CodeScope"
        ),
        .testTarget(
            name: "CodeScopeCoreTests",
            dependencies: ["CodeScopeCore"],
            path: "Tests/CodeScopeCoreTests"
        )
    ]
)
