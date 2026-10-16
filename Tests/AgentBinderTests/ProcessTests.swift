import Darwin
import Foundation
import Testing

@testable import AgentBinder

private let sh = URL(fileURLWithPath: "/bin/sh")

private func spawnSh(_ script: String, onStderr: (@Sendable (String) -> Void)? = nil) throws -> ChildProcess {
    try ChildProcess.spawn(SpawnOptions(executable: sh, arguments: ["-c", script], onStderrLine: onStderr))
}

private func readAll(_ p: ChildProcess) async -> Data {
    var out = Data()
    while case .data(let d) = await p.readStdout() { out.append(d) }
    return out
}

private func openFDCount() -> Int {
    let pid = getpid()
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    return Int(size) / MemoryLayout<proc_fdinfo>.size
}

@Suite("ProcessTests")
struct ProcessTests {
    @Test func spawnEcho() async throws {
        let p = try spawnSh("echo hello")
        let out = await readAll(p)
        #expect(String(decoding: out, as: UTF8.self) == "hello\n")
        #expect(await p.waitForExit() == 0)
    }

    @Test func exitCodeMapping() async throws {
        let p = try spawnSh("exit 3")
        #expect(await p.waitForExit() == 3)
        #expect(p.exitStatus?.signal == nil)

        let q = try spawnSh("kill -TERM $$")
        #expect(await q.waitForExit() == 128 + SIGTERM)
        #expect(q.exitStatus?.signal == SIGTERM)
    }

    @Test func stdinRoundTrip() async throws {
        let p = try ChildProcess.spawn(SpawnOptions(executable: URL(fileURLWithPath: "/bin/cat")))
        try await p.write(Data("ping\n".utf8))
        p.closeStdin()
        #expect(String(decoding: await readAll(p), as: UTF8.self) == "ping\n")
        #expect(await p.waitForExit() == 0)
    }

    @Test func processGroupKillReachesGrandchild() async throws {
        let p = try spawnSh("sleep 1000 & echo $!; wait")
        var line = Data()
        while !line.contains(0x0A), case .data(let d) = await p.readStdout() { line.append(d) }
        let grandchild = pid_t(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
        #expect(ProcessGroup.alive(grandchild))
        await p.killTree()
        try await eventually { !ProcessGroup.alive(grandchild) }
        #expect(kill(p.pid, 0) != 0 && errno == ESRCH)
    }

    @Test func gracefulCloseStages() async throws {
        let stage = Duration.milliseconds(200)
        let a = try spawnSh("cat >/dev/null")
        #expect(await a.gracefulClose(stageTimeout: stage) == .stdinClosed)

        let b = try spawnSh("trap 'exit 0' TERM; while :; do sleep 0.05; done")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await b.gracefulClose(stageTimeout: stage) == .terminated)

        let c = try spawnSh("trap '' TERM; while :; do sleep 0.05; done")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await c.gracefulClose(stageTimeout: stage) == .killed)
        #expect(c.exitStatus?.signal == SIGKILL)
    }

    @Test func stderrTailIsCapped() async throws {
        // 100 lines of 1 KiB each: the tail keeps 32 KiB and ends with the last line.
        let p = try spawnSh(
            "i=0; while [ $i -lt 100 ]; do printf \"line-%03d-%01017d\\n\" $i 0 >&2; i=$((i+1)); done; echo done")
        let out = await readAll(p)
        #expect(String(decoding: out, as: UTF8.self) == "done\n")
        #expect(await p.waitForExit() == 0)
        let tail = p.stderrTail
        #expect(tail.utf8.count == ChildProcess.stderrTailMax)
        #expect(tail.hasSuffix("\n"))
        #expect(tail.split(separator: "\n").last?.hasPrefix("line-099-") == true)
    }

    @Test func onStderrLineGetsEachLine() async throws {
        let lines = Locked<[String]>([])
        let p = try spawnSh("echo one >&2; echo two >&2; printf three >&2") { l in lines.withLock { $0.append(l) } }
        await p.waitForExit()
        try await eventually { lines.value.count == 3 }
        #expect(lines.value == ["one", "two", "three"])
    }

    @Test func writeAfterDeathFailsWithoutSigpipe() async throws {
        let p = try spawnSh("exec 0<&-; exit 0")
        await p.waitForExit()
        await #expect(throws: (any Error).self) {
            for _ in 0..<4 { try await p.write(Data(repeating: 0x41, count: 70_000)) }
        }
    }

    @Test func noDescriptorLeak() async throws {
        // Warm up lazy runtime descriptors first.
        for _ in 0..<3 {
            let p = try spawnSh("true")
            _ = await readAll(p)
            await p.waitForExit()
        }
        let before = openFDCount()
        for _ in 0..<200 {
            let p = try spawnSh("echo x")
            _ = await readAll(p)
            await p.waitForExit()
            p.closeStdin()
        }
        try await eventually { openFDCount() <= before }
        #expect(openFDCount() <= before)
    }

    @Test func childInheritsNoExtraDescriptor() async throws {
        let path = NSTemporaryDirectory() + "agentbinder-fd-\(UUID().uuidString)"
        let raw = open(path, O_CREAT | O_RDWR, 0o600)
        // A high number, without FD_CLOEXEC, that the shell itself never uses.
        let fd = fcntl(raw, F_DUPFD, 60)
        defer {
            close(raw)
            close(fd)
            unlink(path)
        }
        #expect(fd >= 60)
        let p = try spawnSh("if [ -e /dev/fd/\(fd) ]; then echo leaked; else echo clean; fi")
        let out = String(decoding: await readAll(p), as: UTF8.self)
        await p.waitForExit()
        #expect(out == "clean\n")
    }

    @Test func startToken() async throws {
        let me = StartToken.of(getpid())
        #expect(me != nil)
        #expect(StartToken.of(getpid()) == me)
        let p = try spawnSh("sleep 5")
        let other = StartToken.of(p.pid)
        #expect(other != nil && other != me)
        await p.killTree()
    }

    @Test func sandboxCheck() {
        #expect(SandboxCheck.isSandboxed(["APP_SANDBOX_CONTAINER_ID": "x"]))
        #expect(!SandboxCheck.isSandboxed(["HOME": "/Users/x"]))
    }

    @Test func childEnvironmentOverridesWin() {
        let env = childEnvironment(
            base: ["A": "1", "CLAUDECODE": "1", "PATH": "/usr/bin"], overrides: ["A": "2", "B": "3"], path: "/x:/y")
        #expect(env == ["A": "2", "B": "3", "PATH": "/x:/y"])
    }
}

@Suite("BinaryResolverTests")
struct BinaryResolverTests {
    @Test func findsExecutableAndSkipsOthers() async throws {
        let tmp = try TempDir()
        let a = tmp.url.appendingPathComponent("a")
        let b = tmp.url.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try tmp.write("a/tool", "#!/bin/sh\n", mode: 0o644)
        try tmp.write("b/tool", "#!/bin/sh\n", mode: 0o755)
        let r = BinaryResolver(
            .init(useLoginShellPath: false, environment: ["PATH": "\(a.path):\(b.path)"], home: tmp.url))
        let found = try await r.resolve("tool", harness: .claude, override: nil)
        #expect(found.path == b.appendingPathComponent("tool").path)
    }

    @Test func overrideWins() async throws {
        let r = BinaryResolver(.init(useLoginShellPath: false, environment: ["PATH": ""]))
        let u = URL(fileURLWithPath: "/nowhere/claude")
        #expect(try await r.resolve("claude", harness: .claude, override: u) == u)
    }

    @Test func errorListsSearchedFolders() async throws {
        let tmp = try TempDir()
        let r = BinaryResolver(.init(useLoginShellPath: false, environment: ["PATH": "/nope1:/nope2"], home: tmp.url))
        do {
            _ = try await r.resolve("agentbinder-missing-tool", harness: .codex, override: nil)
            Issue.record("expected an error")
        } catch let AgentBinderError.binaryNotFound(h, searched) {
            #expect(h == .codex)
            #expect(Array(searched.prefix(2)) == ["/nope1", "/nope2"])
            #expect(searched.contains(tmp.url.path + "/.local/bin"))
        }
    }

    @Test func loginShellPathParsesBetweenMarkers() async throws {
        let tmp = try TempDir()
        try tmp.write(
            "fakeshell",
            "#!/bin/sh\necho 'welcome noise'\nPATH=/fake/one:/fake/two\nexport PATH\nshift 3\neval \"$1\"\necho trailing\n",
            mode: 0o755)
        // The fake shell drops "-l -i -c" and runs the script.
        let fixed = tmp.url.appendingPathComponent("fakeshell")
        let r = BinaryResolver(
            .init(environment: ["SHELL": fixed.path, "PATH": "/usr/bin"], home: tmp.url, shellTimeout: .seconds(5)))
        let dirs = await r.searchPath()
        #expect(Array(dirs.prefix(2)) == ["/fake/one", "/fake/two"])
    }

    @Test func loginShellTimeoutFallsBack() async throws {
        let tmp = try TempDir()
        try tmp.write("slowshell", "#!/bin/sh\nsleep 30\n", mode: 0o755)
        let r = BinaryResolver(
            .init(
                environment: ["SHELL": tmp.url.appendingPathComponent("slowshell").path, "PATH": "/proc/path"],
                home: tmp.url, shellTimeout: .milliseconds(300)))
        let dirs = await r.searchPath()
        #expect(dirs.first == "/proc/path")
    }

    @Test func parseMarked() {
        #expect(BinaryResolver.parseMarked("noise __AB__/a:/b__AB__ more") == "/a:/b")
        #expect(BinaryResolver.parseMarked("no markers") == nil)
    }
}
