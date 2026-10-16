import Foundation

/// One normalized event from a vendor session.
///
/// A turn emits status, progress and permission events, then exactly one ``Kind/result(_:)``.
/// ``Kind/exit(code:error:errorCode:)`` is always the last event of a session.
public struct Event: Sendable {
    /// What happened.
    public var kind: Kind
    /// The time the library saw the event.
    public var at: Date
    /// The number of user turns that the session wrote. It is 1 for the first turn.
    public var turn: Int
    /// The vendor session id, when it is known.
    public var sessionID: String?
    /// The vendor frame, for logs and fixtures.
    public var raw: Data?

    /// Makes an event. A session fills `turn` and `sessionID` when they are empty.
    public init(_ kind: Kind, at: Date = Date(), turn: Int = 0, sessionID: String? = nil, raw: Data? = nil) {
        self.kind = kind
        self.at = at
        self.turn = turn
        self.sessionID = sessionID
        self.raw = raw
    }

    /// The event vocabulary.
    public enum Kind: Sendable {
        /// The vendor session is live.
        case initialized
        /// Assistant text. `delta` is true for a stream fragment.
        case assistant(text: String, delta: Bool)
        /// Reasoning text that the model shows apart from the answer.
        case thought(text: String, delta: Bool)
        /// The echo of a user turn.
        case user(text: String)
        /// A tool started, completed or failed.
        case tool(ToolEvent)
        /// The vendor asks for a decision. Answer it with ``Session/answer(_:_:)``.
        case permission(PermissionRequest)
        /// The end of a turn. There is exactly one for each turn.
        case result(TurnResult)
        /// A classified failure.
        case error(WireError)
        /// Token and cost counters.
        case usage(Usage)
        /// A coarse status signal of the session.
        case status(SessionStatus, text: String?)
        /// The plan limit windows of the account.
        case limits(Limits)
        /// The session ended. It is always the last event.
        case exit(code: Int32?, error: String?, errorCode: String?)
    }
}

extension Event.Kind {
    /// The stable name of the kind, for example `"assistant"`.
    public var name: String {
        switch self {
        case .initialized: return "init"
        case .assistant: return "assistant"
        case .thought: return "thought"
        case .user: return "user"
        case .tool: return "tool"
        case .permission: return "permission"
        case .result: return "result"
        case .error: return "error"
        case .usage: return "usage"
        case .status: return "status"
        case .limits: return "limits"
        case .exit: return "exit"
        }
    }
}

/// The coarse class of a tool call.
///
/// A consumer uses it to render or to approve a call without vendor tool names.
public enum ToolKind: String, Sendable, Codable, CaseIterable {
    /// The tool reads a file or a URL.
    case read
    /// The tool changes a file.
    case edit
    /// The tool runs a command.
    case exec
    /// The tool is on an MCP server.
    case mcp
    /// The tool searches files or the web.
    case search
    /// Any other tool.
    case other
}

/// The lifecycle step of a tool call.
public enum ToolStatus: String, Sendable, Codable {
    /// The tool started.
    case started
    /// The tool completed.
    case completed
    /// The tool failed.
    case failed
    /// The turn or the process ended before the tool ended.
    case cancelled
}

/// One tool call: its start or its end.
public struct ToolEvent: Sendable, Equatable {
    /// The vendor tool-call id.
    public var id: String
    /// The vendor tool name.
    public var name: String
    /// The coarse class of the tool.
    public var kind: ToolKind
    /// The tool input, usually JSON text.
    public var input: String
    /// The tool output.
    public var output: String
    /// The lifecycle step.
    public var status: ToolStatus
    /// The files that an edit changes, when the protocol names them.
    public var paths: [String]
    /// The exit code of a command, when the vendor reports it.
    public var exitCode: Int32?

    /// Makes a tool event.
    public init(
        id: String = "", name: String = "", kind: ToolKind = .other, input: String = "", output: String = "",
        status: ToolStatus = .started, paths: [String] = [], exitCode: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.input = input
        self.output = output
        self.status = status
        self.paths = paths
        self.exitCode = exitCode
    }
}

/// A vendor request for a decision before a tool runs.
public struct PermissionRequest: Sendable, Equatable {
    /// The id that ``Session/answer(_:_:)`` takes.
    public var id: String
    /// The vendor tool name.
    public var tool: String
    /// The coarse class of the tool.
    public var kind: ToolKind
    /// The question of the vendor, when it sends one.
    public var question: String
    /// The tool input, usually JSON text.
    public var input: String
    /// The answer options of the vendor, when it sends them.
    public var options: [String]
    /// The tool call that the request is for, when the vendor tells.
    public var toolUseID: String?

    /// Makes a permission request.
    public init(
        id: String, tool: String = "", kind: ToolKind = .other, question: String = "", input: String = "",
        options: [String] = [], toolUseID: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.kind = kind
        self.question = question
        self.input = input
        self.options = options
        self.toolUseID = toolUseID
    }
}

/// The answer to a ``PermissionRequest``.
public struct Decision: Sendable, Equatable {
    /// True lets the tool run.
    public var allow: Bool
    /// A note for the model. The vendor shows it to the model on a deny.
    public var message: String?
    /// A changed tool input, as JSON, where the vendor accepts one.
    public var updatedInput: Data?

    /// Makes a decision.
    public init(allow: Bool, message: String? = nil, updatedInput: Data? = nil) {
        self.allow = allow
        self.message = message
        self.updatedInput = updatedInput
    }

    /// Lets the tool run.
    public static func allow(message: String? = nil, updatedInput: Data? = nil) -> Decision {
        Decision(allow: true, message: message, updatedInput: updatedInput)
    }

    /// Stops the tool. The message goes to the model.
    public static func deny(_ message: String? = nil) -> Decision {
        Decision(allow: false, message: message)
    }
}

/// Token and cost counters, in vendor units.
public struct Usage: Sendable, Codable, Equatable {
    /// Input tokens.
    public var input: Int64
    /// Output tokens.
    public var output: Int64
    /// Input tokens read from the prompt cache.
    public var cacheRead: Int64
    /// Input tokens written to the prompt cache.
    public var cacheCreation: Int64
    /// The model that the vendor used.
    public var model: String?
    /// The cost in US dollars, when the vendor reports it.
    public var costUSD: Double

    /// Makes a usage record.
    public init(
        input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheCreation: Int64 = 0, model: String? = nil,
        costUSD: Double = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.model = model
        self.costUSD = costUSD
    }
}

/// The failure family of a turn or a session.
public enum EndReason: String, Sendable, Codable {
    /// The login is missing or bad.
    case auth
    /// A plan limit or a rate limit stopped the turn.
    case limit
    /// The plan does not include the request.
    case entitlement
    /// The vendor is overloaded.
    case overloaded
    /// The wire failed.
    case `protocol`
    /// The turn failed for another reason.
    case failed
    /// The child process did not start.
    case launch
    /// The reason is not known.
    case unknown
}

/// The end of one turn.
public struct TurnResult: Sendable, Equatable {
    /// The vendor subtype, for example `"success"` or `"error_max_turns"`.
    public var subtype: String
    /// True when the vendor marks the turn as failed.
    public var isError: Bool
    /// The final text of the turn.
    public var text: String
    /// The vendor session id.
    public var sessionID: String?
    /// The token counters of the turn.
    public var usage: Usage
    /// The classified failure family of an error result.
    public var endReason: EndReason?
    /// The classified machine code of an error result.
    public var code: String?

    /// Makes a turn result.
    public init(
        subtype: String = "success", isError: Bool = false, text: String = "", sessionID: String? = nil,
        usage: Usage = Usage(), endReason: EndReason? = nil, code: String? = nil
    ) {
        self.subtype = subtype
        self.isError = isError
        self.text = text
        self.sessionID = sessionID
        self.usage = usage
        self.endReason = endReason
        self.code = code
    }
}

/// A classified failure that the session reports as an event.
public struct WireError: Sendable, Equatable {
    /// The failure text, for logs. It is not UI text.
    public var message: String
    /// The stable machine code, for example `"frame_too_large"`.
    public var code: String
    /// The classified failure family.
    public var endReason: EndReason?
    /// Data that belongs to the failure, for example the text of dropped prompts.
    public var text: String?

    /// Makes a failure record.
    public init(message: String, code: String, endReason: EndReason? = nil, text: String? = nil) {
        self.message = message
        self.code = code
        self.endReason = endReason
        self.text = text
    }
}

/// The activity view of a session.
public enum SessionStatus: String, Sendable, Codable {
    /// The status is not known.
    case unknown = ""
    /// A turn runs.
    case running
    /// The session waits for a decision.
    case waiting
    /// No turn runs.
    case idle
}
