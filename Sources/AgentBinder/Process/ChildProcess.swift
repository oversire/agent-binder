import Darwin
import Foundation

/// How a child process ended.
struct ExitStatus: Sendable, Equatable {
    /// The exit code, or 128 + the signal for a signal death.
    var code: Int32
    /// The signal that killed the child, if a signal killed it.
    var signal: Int32?
}

/// The stage of ``ChildProcess/gracefulClose(stageTimeout:)`` that ended the child.
enum CloseStage: Int, Sendable {
    case alreadyExited = 0
    case stdinClosed = 1
    case terminated = 2
    case killed = 3
}

/// One read from a pipe.
enum PipeRead: Sendable {
    case data(Data)
    case eof
    case failed(Int32)
}

/// One spawned child with explicit pipes, its own process group and one waiter.
///
/// It is the only lifecycle mechanism for harness children. Blocking reads, writes and the wait
/// run on private dispatch queues, so they never block the cooperative thread pool.
final class ChildProcess: Sendable {
    /// The size of the retained stderr tail.
    static let stderrTailMax = 32 << 10
    /// The default time of each close stage.
    static let defaultStageTimeout: Duration = .seconds(5)

    let pid: pid_t
    let pgid: pid_t
    let argv: [String]

    private struct State {
        var stdin: Int32
        var stdout: Int32
        var exit: ExitStatus?
        var stderrTail = Data()
    }

    private let state: Locked<State>
    private let stdinQueue: DispatchQueue
    private let stdoutQueue: DispatchQueue
    private let stderrDone = DispatchSemaphore(value: 0)
    private let exited = Latch()

    private init(child: SpawnedChild, argv: [String]) {
        pid = child.pid
        pgid = child.pid
        self.argv = argv
        state = Locked(State(stdin: child.stdin, stdout: child.stdout))
        stdinQueue = DispatchQueue(label: "agentbinder.stdin.\(child.pid)")
        stdoutQueue = DispatchQueue(label: "agentbinder.stdout.\(child.pid)")
    }

    deinit {
        let fds = state.withLock { s -> [Int32] in
            defer {
                s.stdin = -1
                s.stdout = -1
            }
            return [s.stdin, s.stdout]
        }
        for fd in fds where fd >= 0 { _ = Darwin.close(fd) }
    }

    /// Spawns a child. The child is in its own process group.
    static func spawn(_ o: SpawnOptions) throws -> ChildProcess {
        let child = try Spawn.start(o)
        let p = ChildProcess(child: child, argv: [o.executable.path] + o.arguments)
        p.startStderrDrain(fd: child.stderr, onLine: o.onStderrLine)
        p.startWait()
        return p
    }

    // MARK: stdin

    /// Writes all bytes to the stdin of the child. It throws when the child closed its stdin.
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            stdinQueue.async { [self] in
                let fd = state.withLock { $0.stdin }
                guard fd >= 0 else {
                    cont.resume(throwing: AgentBinderError.sessionClosed)
                    return
                }
                let err = data.withUnsafeBytes { raw -> Int32 in
                    var off = 0
                    while off < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                        if n < 0 {
                            if errno == EINTR { continue }
                            return errno
                        }
                        off += n
                    }
                    return 0
                }
                if err == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: AgentBinderError.launch("write stdin: \(String(cString: strerror(err)))"))
                }
            }
        }
    }

    /// Closes the stdin of the child once, after the pending writes.
    func closeStdin() {
        stdinQueue.async { [self] in
            let fd = state.withLock { s -> Int32 in
                defer { s.stdin = -1 }
                return s.stdin
            }
            if fd >= 0 { _ = Darwin.close(fd) }
        }
    }

    // MARK: stdout

    /// Reads the next chunk of stdout. The caller owns framing.
    func readStdout(maxBytes: Int = 64 << 10) async -> PipeRead {
        await withCheckedContinuation { (cont: CheckedContinuation<PipeRead, Never>) in
            stdoutQueue.async { [self] in
                let fd = state.withLock { $0.stdout }
                guard fd >= 0 else {
                    cont.resume(returning: .eof)
                    return
                }
                var buf = [UInt8](repeating: 0, count: maxBytes)
                while true {
                    let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, maxBytes) }
                    if n > 0 {
                        cont.resume(returning: .data(Data(buf[0..<n])))
                    } else if n == 0 {
                        closeStdout()
                        cont.resume(returning: .eof)
                    } else if errno == EINTR {
                        continue
                    } else {
                        let e = errno
                        closeStdout()
                        cont.resume(returning: .failed(e))
                    }
                    return
                }
            }
        }
    }

    // Runs on stdoutQueue, so it never races a read.
    private func closeStdout() {
        let fd = state.withLock { s -> Int32 in
            defer { s.stdout = -1 }
            return s.stdout
        }
        if fd >= 0 { _ = Darwin.close(fd) }
    }

    // MARK: stderr

    /// The last 32 KiB of stderr.
    var stderrTail: String {
        String(decoding: state.withLock { $0.stderrTail }, as: UTF8.self)
    }

    // Reads to EOF even past the cap, so the child never blocks on a full pipe or gets SIGPIPE.
    private func startStderrDrain(fd: Int32, onLine: (@Sendable (String) -> Void)?) {
        let done = stderrDone
        Thread.detachNewThread { [state] in
            var pending = Data()
            var buf = [UInt8](repeating: 0, count: 16 << 10)
            func emit(_ line: Data) {
                var l = line
                if l.last == 0x0D { l.removeLast() }
                onLine?(String(decoding: l, as: UTF8.self))
            }
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                state.withLock { s in
                    s.stderrTail.append(chunk)
                    if s.stderrTail.count > ChildProcess.stderrTailMax {
                        s.stderrTail = Data(s.stderrTail.suffix(ChildProcess.stderrTailMax))
                    }
                }
                guard onLine != nil else { continue }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    emit(pending[pending.startIndex..<nl])
                    pending = Data(pending[(nl + 1)...])
                }
                if pending.count > 1 << 20 {
                    emit(pending)
                    pending.removeAll()
                }
            }
            if !pending.isEmpty { emit(pending) }
            _ = Darwin.close(fd)
            done.signal()
        }
    }

    // MARK: exit

    private func startWait() {
        let pid = pid
        let done = stderrDone
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let sig = status & 0x7f
            let exit =
                sig == 0
                ? ExitStatus(code: (status >> 8) & 0xff, signal: nil)
                : ExitStatus(code: 128 + sig, signal: sig)
            // Give the stderr drain a moment, so the tail is complete for classification.
            // A grandchild can keep the pipe open, so the wait has a limit.
            if done.wait(timeout: .now() + .milliseconds(500)) == .success { done.signal() }
            state.withLock { $0.exit = exit }
            exited.open()
        }
    }

    /// The exit status, or nil while the child is alive.
    var exitStatus: ExitStatus? { state.withLock { $0.exit } }

    /// Waits for the child to exit and returns its exit code.
    @discardableResult
    func waitForExit() async -> Int32 {
        _ = await waitForExit(timeout: nil)
        return exitStatus?.code ?? -1
    }

    /// Waits up to `timeout` for the child to exit. It returns false when the child is still alive.
    func waitForExit(timeout: Duration?) async -> Bool {
        await exited.wait(timeout: timeout)
    }

    // MARK: signals

    /// Sends a signal to the process group, else to the process.
    func signalGroup(_ sig: Int32) {
        if pgid > 0 && killpg(pgid, sig) == 0 { return }
        if exitStatus == nil { _ = Darwin.kill(pid, sig) }
    }

    /// Closes stdin, waits, sends SIGTERM to the group, waits, then sends SIGKILL to the group.
    ///
    /// A SIGTERM that comes too early can cut the vendor session file and lose the last
    /// assistant message, so each stage waits first.
    @discardableResult
    func gracefulClose(stageTimeout: Duration = ChildProcess.defaultStageTimeout) async -> CloseStage {
        if exitStatus != nil {
            reapGroup()
            return .alreadyExited
        }
        closeStdin()
        if await waitForExit(timeout: stageTimeout) {
            reapGroup()
            return .stdinClosed
        }
        signalGroup(SIGTERM)
        if await waitForExit(timeout: stageTimeout) {
            reapGroup()
            return .terminated
        }
        signalGroup(SIGKILL)
        await waitForExit()
        return .killed
    }

    /// Kills the process tree and waits for the child.
    func killTree() async {
        signalGroup(SIGKILL)
        await waitForExit()
    }

    // A grandchild that outlives the leader still holds the group; it must not outlive the session.
    private func reapGroup() {
        if pgid > 0 { _ = killpg(pgid, SIGKILL) }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
