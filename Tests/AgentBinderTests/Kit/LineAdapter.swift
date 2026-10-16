import Foundation

@testable import AgentBinder

/// A scripted codec for the wire tests. Its frames are small JSON objects:
/// `assistant`, `result`, `error`, `init` and `user` (the echo of a prompt, as `cat` gives).
final class LineAdapter: WireAdapter, TurnStateReporting, ConcurrentPrompting, Sendable {
    struct Options: Sendable {
        var handshake: (@Sendable (FrameWriter) async throws -> [Event])?
        var trackTurns = false
        var concurrent = false
    }

    let options: Options
    private let active = Locked(false)

    init(_ options: Options = Options()) { self.options = options }

    var turnActive: Bool { active.value }
    var concurrentPrompt: Bool { options.concurrent }

    func setActive(_ v: Bool) { active.withLock { $0 = v } }

    func handshake(_ w: FrameWriter) async throws -> [Event] {
        try await options.handshake?(w) ?? []
    }

    func encodePrompt(_ p: Prompt) throws -> Data {
        if options.trackTurns { setActive(true) }
        return JSONValue.object(["type": "user", "text": .string(p.text), "kind": .string(p.kind ?? "")]).frame
    }

    func parse(_ line: Data) -> [Event] {
        guard let v = JSONValue.parse(line) else {
            return [Event(.error(WireError(message: "not JSON", code: "parse_failed")))]
        }
        let text = v["text"].stringValue
        switch v["type"].stringValue {
        case "assistant": return [Event(.assistant(text: text, delta: false))]
        case "result":
            setActive(false)
            return [Event(.result(TurnResult(text: text)))]
        case "error": return [Event(.error(WireError(message: text, code: v["code"].stringValue)))]
        case "init": return [Event(.initialized, sessionID: v["id"]?.string)]
        case "user":
            setActive(false)
            return [Event(.assistant(text: text, delta: false)), Event(.result(TurnResult(text: text)))]
        default: return []
        }
    }

    func encodeDecision(id: String, _ d: Decision) throws -> Data {
        JSONValue.object(["type": "decision", "id": .string(id), "allow": .bool(d.allow)]).frame
    }

    func exitEvents(code: Int32, stderr: String) -> [Event] { [] }
}

/// A ``LineAdapter`` that can steer.
final class SteeringAdapter: WireAdapter, TurnStateReporting, SteerSupporting, Sendable {
    let base = LineAdapter(.init(trackTurns: true))
    let steerError = Locked<AgentBinderError?>(nil)
    let steered = Locked<[String]>([])

    var turnActive: Bool { base.turnActive }

    func steer(_ p: Prompt) async throws {
        if let e = steerError.value { throw e }
        steered.withLock { $0.append(p.text) }
    }

    func handshake(_ w: FrameWriter) async throws -> [Event] { [] }
    func encodePrompt(_ p: Prompt) throws -> Data { try base.encodePrompt(p) }
    func parse(_ line: Data) -> [Event] { base.parse(line) }
    func encodeDecision(id: String, _ d: Decision) throws -> Data { try base.encodeDecision(id: id, d) }
    func exitEvents(code: Int32, stderr: String) -> [Event] { [] }
}

/// The two ends of an in-memory session: what the peer writes and what the session wrote.
final class MemoryPeer: Sendable {
    let input: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    let written = Locked<[Data]>([])

    init() {
        (input, cont) = AsyncStream.makeStream(of: Data.self)
    }

    var output: @Sendable (Data) -> Void { { [written] d in written.withLock { $0.append(d) } } }

    func send(_ s: String) { cont.yield(Data(s.utf8)) }
    func send(_ d: Data) { cont.yield(d) }
    func end() { cont.finish() }

    /// The frames that the session wrote, as JSON.
    var frames: [JSONValue] { written.value.compactMap { JSONValue.parse($0) } }
}

extension AsyncStream where Element == Event {
    /// Reads every event until the stream ends.
    func collect() async -> [Event] {
        var out: [Event] = []
        for await e in self { out.append(e) }
        return out
    }

    /// Reads events until one matches.
    func next(where match: (Event) -> Bool) async -> Event? {
        for await e in self where match(e) { return e }
        return nil
    }
}

extension Event {
    var isResult: Bool {
        if case .result = kind { return true }
        return false
    }

    var isExit: Bool {
        if case .exit = kind { return true }
        return false
    }

    var errorCode: String? {
        if case .error(let e) = kind { return e.code }
        return nil
    }

    var assistantText: String? {
        if case .assistant(let t, _) = kind { return t }
        return nil
    }
}
