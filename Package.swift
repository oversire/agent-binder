// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBinder",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentBinder", targets: ["AgentBinder"]),
        .library(name: "AgentBinderNative", targets: ["AgentBinderNative"]),
    ],
    dependencies: [
        // AgentBinderNative only. The core target must not import it.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        // The MCP SDK uses it; the stdio transport of AgentBinderNative needs its logger type.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(name: "AgentBinder"),
        .target(
            name: "AgentBinderNative",
            dependencies: [
                "AgentBinder", .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "AgentBinderTests", dependencies: ["AgentBinder"]),
        .testTarget(
            name: "AgentBinderNativeTests",
            dependencies: ["AgentBinder", "AgentBinderNative", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "AgentBinderLiveTests",
            dependencies: ["AgentBinder", "AgentBinderNative"],
            path: "Tests/LiveTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
