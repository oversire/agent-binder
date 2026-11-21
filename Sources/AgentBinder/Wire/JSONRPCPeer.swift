import Foundation

/// A JSON-RPC error object from the peer.
struct JSONRPCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The method is not found, or the capability is off.
    static let methodNotFound = -32601
    /// An internal error, for example a failed file-system call.
    static let internalError = -32603

    var code: Int
    var message: String
    var data: JSONValue?

    var description: String {
        if let data { return "jsonrpc error \(code): \(message) (\(data.jsonString))" }
        return "jsonrpc error \(code): \(message)"
    }

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    init?(_ v: JSONValue?) {
        guard let v, v.object != nil else { return nil }
        self.init(code: Int(v["code"]?.int ?? 0), message: v["message"].stringValue, data: v["data"])
    }
}

/// A JSON-RPC 2.0 peer over NDJSON lines.
///
/// It runs inside a ``WireAdapter``: the session gives it each stdout line, and it writes through
/// the ``FrameWriter``. Ids are integers from 1, from one counter for each peer.
final class JSONRPCPeer: Sendable {
    /// What an inbound line is.
    enum Inbound: Sendable, Equatable {
        /// A reply. `delivered` is false when no caller waited for the id.
        case response(Response)
        /// A notification. It has no reply.
        case notification(method: String, params: JSONValue?)
        /// A request of the peer. Reply with ``respond(id:result:)`` and the same id.
        case request(id: JSONValue, method: String, params: JSONValue?)
        /// A line that is not a JSON-RPC message.
        case invalid(Data)
    }

    /// One reply of the peer.
    struct Response: Sendable, Equatable {
        var id: JSONValue
        var result: JSONValue?
        var error: JSONRPCError?
        var delivered: Bool
    }

    private struct State {
        var writer: FrameWriter?
        var next: Int64 = 0
    }

    private let state: Locked<State>
    private let replies = ReplyTable<JSONValue>()

    /// Makes a peer. Attach the writer later when the adapter gets it in the handshake.
    init() {
        state = Locked(State())
    }

    func attach(_ writer: FrameWriter) {
        state.withLock { $0.writer = writer }
    }

    /// The number of callers that wait for a reply.
    var pending: Int { replies.count }

    /// The error that stopped the peer, if one did.
    var dead: (any Error)? { replies.dead }

    /// A fresh id. Prompts that the adapter matches itself use the same counter, so ids never repeat.
    func nextID() -> JSONValue {
        let n = state.withLock { s -> Int64 in
            s.next += 1
            return s.next
        }
        return .int(n)
    }

    // MARK: outbound

    /// Sends a request and waits for its reply. A nil or zero timeout waits without a limit.
    @discardableResult
    func request(_ method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        let id = nextID()
        let key = Self.key(id)
        // The slot comes before the write, so a fast reply finds it; the write stays in line with other frames.
        try replies.register(key)
        if let timeout { replies.expire(key, after: timeout, with: AgentBinderError.timeout(method)) }
        do {
            try await write(Self.frame(id: id, method: method, params: params))
        } catch {
            replies.remove(key)
            throw error
        }
        return try await replies.wait(key).get()
    }

    /// Sends a request without a waiter, with an id from ``nextID()``. Record the id before the call,
    /// because the reply can come before the call returns.
    func send(id: JSONValue, _ method: String, params: JSONValue? = nil) async throws {
        try await write(Self.frame(id: id, method: method, params: params))
    }

    /// Sends a notification.
    func notify(_ method: String, params: JSONValue? = nil) async throws {
        try await write(Self.frame(id: nil, method: method, params: params))
    }

    /// Replies to a request of the peer, with its id unchanged.
    func respond(id: JSONValue, result: JSONValue) async throws {
        try await write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Sends an error reply to a request of the peer.
    func respondError(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) async throws {
        var err: [String: JSONValue] = ["code": .int(Int64(code)), "message": .string(message)]
        if let data { err["data"] = data }
        try await write(["jsonrpc": "2.0", "id": id, "error": .object(err)])
    }

    private func write(_ frame: JSONValue) async throws {
        if let dead = replies.dead { throw dead }
        let writer = state.value.writer
        guard let writer else { throw AgentBinderError.sessionClosed }
        do {
            try await writer.write(frame)
        } catch {
            failAll(error)
            throw error
        }
    }

    private static func frame(id: JSONValue?, method: String, params: JSONValue?) -> JSONValue {
        var o: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { o["id"] = id }
        if let params { o["params"] = params }
        return .object(o)
    }

    // MARK: inbound

    /// Routes one inbound line. A reply resumes its caller; the rest goes back to the adapter.
    func handle(_ line: Data) -> Inbound {
        guard let msg = JSONValue.parse(line), msg.object != nil else { return .invalid(line) }
        let id = msg["id"].flatMap { $0.isNull ? nil : $0 }
        if let method = msg["method"]?.string, !method.isEmpty {
            if let id { return .request(id: id, method: method, params: msg["params"]) }
            return .notification(method: method, params: msg["params"])
        }
        guard let id else { return .invalid(line) }
        let error = JSONRPCError(msg["error"])
        let result = msg["result"] ?? .null
        let delivered = replies.resolve(Self.key(id), error.map { .failure($0) } ?? .success(result))
        return .response(Response(id: id, result: msg["result"], error: error, delivered: delivered))
    }

    /// Stops the peer. Every waiting caller and every later call throws `error`.
    func failAll(_ error: any Error = AgentBinderError.sessionClosed) {
        replies.failAll(error)
    }

    // 7 and "7" never share a key.
    private static func key(_ id: JSONValue) -> String {
        switch id {
        case .string(let s): return "s:" + s
        case .int(let n): return "n:\(n)"
        default:
            if let n = id.int { return "n:\(n)" }
            return "j:" + id.jsonString
        }
    }
}
