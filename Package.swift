// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AgentBinder",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentBinder", targets: ["AgentBinder"]),
        .library(name: "AgentBinderNative", targets: ["AgentBinderNative"]),
        .library(name: "AgentBinderMCP", targets: ["AgentBinderMCP"]),
    ],
    dependencies: [
        // AgentBinderMCP only. AgentBinder and AgentBinderNative must not import it.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        // The MCP SDK uses it; the stdio transport of AgentBinderMCP needs its logger type.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(name: "AgentBinder"),
        .target(name: "AgentBinderNative", dependencies: ["AgentBinder"]),
        .target(
            name: "AgentBinderMCP",
            dependencies: [
                "AgentBinder", "AgentBinderNative", .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // A stdio MCP server for the live tests. It is not a product.
        .executableTarget(name: "agentbinder-mcp-helper"),
        .testTarget(name: "AgentBinderTests", dependencies: ["AgentBinder"]),
        .testTarget(name: "AgentBinderNativeTests", dependencies: ["AgentBinder", "AgentBinderNative"]),
        .testTarget(
            name: "AgentBinderMCPTests",
            dependencies: [
                "AgentBinder", "AgentBinderNative", "AgentBinderMCP", .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "AgentBinderLiveTests",
            dependencies: ["AgentBinder", "AgentBinderNative", "AgentBinderMCP", "agentbinder-mcp-helper"],
            path: "Tests/LiveTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
