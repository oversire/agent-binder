import Foundation

/// The files and folders that a launch makes. They can hold secrets, so folders are 0700 and files 0600.
enum ConfigFiles {
    /// Writes a JSON file with mode 0600. It makes the parent folder with mode 0700.
    static func writeJSON(_ v: JSONValue, to url: URL) throws {
        try write(Data((v.prettyString + "\n").utf8), to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            throw AgentBinderError.launch("write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Makes a temp folder with mode 0700 for the generated files of one session.
    static func sessionDirectory(_ h: Harness, purpose: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("agentbinder-\(h.rawValue)-\(purpose)-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AgentBinderError.launch("temp dir: \(error.localizedDescription)")
        }
        return dir
    }
}
