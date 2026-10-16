import Foundation

@testable import AgentBinder

/// An in-memory vendor peer. Each step waits for a frame that matches and sends its reply lines.
///
/// Frames that match no step go to ``unmatched``. Steps match in order.
final class ScriptedPeer: Sendable {
    struct Step: Sendable {
        var match: @Sendable (JSONValue) -> Bool
        var reply: @Sendable (JSONValue) -> [String]
    }

    private struct State {
        var steps: [Step] = []
        var unmatched: [JSONValue] = []
        var seen: [JSONValue] = []
    }

    let input: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    private let state = Locked(State())

    init() {
        (input, cont) = AsyncStream.makeStream(of: Data.self)
    }

    /// Adds a step.
    func expect(
        _ match: @escaping @Sendable (JSONValue) -> Bool,
        reply: @escaping @Sendable (JSONValue) -> [String] = { _ in [] }
    ) {
        state.withLock { $0.steps.append(Step(match: match, reply: reply)) }
    }

    /// Adds a step for a JSON-RPC request. The reply gets the request.
    func expect(method: String, reply: @escaping @Sendable (JSONValue) -> [String] = { _ in [] }) {
        expect({ $0["method"]?.string == method }, reply: reply)
    }

    /// Adds a step for a frame with a `type` field.
    func expect(type: String, reply: @escaping @Sendable (JSONValue) -> [String] = { _ in [] }) {
        expect({ $0["type"]?.string == type }, reply: reply)
    }

    /// Sends one line to the session.
    func send(_ line: String) { cont.yield(Data((line.hasSuffix("\n") ? line : line + "\n").utf8)) }

    /// Ends the stdout of the peer.
    func end() { cont.finish() }

    /// The sink of the session.
    var output: @Sendable (Data) -> Void {
        { [self] data in
            for part in data.split(separator: 0x0A) {
                guard let v = JSONValue.parse(Data(part)) else { continue }
                let step = state.withLock { s -> Step? in
                    s.seen.append(v)
                    guard let i = s.steps.firstIndex(where: { $0.match(v) }) else {
                        s.unmatched.append(v)
                        return nil
                    }
                    return s.steps.remove(at: i)
                }
                for line in step?.reply(v) ?? [] { send(line) }
            }
        }
    }

    /// Every frame that the session wrote.
    var seen: [JSONValue] { state.value.seen }
    /// The frames that matched no step.
    var unmatched: [JSONValue] { state.value.unmatched }
    /// The number of steps that still wait.
    var pending: Int { state.value.steps.count }

    /// Starts an in-memory session on this peer.
    func session(
        _ adapter: any WireAdapter, harness: Harness = .fake, config: WireConfig = WireConfig()
    ) async throws
        -> WireSession
    {
        try await WireSession.inMemory(harness: harness, adapter: adapter, input: input, output: output, config: config)
    }
}
