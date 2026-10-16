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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1"))
    ],
    targets: [
        .target(name: "AgentBinder"),
        .target(
            name: "AgentBinderNative",
            dependencies: ["AgentBinder", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(name: "AgentBinderTests", dependencies: ["AgentBinder"]),
        .testTarget(name: "AgentBinderNativeTests", dependencies: ["AgentBinderNative"]),
        .testTarget(
            name: "AgentBinderLiveTests",
            dependencies: ["AgentBinder", "AgentBinderNative"],
            path: "Tests/LiveTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
