import AgentBinder
import Foundation

/// A temp folder that goes away with the value.
final class TempDir: @unchecked Sendable {
    let url: URL

    init(prefix: String = "agentbinder-test-") throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        url = base.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var path: String { url.path }

    @discardableResult
    func write(_ relative: String, _ text: String, mode: Int = 0o644) throws -> URL {
        let u = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: u.path)
        return u
    }

    /// Writes an executable shell script.
    @discardableResult
    func script(_ name: String, _ body: String) throws -> URL {
        try write(name, "#!/bin/sh\n" + body + "\n", mode: 0o755)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }
}

/// `Testing.Attachment` hides the library type in files that import Testing.
typealias PromptAttachment = Attachment
