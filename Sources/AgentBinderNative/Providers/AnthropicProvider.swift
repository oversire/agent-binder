import AgentBinder
import Foundation

/// A model on the Anthropic Messages API, with streaming over server-sent events.
public struct AnthropicModel: Model {
    /// The default model.
    public static let defaultModel = "claude-sonnet-5-5"
    /// The default endpoint.
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    /// The output token limit when the request sets none.
    public static let defaultMaxTokens = 64000
    static let version = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// The options of the model.
    public struct Options: Sendable {
        /// An endpoint that wins over `Credentials.baseURL`.
        public var baseURL: URL?
        /// The URL session of the calls.
        public var session: URLSession
        /// Adds the server tool `web_search` with at most 3 uses in one call.
        public var webSearch: Bool
        /// Sends the top-level `cache_control`, so the API caches the longest stable prefix.
        public var promptCaching: Bool
        /// Asks the API to run a refused request again on the recommended model (`fallbacks: "default"`).
        /// Only the first-party endpoint gets it, and only for the models that take it.
        public var refusalFallback: Bool

        /// Makes options.
        public init(
            baseURL: URL? = nil, session: URLSession = .shared, webSearch: Bool = false, promptCaching: Bool = true,
            refusalFallback: Bool = true
        ) {
            self.baseURL = baseURL
            self.session = session
            self.webSearch = webSearch
            self.promptCaching = promptCaching
            self.refusalFallback = refusalFallback
        }
    }

    /// The model id.
    public let name: String
    let credentials: Credentials
    let options: Options
    var http: ProviderHTTP

    /// Makes a model. The credentials format must be `anthropic`, and the key must not be empty.
    public init(credentials: Credentials, model: String? = nil, options: Options = Options()) throws {
        guard credentials.format == .anthropic else {
            throw NativeError.config(
                "anthropic: credentials format \(JSONValue.quote(credentials.format.rawValue)) is not \"anthropic\"")
        }
        guard !credentials.apiKey.isEmpty else { throw NativeError.config("anthropic: the API key is empty") }
        self.credentials = credentials
        self.options = options
        name = model.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModel
        http = ProviderHTTP(provider: "anthropic", session: options.session)
    }

    var baseURL: URL { options.baseURL ?? credentials.baseURL ?? Self.defaultBaseURL }

    /// The first-party endpoint takes the newest request fields. A gateway can refuse them.
    var firstParty: Bool { baseURL.host == Self.defaultBaseURL.host }

    /// The models that take `fallbacks: "default"`.
    var takesFallback: Bool {
        ["claude-opus-5", "claude-fable-5", "claude-mythos-5"].contains { name.hasPrefix($0) }
            || name == "claude-sonnet-5-5"
    }

    var sendsFallback: Bool { options.refusalFallback && firstParty && takesFallback }

    /// Streams one call.
    public func stream(_ r: ModelRequest) -> AsyncThrowingStream<StreamPart, any Error> {
        AsyncThrowingStream { c in
            let t = Task {
                do {
                    let bytes = try await http.open(try urlRequest(r))
                    var s = AnthropicStream()
                    for try await e in bytes.events {
                        for p in try s.handle(e) { c.yield(p) }
                    }
                    c.yield(try s.finish())
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }

    func urlRequest(_ r: ModelRequest) throws -> URLRequest {
        var u = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        u.httpMethod = "POST"
        u.timeoutInterval = 600
        for (k, v) in credentials.headers { u.setValue(v, forHTTPHeaderField: k) }
        u.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")
        u.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        u.setValue("application/json", forHTTPHeaderField: "content-type")
        u.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if sendsFallback {
            let old = u.value(forHTTPHeaderField: "anthropic-beta").map { $0 + "," } ?? ""
            u.setValue(old + Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        u.httpBody = try body(r).jsonData
        return u
    }
}

/// Folds the events of one Messages stream into stream parts.
struct AnthropicStream {
    private var tools: [Int: (id: String, name: String, json: String)] = [:]
    private var usage = ModelUsage()
    private var stop = ""

    mutating func handle(_ e: SSEEvent) throws -> [StreamPart] {
        guard let v = JSONValue.parse(e.data) else { return [] }
        switch v["type"]?.string ?? e.event {
        case "message_start":
            let u = v.at("message", "usage")
            usage.input = u?["input_tokens"]?.int ?? 0
            usage.output = u?["output_tokens"]?.int ?? 0
            usage.cacheRead = u?["cache_read_input_tokens"]?.int ?? 0
            usage.cacheWrite = u?["cache_creation_input_tokens"]?.int ?? 0
        case "content_block_start":
            let b = v["content_block"]
            switch b?["type"]?.string {
            case "tool_use":
                let id = b?["id"].stringValue ?? ""
                tools[Int(v["index"]?.int ?? 0)] = (id, b?["name"].stringValue ?? "", "")
                return [.toolInputStart(id: id)]
            case "fallback":
                // A refused attempt ends here; the rest of the stream comes from the fallback model.
                return [.fallback(model: b?.at("to", "model")?.string ?? "")]
            default: break
            }
        case "content_block_delta":
            let d = v["delta"]
            switch d?["type"]?.string {
            case "text_delta": return [.textDelta(d?["text"].stringValue ?? "")]
            case "thinking_delta": return [.reasoningDelta(d?["thinking"].stringValue ?? "")]
            // Fixed on purpose: the signature goes back with the thinking block on the next call.
            case "signature_delta": return [.reasoningSignature(d?["signature"].stringValue ?? "")]
            case "input_json_delta":
                let i = Int(v["index"]?.int ?? 0)
                guard var t = tools[i] else { return [] }
                let frag = d?["partial_json"].stringValue ?? ""
                t.json += frag
                tools[i] = t
                return frag.isEmpty ? [] : [.toolInputDelta(id: t.id, fragment: frag)]
            default: break
            }
        case "content_block_stop":
            guard let t = tools.removeValue(forKey: Int(v["index"]?.int ?? 0)) else { return [] }
            return [.toolCallDone(ToolCall(id: t.id, name: t.name, input: Data((t.json.isEmpty ? "{}" : t.json).utf8)))]
        case "message_delta":
            if let s = v.at("delta", "stop_reason")?.string { stop = s }
            let u = v["usage"]
            // The values are totals so far: each one that is set replaces the old one.
            if let n = u?["output_tokens"]?.int, n > 0 { usage.output = n }
            if let n = u?["input_tokens"]?.int, n > 0 { usage.input = n }
            if let n = u?["cache_read_input_tokens"]?.int, n > 0 { usage.cacheRead = n }
            if let n = u?["cache_creation_input_tokens"]?.int, n > 0 { usage.cacheWrite = n }
        case "error":
            throw ProviderError(
                provider: "anthropic", type: v.at("error", "type")?.string,
                message: v.at("error", "message")?.string ?? e.data)
        default: break
        }
        return []
    }

    func finish() throws -> StreamPart {
        guard !stop.isEmpty else {
            throw ProviderError(
                provider: "anthropic", type: "stream_incomplete", message: "the stream ended before a stop reason")
        }
        return .finish(Finish(reason: Self.reason(stop), raw: stop, usage: usage))
    }

    static func reason(_ s: String) -> FinishReason {
        switch s {
        case "end_turn": return .stop
        case "max_tokens": return .length
        case "tool_use": return .toolCalls
        case "refusal": return .refusal
        default: return .other
        }
    }
}
