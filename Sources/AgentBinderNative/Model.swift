import AgentBinder
import Foundation

/// A language model behind a provider API.
///
/// ``stream(_:)`` yields exactly one ``StreamPart/finish(_:)``, or it throws. A cancel of the
/// consumer task cancels the HTTP request.
public protocol Model: Sendable {
    /// The model id that the provider gets.
    var name: String { get }
    /// Streams one model call.
    func stream(_ r: ModelRequest) -> AsyncThrowingStream<StreamPart, any Error>
}

/// One model call.
public struct ModelRequest: Sendable, Equatable {
    /// The system prompt. It is empty when there is none.
    public var system: String
    /// The history.
    public var messages: [Message]
    /// The tools that the model can call.
    public var tools: [ToolSpec]
    /// How the model picks a tool.
    public var toolChoice: ToolChoice
    /// The output token limit. Zero uses the provider default.
    public var maxOutputTokens: Int
    /// The reasoning effort: `low`, `medium`, `high` or `max`. Empty uses no reasoning setting.
    public var effort: String

    /// Makes a request.
    public init(
        system: String = "", messages: [Message], tools: [ToolSpec] = [], toolChoice: ToolChoice = .auto,
        maxOutputTokens: Int = 0, effort: String = ""
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
    }
}

/// How the model picks a tool.
public enum ToolChoice: Sendable, Equatable {
    /// The model decides.
    case auto
    /// The model calls no tool.
    case none
    /// The model calls a tool.
    case required
    /// The model calls this tool.
    case named(String)
}

/// One piece of a model stream.
public enum StreamPart: Sendable, Equatable {
    /// Answer text.
    case textDelta(String)
    /// Reasoning text.
    case reasoningDelta(String)
    /// The signature of the reasoning so far. The provider needs it again on the next call.
    case reasoningSignature(String)
    /// A tool call starts.
    case toolInputStart(id: String)
    /// A piece of the JSON input of a tool call.
    case toolInputDelta(id: String, fragment: String)
    /// A tool call is complete.
    case toolCallDone(ToolCall)
    /// The call ended. It is the last part.
    case finish(Finish)
}

/// Why a model call ended.
public enum FinishReason: String, Sendable, Codable {
    /// The model ended its answer.
    case stop
    /// The output token limit cut the answer.
    case length
    /// The model asks for tool calls.
    case toolCalls = "tool_calls"
    /// A content filter blocked the answer.
    case contentFilter = "content_filter"
    /// The model refused the request.
    case refusal
    /// The stream failed.
    case error
    /// Another reason.
    case other
}

/// The end of a model call.
public struct Finish: Sendable, Equatable {
    /// The normalized reason.
    public var reason: FinishReason
    /// The provider reason, for example `"end_turn"`.
    public var raw: String
    /// The token counters.
    public var usage: ModelUsage

    /// Makes a finish.
    public init(reason: FinishReason, raw: String = "", usage: ModelUsage = ModelUsage()) {
        self.reason = reason
        self.raw = raw
        self.usage = usage
    }
}

/// The token counters of one model call, in provider units.
///
/// OpenAI counts the cached tokens in ``input``. Anthropic does not.
public struct ModelUsage: Sendable, Equatable {
    /// Input tokens.
    public var input: Int64
    /// Output tokens.
    public var output: Int64
    /// Input tokens read from the prompt cache.
    public var cacheRead: Int64
    /// Input tokens written to the prompt cache.
    public var cacheWrite: Int64
    /// Reasoning tokens.
    public var reasoning: Int64

    /// Makes counters.
    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, reasoning: Int64 = 0)
    {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    /// The counters as a core usage record.
    public var usage: Usage {
        Usage(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheWrite)
    }

    static func + (a: ModelUsage, b: ModelUsage) -> ModelUsage {
        ModelUsage(
            input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite: a.cacheWrite + b.cacheWrite, reasoning: a.reasoning + b.reasoning)
    }
}

/// A failure of the native loop. Each case has a stable machine code.
public struct NativeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The stable machine code, for example `"model_refused"`.
    public var code: String
    /// The failure text, for logs. It is not UI text.
    public var message: String

    /// Makes an error.
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    /// The message.
    public var description: String { message }

    /// The store has no messages for the session.
    public static let notFound = NativeError("not_found", "native: no stored messages")

    static func config(_ m: String) -> NativeError { NativeError("native_config", m) }
}
