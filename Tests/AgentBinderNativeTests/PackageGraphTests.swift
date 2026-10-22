import Foundation
import Testing

/// Reads the manifest with `swift package dump-package` and walks the target graph of each product.
@Suite("PackageGraphTests")
struct PackageGraphTests {
    struct Graph {
        /// The local target names of each target.
        var targets: [String: [String]] = [:]
        /// The external products (`package/product`) of each target.
        var external: [String: [String]] = [:]
        var products: [String: [String]] = [:]

        /// The external products that a product pulls in, through each local target.
        func externalProducts(of product: String) -> Set<String> {
            var seen = Set<String>()
            var todo = products[product] ?? []
            var out = Set<String>()
            while let t = todo.popLast() {
                guard seen.insert(t).inserted else { continue }
                out.formUnion(external[t] ?? [])
                todo += targets[t] ?? []
            }
            return out
        }
    }

    static func load() throws -> Graph {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("agentbinder-dump-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Its own scratch path, so the call does not wait for the build lock of `swift test`.
        p.arguments = ["swift", "package", "dump-package", "--package-path", root.path, "--scratch-path", scratch.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "dump-package failed")

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var g = Graph()
        let local = Set((json["targets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        for t in json["targets"] as? [[String: Any]] ?? [] {
            let name = try #require(t["name"] as? String)
            for d in t["dependencies"] as? [[String: Any]] ?? [] {
                if let p = d["product"] as? [Any] {
                    g.external[name, default: []].append("\(p[1] as? String ?? "?")/\(p[0] as? String ?? "?")")
                } else if let n = ((d["byName"] ?? d["target"]) as? [Any])?.first as? String {
                    // A by-name entry that is not a local target is a product of a package.
                    if local.contains(n) {
                        g.targets[name, default: []].append(n)
                    } else {
                        g.external[name, default: []].append(n)
                    }
                }
            }
        }
        for p in json["products"] as? [[String: Any]] ?? [] {
            if let name = p["name"] as? String { g.products[name] = p["targets"] as? [String] ?? [] }
        }
        return g
    }

    // Fixed on purpose: a consumer of AgentBinderNative pulls in no external package.
    @Test func nativeHasNoExternalPackages() throws {
        let g = try Self.load()
        #expect(g.products["AgentBinderNative"] == ["AgentBinderNative"])
        #expect(g.externalProducts(of: "AgentBinder").isEmpty)
        #expect(g.externalProducts(of: "AgentBinderNative").isEmpty)
        #expect(g.externalProducts(of: "AgentBinderMCP") == ["swift-sdk/MCP", "swift-log/Logging"])
    }
}
