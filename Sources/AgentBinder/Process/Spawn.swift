import Darwin
import Foundation

/// The description of one child process.
package struct SpawnOptions: Sendable {
    package var executable: URL
    package var arguments: [String]
    package var directory: URL?
    /// The full child environment. Nil inherits the environment of this process.
    package var environment: [String: String]?
    /// Receives each stderr line. It runs on the drain thread, so it must not block.
    package var onStderrLine: (@Sendable (String) -> Void)?

    package init(
        executable: URL, arguments: [String] = [], directory: URL? = nil, environment: [String: String]? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.onStderrLine = onStderrLine
    }
}

/// The descriptors and pid of a child that `posix_spawn` started.
struct SpawnedChild {
    var pid: pid_t
    var stdin: Int32
    var stdout: Int32
    var stderr: Int32
}

enum Spawn {
    /// Starts the child in its own process group, with only fds 0, 1 and 2 open.
    static func start(_ o: SpawnOptions) throws -> SpawnedChild {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0 else { throw AgentBinderError.launch("pipe: \(errnoText())") }
        guard pipe(&outPipe) == 0 else {
            closeAll(inPipe)
            throw AgentBinderError.launch("pipe: \(errnoText())")
        }
        guard pipe(&errPipe) == 0 else {
            closeAll(inPipe + outPipe)
            throw AgentBinderError.launch("pipe: \(errnoText())")
        }
        let all = inPipe + outPipe + errPipe
        for fd in all { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A write to a dead child returns EPIPE instead of a SIGPIPE that kills the app.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)
        if let dir = o.directory {
            posix_spawn_file_actions_addchdir_np(&fa, dir.path)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let argv = [o.executable.path] + o.arguments
        let env = (o.environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(env) { cEnv in
                posix_spawn(&pid, o.executable.path, &fa, &attr, cArgv, cEnv)
            }
        }
        // The parent copies of the child ends go away in each case.
        _ = close(inPipe[0])
        _ = close(outPipe[1])
        _ = close(errPipe[1])
        guard rc == 0 else {
            _ = close(inPipe[1])
            _ = close(outPipe[0])
            _ = close(errPipe[0])
            throw AgentBinderError.launch("spawn \(o.executable.path): \(String(cString: strerror(rc)))")
        }
        return SpawnedChild(pid: pid, stdin: inPipe[1], stdout: outPipe[0], stderr: errPipe[0])
    }

    static func errnoText() -> String { String(cString: strerror(errno)) }

    private static func closeAll(_ fds: [Int32]) {
        for fd in fds where fd >= 0 { _ = close(fd) }
    }

    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { for p in ptrs { free(p) } }
        return ptrs.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
