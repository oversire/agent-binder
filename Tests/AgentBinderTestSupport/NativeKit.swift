import AgentBinder
import AgentBinderNative
import Foundation
import Testing

/// A model that replays one step for each call and records the requests.
package final class ScriptedModel: Model {
    package enum Step: Sendable {
        case parts([StreamPart])
        case fail(any Error)
        /// Yields the parts, then waits until the consumer cancels.
        case hang([StreamPart])
    }

    package let name: String
    private let steps: Locked<[Step]>
    package let requests = Locked<[ModelRequest]>([])

    package init(_ steps: [Step], name: String = "scripted") {
        self.steps = Locked(steps)
        self.name = name
    }

    package var calls: Int { requests.value.count }

    package func stream(_ r: ModelRequest) -> AsyncThrowingStream<StreamPart, any Error> {
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
    package static func text(_ t: String) -> [StreamPart] { [.textDelta(t), .stop] }
    package static let stop = StreamPart.finish(
        Finish(reason: .stop, raw: "end_turn", usage: ModelUsage(input: 10, output: 2)))
    package static func calls(_ c: ToolCall...) -> [StreamPart] {
        c.map(StreamPart.toolCallDone) + [.finish(Finish(reason: .toolCalls, raw: "tool_use"))]
    }
}

extension ToolCall {
    package static func call(_ id: String, _ name: String, _ json: String = "{}") -> ToolCall {
        ToolCall(id: id, name: name, input: Data(json.utf8))
    }
}

/// Reads all events of a session in the background.
package final class Sink: Sendable {
    private let all = Locked<[Event]>([])
    private let task: Task<Void, Never>

    package init(_ s: any Session) {
        let all = all
        let stream = s.events
        task = Task { for await e in stream { all.withLock { $0.append(e) } } }
    }

    package var events: [Event] { all.value }
    package var names: [String] { events.map(\.kind.name) }
    package var results: [TurnResult] {
        events.compactMap {
            if case .result(let r) = $0.kind { return r }
            return nil
        }
    }
    package var tools: [ToolEvent] {
        events.compactMap {
            if case .tool(let t) = $0.kind { return t }
            return nil
        }
    }
    package var permissions: [PermissionRequest] {
        events.compactMap {
            if case .permission(let p) = $0.kind { return p }
            return nil
        }
    }
    package var errors: [WireError] {
        events.compactMap {
            if case .error(let e) = $0.kind { return e }
            return nil
        }
    }
    package var text: [String] {
        events.compactMap {
            if case .assistant(let t, false) = $0.kind { return t }
            return nil
        }
    }

    package func waitResults(_ n: Int) async throws { try await eventually { self.results.count >= n } }
    package func waitEnd() async { await task.value }
}

/// A runtime with a native driver of a config.
package func runtime(_ cfg: NativeConfig, environment: [String: String]? = nil) async -> Runtime {
    let rt = Runtime(options: .init(useLoginShellPath: false, environment: environment))
    await rt.setDriver(NativeDriver(cfg), for: .native)
    return rt
}

package func config(_ model: ScriptedModel, _ edit: (inout NativeConfig) -> Void = { _ in }) -> NativeConfig {
    var c = NativeConfig(newModel: { _, _ in model })
    edit(&c)
    return c
}

package func request(_ dir: URL = FileManager.default.temporaryDirectory, id: String? = "s1") -> StartRequest {
    StartRequest(
        harness: .native, workingDirectory: dir, sessionID: id,
        credentials: Credentials(format: .anthropic, apiKey: "k"))
}
