import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

// A small copy of the kit of AgentBinderNativeTests. A test target cannot import another one.

struct TimeoutError: Error {}

/// Polls `condition` until it is true, or fails after `timeout`.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async throws -> Bool) async throws {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try await condition() { return }
    Issue.record("condition not met in \(timeout)")
    throw TimeoutError()
}

/// A temporary folder that goes away with the value.
final class Scratch: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("agentbinder-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ rel: String, _ text: String) throws -> URL {
        let f = url.appendingPathComponent(rel)
        try Data(text.utf8).write(to: f)
        return f
    }
}

/// A model that replays one list of parts for each call and records the requests.
final class ScriptedModel: Model {
    let name = "scripted"
    private let steps: Locked<[[StreamPart]]>
    let requests = Locked<[ModelRequest]>([])

    init(_ steps: [[StreamPart]]) { self.steps = Locked(steps) }

    func stream(_ r: ModelRequest) -> AsyncThrowingStream<StreamPart, any Error> {
        requests.withLock { $0.append(r) }
        let step = steps.withLock { s -> [StreamPart]? in s.isEmpty ? nil : s.removeFirst() }
        return AsyncThrowingStream { c in
            guard let step else { return c.finish(throwing: NativeError("script_empty", "no more steps")) }
            for x in step { c.yield(x) }
            c.finish()
        }
    }
}

extension StreamPart {
    static func text(_ t: String) -> [StreamPart] {
        [.textDelta(t), .finish(Finish(reason: .stop, raw: "end_turn", usage: ModelUsage(input: 10, output: 2)))]
    }
    static func calls(_ c: ToolCall...) -> [StreamPart] {
        c.map(StreamPart.toolCallDone) + [.finish(Finish(reason: .toolCalls, raw: "tool_use"))]
    }
}

extension ToolCall {
    static func call(_ id: String, _ name: String, _ json: String = "{}") -> ToolCall {
        ToolCall(id: id, name: name, input: Data(json.utf8))
    }
}

/// Reads all events of a session in the background.
final class Sink: Sendable {
    private let all = Locked<[Event]>([])

    init(_ s: any Session) {
        let all = all
        let stream = s.events
        Task { for await e in stream { all.withLock { $0.append(e) } } }
    }

    var results: [TurnResult] {
        all.value.compactMap {
            if case .result(let r) = $0.kind { return r }
            return nil
        }
    }
    var tools: [ToolEvent] {
        all.value.compactMap {
            if case .tool(let t) = $0.kind { return t }
            return nil
        }
    }

    func waitResults(_ n: Int) async throws { try await eventually { self.results.count >= n } }
}

/// A runtime with a native driver of a config.
func runtime(_ cfg: NativeConfig, environment: [String: String]? = nil) async -> Runtime {
    let rt = Runtime(options: .init(useLoginShellPath: false, environment: environment))
    await rt.setDriver(NativeDriver(cfg), for: .native)
    return rt
}

func config(_ model: ScriptedModel, _ edit: (inout NativeConfig) -> Void = { _ in }) -> NativeConfig {
    var c = NativeConfig(newModel: { _, _ in model })
    edit(&c)
    return c
}

func request(id: String? = "s1") -> StartRequest {
    StartRequest(
        harness: .native, workingDirectory: FileManager.default.temporaryDirectory, sessionID: id,
        credentials: Credentials(format: .anthropic, apiKey: "k"))
}
