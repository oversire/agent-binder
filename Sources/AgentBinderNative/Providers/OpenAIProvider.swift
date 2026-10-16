import AgentBinder
import Foundation

/// A model on the OpenAI Chat Completions API, with streaming. It also works with compatible
/// gateways (Ollama, OpenRouter, vLLM, Groq, LM Studio) through a base URL that ends in `/v1`.
public struct OpenAIModel: Model {
    /// The default endpoint.
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    /// The options of the model.
    public struct Options: Sendable {
        /// An endpoint that wins over `Credentials.baseURL`.
        public var baseURL: URL?
        /// The URL session of the calls.
        public var session: URLSession

        /// Makes options.
        public init(baseURL: URL? = nil, session: URLSession = .shared) {
            self.baseURL = baseURL
            self.session = session
        }
    }

    /// The model id.
    public let name: String
    let credentials: Credentials
    let options: Options
    var http: ProviderHTTP

    /// Makes a model. The credentials format must be `openai`, the key must not be empty, and the
    /// model name is required: each gateway has its own names.
    public init(credentials: Credentials, model: String?, options: Options = Options()) throws {
        guard credentials.format == .openai else {
            throw NativeError.config(
                "openai: credentials format \(JSONValue.quote(credentials.format.rawValue)) is not \"openai\"")
        }
        guard !credentials.apiKey.isEmpty else { throw NativeError.config("openai: the API key is empty") }
        guard let model, !model.isEmpty else { throw NativeError.config("openai: the model name is required") }
        self.credentials = credentials
        self.options = options
        name = model
        http = ProviderHTTP(provider: "openai", session: options.session)
    }

    var baseURL: URL {
        let u = options.baseURL ?? credentials.baseURL ?? Self.defaultBaseURL
        var s = u.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? u
    }

    /// The first-party endpoint takes `max_completion_tokens`. Most gateways know only `max_tokens`.
    var firstParty: Bool { baseURL.host == Self.defaultBaseURL.host }

    /// Streams one call.
    public func stream(_ r: ModelRequest) -> AsyncThrowingStream<StreamPart, any Error> {
        AsyncThrowingStream { c in
            let t = Task {
                var s = OpenAIStream()
                do {
                    let bytes = try await http.open(try urlRequest(r))
                    for try await e in bytes.events {
                        if e.data == "[DONE]" { break }
                        for p in try s.handle(e.data) { c.yield(p) }
                    }
                    for p in s.finish() { c.yield(p) }
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }

    func urlRequest(_ r: ModelRequest) throws -> URLRequest {
        var u = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        u.httpMethod = "POST"
        u.timeoutInterval = 600
        for k in credentials.headers.keys.sorted() { u.setValue(credentials.headers[k], forHTTPHeaderField: k) }
        u.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        u.setValue("application/json", forHTTPHeaderField: "Content-Type")
        u.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        u.httpBody = try body(r).jsonData
        return u
    }
}

/// Folds the chunks of one Chat Completions stream into stream parts.
struct OpenAIStream {
    private var calls: [(index: Int64, id: String, name: String, args: String)] = []
    private var usage = ModelUsage()
    private var raw = ""

    mutating func handle(_ data: String) throws -> [StreamPart] {
        guard let v = JSONValue.parse(data) else { return [] }
        if let e = v["error"], !e.isNull {
            throw ProviderError(
                provider: "openai", type: e["type"]?.string ?? e["code"]?.string,
                message: "received error while streaming: " + (e["message"]?.string ?? e.jsonString))
        }
        var out: [StreamPart] = []
        for ch in v["choices"]?.array ?? [] {
            let d = ch["delta"]
            if let t = d?["content"]?.string, !t.isEmpty { out.append(.textDelta(t)) }
            for tc in d?["tool_calls"]?.array ?? [] {
                let index = tc["index"]?.int ?? 0
                let i: Int
                if let found = calls.firstIndex(where: { $0.index == index }) {
                    i = found
                } else {
                    calls.append((index, "", "", ""))
                    i = calls.count - 1
                }
                if let id = tc["id"]?.string, !id.isEmpty { calls[i].id = id }
                if let n = tc.at("function", "name")?.string, !n.isEmpty { calls[i].name = n }
                if let a = tc.at("function", "arguments")?.string, !a.isEmpty {
                    calls[i].args += a
                    out.append(.toolInputDelta(id: calls[i].id, fragment: a))
                }
            }
            if let f = ch["finish_reason"]?.string, !f.isEmpty { raw = f }
        }
        if let u = v["usage"], !u.isNull {
            usage = ModelUsage(
                input: u["prompt_tokens"]?.int ?? 0, output: u["completion_tokens"]?.int ?? 0,
                cacheRead: u.at("prompt_tokens_details", "cached_tokens")?.int ?? 0,
                reasoning: u.at("completion_tokens_details", "reasoning_tokens")?.int ?? 0)
        }
        return out
    }

    func finish() -> [StreamPart] {
        calls.map {
            .toolCallDone(ToolCall(id: $0.id, name: $0.name, input: $0.args.isEmpty ? nil : Data($0.args.utf8)))
        }
            + [.finish(Finish(reason: Self.reason(raw), raw: raw, usage: usage))]
    }

    static func reason(_ s: String) -> FinishReason {
        switch s {
        case "stop": return .stop
        case "length": return .length
        case "tool_calls", "function_call": return .toolCalls
        case "content_filter": return .contentFilter
        default: return .other
        }
    }
}
