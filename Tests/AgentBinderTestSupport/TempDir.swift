import Foundation

/// A temp folder that goes away with the value.
package final class TempDir: Sendable {
    package let url: URL

    package init(prefix: String = "agentbinder-test-") throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        url = base.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    package var path: String { url.path }

    @discardableResult
    package func write(_ relative: String, _ text: String, mode: Int = 0o644) throws -> URL {
        let u = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: u.path)
        return u
    }

    /// Writes an executable shell script.
    @discardableResult
    package func script(_ name: String, _ body: String) throws -> URL {
        try write(name, "#!/bin/sh\n" + body + "\n", mode: 0o755)
    }

    package func read(_ relative: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }
}

extension Duration {
    /// The probe limit of a runtime with fake binaries. The first run of a new script can wait for a system scan.
    package static let testProbe: Duration = .seconds(30)
}
