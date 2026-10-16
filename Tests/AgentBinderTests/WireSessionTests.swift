import Darwin
import Foundation
import Testing

@testable import AgentBinder

private func shChild(_ script: String) throws -> ChildProcess {
    try ChildProcess.spawn(
        SpawnOptions(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]))
}

private final class WeakRef: @unchecked Sendable {
    weak var value: AnyObject?
}

private func memorySession(
    _ adapter: any WireAdapter = LineAdapter(), config: WireConfig = WireConfig()
) async throws -> (WireSession, MemoryPeer) {
    let peer = MemoryPeer()
    let s = try await WireSession.inMemory(adapter: adapter, input: peer.input, output: peer.output, config: config)
    return (s, peer)
}

@Suite("FrameReaderTests")
struct FrameReaderTests {
    @Test func splitsAcrossChunks() {
        var r = FrameReader(maxBytes: 100)
        #expect(r.feed(Data("{\"a\":".utf8)) == [])
        #expect(
            r.feed(Data("1}\n{\"b\":2}\r\n{\"c\"".utf8)) == [
                .line(Data("{\"a\":1}".utf8)), .line(Data("{\"b\":2}".utf8)),
            ])
        #expect(r.finish() == .line(Data("{\"c\"".utf8)))
        #expect(r.finish() == nil)
    }

    @Test func dropsLongFrameAndResyncs() {
        var r = FrameReader(maxBytes: 10)
        #expect(r.feed(Data("0123456789abc".utf8)) == [])
        #expect(r.feed(Data("def\nok\n".utf8)) == [.tooLarge, .line(Data("ok".utf8))])
        // The cap counts the newline.
        #expect(r.feed(Data("012345678\n0123456789\n".utf8)) == [.line(Data("012345678".utf8)), .tooLarge])
        #expect(r.feed(Data("01234567890".utf8)) == [])
        #expect(r.finish() == .tooLarge)
    }

    @Test func blank() {
        #expect(FrameReader.isBlank(Data(" \t\r".utf8)))
        #expect(!FrameReader.isBlank(Data(" x".utf8)))
    }
}

@Suite("WireSessionTests")
struct WireSessionTests {
    @Test func framesBecomeEventsAndExitIsLast() async throws {
        let (s, peer) = try await memorySession()
        peer.send("{\"type\":\"init\",\"id\":\"S1\"}\n{\"type\":\"assistant\",\"text\":\"hi\"}\n")
        peer.send("{\"type\":\"result\",\"text\":\"done\"}\n")
        peer.end()
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.map(\.kind.name) == ["init", "assistant", "result", "exit"])
        #expect(evs.allSatisfy { $0.sessionID == "S1" })
        #expect(s.id == "S1")
        #expect(evs[1].raw == Data("{\"type\":\"assistant\",\"text\":\"hi\"}".utf8))
        await s.close()
    }

    @Test func blankLinesAndCRLF() async throws {
        let (s, peer) = try await memorySession()
        peer.send("\n   \n{\"type\":\"assistant\",\"text\":\"a\"}\r\n\r\n{\"type\":\"assistant\",\"text\":\"b\"}")
        peer.end()
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.compactMap(\.assistantText) == ["a", "b"])
        #expect(evs.count == 3)
    }

    @Test func frameTooLargeAtDefaultCap() async throws {
        let (s, peer) = try await memorySession()
        var big = Data("{\"type\":\"assistant\",\"text\":\"".utf8)
        big.append(Data(repeating: 0x78, count: 17 << 20))
        big.append(Data("\"}\n".utf8))
        // Feed in pieces, as a pipe does.
        var off = 0
        while off < big.count {
            let n = min(1 << 20, big.count - off)
            peer.send(big.subdata(in: off..<(off + n)))
            off += n
        }
        peer.send("{\"type\":\"assistant\",\"text\":\"next\"}\n")
        peer.end()
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.compactMap(\.errorCode) == ["frame_too_large"])
        #expect(evs.compactMap(\.assistantText) == ["next"])
        #expect(s.lastError?.code == "frame_too_large")
    }

    @Test func lastFrameWithoutNewline() async throws {
        let p = try shChild("printf '{\"type\":\"assistant\",\"text\":\"tail\"}'")
        let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter())
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.compactMap(\.assistantText) == ["tail"])
        guard case .exit(let code, let err, let errCode) = evs.last?.kind else {
            Issue.record("no exit")
            return
        }
        #expect(code == 0 && err == nil && errCode == nil)
    }

    @Test func handshakeFailureKillsChildAndRunsHooks() async throws {
        let p = try shChild("sleep 100")
        let ran = Locked(false)
        let adapter = LineAdapter(.init(handshake: { _ in throw AgentBinderError.handshakeFailed("boom") }))
        await #expect(throws: AgentBinderError.self) {
            _ = try await WireSession.start(
                harness: .fake, process: p, adapter: adapter, onClose: [{ ran.withLock { $0 = true } }])
        }
        #expect(p.exitStatus?.signal == SIGKILL)
        #expect(ran.value)
    }

    @Test func handshakeTimeout() async throws {
        let p = try shChild("sleep 100")
        let adapter = LineAdapter(
            .init(handshake: { _ in
                try await Task.sleep(for: .seconds(60))
                return []
            }))
        var config = WireConfig()
        config.handshakeTimeout = .milliseconds(200)
        do {
            _ = try await WireSession.start(harness: .fake, process: p, adapter: adapter, config: config)
            Issue.record("expected a timeout")
        } catch let e as AgentBinderError {
            #expect(e.code == "handshake_timeout")
        }
        #expect(p.exitStatus != nil)
    }

    @Test func handshakeWritesAndEmits() async throws {
        let adapter = LineAdapter(
            .init(handshake: { w in
                try await w.write(["type": "hello"])
                w.setSessionID("H1")
                return [Event(.initialized)]
            }))
        let (s, peer) = try await memorySession(adapter)
        #expect(peer.frames == [["type": "hello"]])
        #expect(s.id == "H1")
        peer.end()
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.map(\.kind.name) == ["init", "exit"])
        #expect(evs[0].sessionID == "H1")
    }

    @Test func promptDuringActiveTurn() async throws {
        let adapter = LineAdapter(.init(trackTurns: true))
        let (s, peer) = try await memorySession(adapter)
        try await s.prompt(Prompt("one"))
        #expect(s.turn == 1)
        await #expect(throws: AgentBinderError.turnActive) { try await s.prompt(Prompt("two")) }
        peer.send("{\"type\":\"result\",\"text\":\"r\"}\n")
        try await eventually { !adapter.turnActive }
        try await s.prompt(Prompt("two"))
        #expect(s.turn == 2)
        #expect(peer.frames.map { $0["text"].stringValue } == ["one", "two"])
        peer.end()
        await s.close()
    }

    @Test func concurrentAdapterTakesSecondPrompt() async throws {
        let (s, peer) = try await memorySession(LineAdapter(.init(trackTurns: true, concurrent: true)))
        try await s.prompt(Prompt("one"))
        #expect(try await s.send(Prompt("two")) == .prompted)
        #expect(peer.frames.count == 2)
        peer.end()
        await s.close()
    }

    @Test func sendHoldsAndFlushesOneFollowup() async throws {
        let adapter = LineAdapter(.init(trackTurns: true))
        let (s, peer) = try await memorySession(adapter)
        #expect(try await s.send(Prompt("go")) == .prompted)
        #expect(try await s.send(Prompt("a")) == .held)
        #expect(try await s.send(Prompt("b")) == .held)
        #expect(peer.frames.count == 1)
        peer.send("{\"type\":\"result\",\"text\":\"r1\"}\n")
        let r1 = try await withTimeout { await s.events.next(where: \.isResult) }
        #expect(r1?.turn == 1)
        let frames = peer.frames
        #expect(frames.count == 2)
        #expect(frames.last?["text"] == "a\n\nb")
        #expect(frames.last?["kind"] == "followup")
        #expect(s.turn == 2)
        peer.end()
        await s.close()
    }

    @Test func exitDropsHeldPrompts() async throws {
        let adapter = LineAdapter(.init(trackTurns: true))
        let (s, peer) = try await memorySession(adapter)
        try await s.prompt(Prompt("go"))
        #expect(try await s.send(Prompt("lost 1")) == .held)
        #expect(try await s.send(Prompt("lost 2")) == .held)
        peer.end()
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.map(\.kind.name) == ["error", "exit"])
        guard case .error(let we) = evs[0].kind else { return }
        #expect(we.code == "held_prompt_dropped")
        #expect(we.text == "lost 1\n\nlost 2")
    }

    @Test func sendSteersDuringTurn() async throws {
        let adapter = SteeringAdapter()
        let (s, peer) = try await memorySession(adapter)
        #expect(try await s.send(Prompt("go")) == .prompted)
        #expect(try await s.send(Prompt("more")) == .steered)
        #expect(adapter.steered.value == ["more"])

        adapter.steerError.withLock { $0 = .unsupported("steer") }
        #expect(try await s.send(Prompt("later")) == .held)

        // The turn ended in between: the send prompts at once.
        adapter.steerError.withLock { $0 = .noActiveTurn }
        adapter.base.setActive(false)
        #expect(try await s.send(Prompt("x")) == .prompted)
        peer.end()
        await s.close()
    }

    @Test func outboxNoActiveTurnFallsThrough() async throws {
        let box = Outbox()
        let active = Locked(true)
        let prompted = Locked<[String]>([])
        let ops = Outbox.Ops(
            active: { active.value },
            prompt: { p in prompted.withLock { $0.append(p.text) } },
            steer: { _ in
                active.withLock { $0 = false }
                throw AgentBinderError.noActiveTurn
            }, concurrent: false)
        #expect(try await box.send(ops, Prompt("p")) == .prompted)
        #expect(prompted.value == ["p"])
    }

    @Test func outboxSteerErrorPropagates() async throws {
        let box = Outbox()
        let ops = Outbox.Ops(
            active: { true }, prompt: { _ in }, steer: { _ in throw AgentBinderError.sessionClosed },
            concurrent: false)
        await #expect(throws: AgentBinderError.sessionClosed) { _ = try await box.send(ops, Prompt("p")) }
        #expect(!box.pending)
    }

    @Test func outboxFlushFailureReturnsHeld() async throws {
        let box = Outbox()
        let ops = Outbox.Ops(active: { true }, prompt: { _ in }, steer: nil, concurrent: false)
        #expect(try await box.send(ops, Prompt("a", attachments: [.data(Data([1]), mime: "image/png")])) == .held)
        #expect(try await box.send(ops, Prompt("b")) == .held)
        let joined = Locked<Prompt?>(nil)
        let dropped = await box.flush { p in
            joined.withLock { $0 = p }
            throw AgentBinderError.sessionClosed
        }
        #expect(dropped.map(\.text) == ["a", "b"])
        #expect(joined.value?.text == "a\n\nb")
        #expect(joined.value?.attachments.count == 1)
        #expect(!box.pending)
    }

    @Test func answerAndInterrupt() async throws {
        let (s, peer) = try await memorySession()
        try await s.answer("P1", .allow())
        #expect(peer.frames == [["type": "decision", "id": "P1", "allow": true]])
        await #expect(throws: AgentBinderError.self) { try await s.interrupt() }
        peer.end()
        await s.close()
    }

    @Test func interruptSignalsTheGroup() async throws {
        let p = try shChild(
            "trap 'echo \"{\\\"type\\\":\\\"assistant\\\",\\\"text\\\":\\\"stopped\\\"}\"; exit 0' TERM; while :; do sleep 0.05; done"
        )
        let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter())
        try await Task.sleep(for: .milliseconds(100))
        try await s.interrupt()
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.compactMap(\.assistantText) == ["stopped"])
    }

    @Test func nonZeroExitCarriesStderr() async throws {
        let p = try shChild("echo '  first problem' >&2; echo second >&2; exit 4")
        let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter())
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.count == 1)
        guard case .exit(let code, let err, let errCode) = evs[0].kind else {
            Issue.record("no exit")
            return
        }
        #expect(code == 4)
        #expect(err == "first problem")
        #expect(errCode == "process_exited")
        #expect(s.lastError?.code == "process_exited")
    }

    @Test func slowConsumerReachesTheEnd() async throws {
        let p = try shChild(
            "i=0; while [ $i -lt 300 ]; do printf '{\"type\":\"assistant\",\"text\":\"%d\"}\\n' $i; i=$((i+1)); done")
        let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter())
        var texts: [String] = []
        var last: Event?
        for await e in s.events {
            if let t = e.assistantText { texts.append(t) }
            last = e
            try await Task.sleep(for: .microseconds(200))
        }
        #expect(texts == (0..<300).map(String.init))
        #expect(last?.isExit == true)
    }

    @Test func closeWithStalledConsumer() async throws {
        // 400 frames fill the 256-slot buffer, then the child waits on stdin.
        let p = try shChild(
            "i=0; while [ $i -lt 400 ]; do printf '{\"type\":\"assistant\",\"text\":\"%d\"}\\n' $i; i=$((i+1)); done; cat >/dev/null"
        )
        var config = WireConfig()
        config.stageTimeout = .milliseconds(300)
        let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter(), config: config)
        // Let the buffer fill while no one reads.
        try await Task.sleep(for: .milliseconds(300))
        try await withTimeout { await s.close() }
        #expect(p.exitStatus != nil)
        let evs = try await withTimeout { await s.events.collect() }
        #expect(evs.last?.isExit == true)
        #expect(evs.filter(\.isExit).count == 1)
        #expect(evs.count <= 401)
    }

    @Test func cancelledConsumerClosesTheSession() async throws {
        let p = try shChild("cat >/dev/null")
        let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter())
        let consumer = Task { for await _ in s.events {} }
        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        _ = await consumer.value
        try await eventually { p.exitStatus != nil }
        #expect(!ProcessGroup.alive(p.pid))
    }

    @Test func frameLogRecordsBothDirections() async throws {
        let tmp = try TempDir()
        let path = tmp.url.appendingPathComponent("frames.ndjson")
        var config = WireConfig()
        config.logPath = path
        let p = try ChildProcess.spawn(SpawnOptions(executable: URL(fileURLWithPath: "/bin/cat")))
        let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter(), config: config)
        try await s.prompt(Prompt("hi"))
        _ = try await withTimeout { await s.events.next(where: \.isResult) }
        await s.close()
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
            JSONValue.parse(String($0))
        }
        #expect(lines.map { $0["dir"].stringValue } == ["out", "in"])
        #expect(lines[0]["frame"]?["text"] == "hi")
        #expect(lines[1]["frame"]?["type"] == "user")
        #expect(lines[0]["at"]?.string?.contains("T") == true)
    }

    @Test func manySessionsInParallel() async throws {
        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let p = try ChildProcess.spawn(SpawnOptions(executable: URL(fileURLWithPath: "/bin/cat")))
                    let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter())
                    try await s.prompt(Prompt("n\(i)"))
                    let r = await s.events.next(where: \.isResult)
                    await s.close()
                    if case .result(let t) = r?.kind { return t.text }
                    return nil
                }
            }
            var got = Set<String>()
            for try await t in group { if let t { got.insert(t) } }
            #expect(got == Set((0..<50).map { "n\($0)" }))
        }
    }

    @Test func sessionIsReleasedAfterClose() async throws {
        let ref = WeakRef()
        let ended = Locked(false)
        do {
            let p = try ChildProcess.spawn(SpawnOptions(executable: URL(fileURLWithPath: "/bin/cat")))
            let s = try await WireSession.start(harness: .fake, process: p, adapter: LineAdapter())
            ref.value = s
            let events = s.events
            let reader = Task {
                for await _ in events {}
                ended.withLock { $0 = true }
            }
            await s.close()
            _ = await reader.value
        }
        #expect(ended.value)
        try await eventually { ref.value == nil }
    }
}
