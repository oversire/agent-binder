import Darwin
import Foundation

/// Finds the vendor executables. A GUI app has only `/usr/bin:/bin:/usr/sbin:/sbin` on its PATH,
/// so the resolver reads the PATH of the login shell once and adds the usual install folders.
final class BinaryResolver: Sendable {
    struct Config: Sendable {
        var useLoginShellPath = true
        var extraPaths: [URL] = []
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var home: URL = FileManager.default.homeDirectoryForCurrentUser
        var shellTimeout: Duration = .seconds(5)
        /// When set, the resolver searches only these folders.
        var only: [URL]?
    }

    private let config: Config
    private let flight = SingleFlight<String, [String]>()
    private let cached = Locked<[String]?>(nil)

    init(_ config: Config = Config()) { self.config = config }

    /// The override, else the first executable on the search path.
    func resolve(_ name: String, harness: Harness, override: URL?) async throws -> URL {
        if let override { return override }
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            if Self.isExecutable(url.path) { return url }
        }
        let dirs = await searchPath()
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if Self.isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        throw AgentBinderError.binaryNotFound(harness, searched: dirs)
    }

    /// The search folders in order, without duplicates.
    func searchPath() async -> [String] {
        if let c = cached.value { return c }
        let dirs = await flight.run("path") { [config] in
            if let only = config.only { return only.map(\.path) }
            var out: [String] = []
            var seen = Set<String>()
            func add(_ d: String) {
                let d = d.trimmingCharacters(in: .whitespaces)
                guard !d.isEmpty, seen.insert(d).inserted else { return }
                out.append(d)
            }
            let shellPath = config.useLoginShellPath ? await Self.loginShellPath(config) : nil
            for d in (shellPath ?? config.environment["PATH"] ?? "").split(separator: ":") { add(String(d)) }
            for u in config.extraPaths { add(u.path) }
            for d in Self.knownFolders(home: config.home) { add(d) }
            return out
        }
        cached.withLock { $0 = dirs }
        return dirs
    }

    /// The PATH value for a child, so a vendor CLI that is a Node script finds `node`.
    func childPath() async -> String { await searchPath().joined(separator: ":") }

    static func knownFolders(home: URL) -> [String] {
        let h = home.path
        var dirs = ["\(h)/.local/bin", "\(h)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(h)/.bun/bin"]
        dirs += ["\(h)/.npm-global/bin", "\(h)/.volta/bin"]
        let nvm = "\(h)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        dirs += versions.sorted { semverAtLeast($0, $1) && $0 != $1 }.map { "\(nvm)/\($0)/bin" }
        dirs += ["\(h)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return dirs
    }

    /// A regular file (after symlinks) that this user can run.
    static func isExecutable(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    private static let marker = "__AB__"

    // rc files of the shell print noise, so the value sits between two markers.
    static func loginShellPath(_ config: Config) async -> String? {
        let shell = config.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '\(marker)%s\(marker)' \"$PATH\""
        guard
            let child = try? ChildProcess.spawn(
                SpawnOptions(
                    executable: URL(fileURLWithPath: shell), arguments: ["-l", "-i", "-c", script],
                    environment: config.environment))
        else { return nil }
        child.closeStdin()
        let output = Locked(Data())
        let reader = Task {
            while case .data(let d) = await child.readStdout() { output.withLock { $0.append(d) } }
        }
        let exited = await child.waitForExit(timeout: config.shellTimeout)
        if !exited { await child.killTree() }
        await reader.value
        return parseMarked(String(decoding: output.value, as: UTF8.self))
    }

    static func parseMarked(_ text: String) -> String? {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let v = parts[parts.count - 2]
        return v.isEmpty ? nil : v
    }
}
