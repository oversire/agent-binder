import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

struct TimeoutError: Error {}

/// Polls `condition` until it is true, or fails after `timeout`.
func eventually(
    timeout: Duration = .seconds(5), _ sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async throws -> Bool
) async throws {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try await condition() { return }
    Issue.record("condition not met in \(timeout)", sourceLocation: sourceLocation)
    throw TimeoutError()
}

/// A temporary folder that goes away with the value.
final class Scratch: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("agentbinder-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var path: String { url.path }

    @discardableResult
    func write(_ rel: String, _ text: String) throws -> URL {
        let f = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: f)
        return f
    }

    func read(_ rel: String) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// A model that replays one step for each call and records the requests.
final class ScriptedModel: Model {
    enum Step: Sendable {
        case parts([StreamPart])
        case fail(any Error)
        /// Yields the parts, then waits until the consumer cancels.
        case hang([StreamPart])
    }

    let name: String
    private let steps: Locked<[Step]>
    let requests = Locked<[ModelRequest]>([])

    init(_ steps: [Step], name: String = "scripted") {
        self.steps = Locked(steps)
        self.name = name
    }

    var calls: Int { requests.value.count }

    func stream(_ r: ModelRequest) -> AsyncThrowingStream<StreamPart, any Error> {
        requests.withLock { $0.append(r) }
        let step = steps.withLock { s -> Step? in s.isEmpty ? nil : s.removeFirst() }
        return AsyncThrowingStream { c in
            let t = Task {
                switch step {
                case .parts(let p)?:
                    for x in p { c.yield(x) }
                    c.finish()
                case .fail(let e)?:
                    c.finish(throwing: e)
                case .hang(let p)?:
                    for x in p { c.yield(x) }
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    c.finish(throwing: CancellationError())
                case nil:
                    c.finish(throwing: NativeError("script_empty", "the script has no more steps"))
                }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

extension StreamPart {
    static func text(_ t: String) -> [StreamPart] { [.textDelta(t), .stop] }
    static let stop = StreamPart.finish(Finish(reason: .stop, raw: "end_turn", usage: ModelUsage(input: 10, output: 2)))
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
    private let task: Task<Void, Never>

    init(_ s: any Session) {
        let all = all
        let stream = s.events
        task = Task { for await e in stream { all.withLock { $0.append(e) } } }
    }

    var events: [Event] { all.value }
    var names: [String] { events.map(\.kind.name) }
    var results: [TurnResult] {
        events.compactMap {
            if case .result(let r) = $0.kind { return r }
            return nil
        }
    }
    var tools: [ToolEvent] {
        events.compactMap {
            if case .tool(let t) = $0.kind { return t }
            return nil
        }
    }
    var permissions: [PermissionRequest] {
        events.compactMap {
            if case .permission(let p) = $0.kind { return p }
            return nil
        }
    }
    var errors: [WireError] {
        events.compactMap {
            if case .error(let e) = $0.kind { return e }
            return nil
        }
    }
    var text: [String] {
        events.compactMap {
            if case .assistant(let t, false) = $0.kind { return t }
            return nil
        }
    }

    func waitResults(_ n: Int) async throws { try await eventually { self.results.count >= n } }
    func waitEnd() async { await task.value }
}

/// A runtime with a native driver of a config.
func runtime(_ cfg: NativeConfig) async -> Runtime {
    let rt = Runtime(options: .init(useLoginShellPath: false))
    await rt.setDriver(NativeDriver(cfg), for: .native)
    return rt
}

func config(_ model: ScriptedModel, _ edit: (inout NativeConfig) -> Void = { _ in }) -> NativeConfig {
    var c = NativeConfig(newModel: { _, _ in model })
    edit(&c)
    return c
}

func request(_ dir: URL = FileManager.default.temporaryDirectory, id: String? = "s1") -> StartRequest {
    StartRequest(
        harness: .native, workingDirectory: dir, sessionID: id,
        credentials: Credentials(format: .anthropic, apiKey: "k"))
}

/// A tool that echoes its `text` input.
struct EchoTool: Tool {
    struct In: Decodable, Sendable { var text: String }
    var name = "echo"
    var readOnly = true
    var kind = ToolKind.other

    var spec: ToolSpec {
        ToolSpec(
            name: name, inputSchema: ToolSpec.strings(["text"], required: ["text"]),
            annotations: ToolAnnotations(readOnly: readOnly, kind: kind))
    }

    func call(_ input: Data?) async throws -> ToolResult {
        try await FuncTool(spec) { (i: In) in "echo: \(i.text)" }.call(input)
    }
}
