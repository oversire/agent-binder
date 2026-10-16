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

    private typealias Reply = Result<JSONValue, any Error>

    private enum Slot {
        case registered
        case waiting(CheckedContinuation<Reply, Never>)
        case done(Reply)
    }

    private struct State {
        var writer: FrameWriter?
        var next: Int64 = 0
        var waiters: [String: Slot] = [:]
        var dead: (any Error)?
    }

    private let state: Locked<State>
    private let idPrefix: String?

    /// Makes a peer. Attach the writer later when the adapter gets it in the handshake.
    init(writer: FrameWriter? = nil, idPrefix: String? = nil) {
        state = Locked(State(writer: writer))
        self.idPrefix = idPrefix
    }

    func attach(_ writer: FrameWriter) {
        state.withLock { $0.writer = writer }
    }

    /// The number of callers that wait for a reply.
    var pending: Int { state.withLock { $0.waiters.count } }

    /// The error that stopped the peer, if one did.
    var dead: (any Error)? { state.withLock { $0.dead } }

    /// A fresh id. Prompts that the adapter matches itself use the same counter, so ids never repeat.
    func nextID() -> JSONValue {
        let n = state.withLock { s -> Int64 in
            s.next += 1
            return s.next
        }
        if let idPrefix { return .string("\(idPrefix)\(n)") }
        return .int(n)
    }

    // MARK: outbound

    /// Sends a request and waits for its reply. A nil or zero timeout waits without a limit.
    @discardableResult
    func request(_ method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        let id = nextID()
        let key = Self.key(id)
        // The slot comes before the write, so a fast reply finds it; the write stays in line with other frames.
        try state.withLock { s in
            if let d = s.dead { throw d }
            s.waiters[key] = .registered
        }
        if let timeout, timeout > .zero {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
                resume(key, .failure(AgentBinderError.timeout(method)))
            }
        }
        do {
            try await write(Self.frame(id: id, method: method, params: params))
        } catch {
            _ = state.withLock { $0.waiters.removeValue(forKey: key) }
            throw error
        }
        let reply: Reply = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Reply, Never>) in
                let ready = state.withLock { s -> Reply? in
                    switch s.waiters[key] {
                    case .done(let r):
                        s.waiters[key] = nil
                        return r
                    case .registered:
                        s.waiters[key] = .waiting(cont)
                        return nil
                    case .waiting, nil:
                        return .failure(s.dead ?? AgentBinderError.sessionClosed)
                    }
                }
                if let ready { cont.resume(returning: ready) }
            }
        } onCancel: {
            resume(key, .failure(CancellationError()))
        }
        return try reply.get()
    }

    /// Sends a request and decodes its result.
    func request<T: Decodable>(
        _ method: String, params: JSONValue? = nil, timeout: Duration? = nil, as type: T.Type
    ) async throws -> T {
        let v = try await request(method, params: params, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: v.jsonData)
        } catch {
            throw AgentBinderError.invalidRequest("\(method): decode result: \(error)")
        }
    }

    /// Sends a request without a waiter and returns its id. The adapter matches the reply itself.
    func send(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let id = nextID()
        try await write(Self.frame(id: id, method: method, params: params))
        return id
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
        let (writer, dead) = state.withLock { ($0.writer, $0.dead) }
        if let dead { throw dead }
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
        let delivered = resume(Self.key(id), error.map { .failure($0) } ?? .success(result))
        return .response(Response(id: id, result: msg["result"], error: error, delivered: delivered))
    }

    /// Stops the peer. Every waiting caller and every later call throws `error`.
    func failAll(_ error: any Error = AgentBinderError.sessionClosed) {
        let (waiters, dead) = state.withLock { s -> ([CheckedContinuation<Reply, Never>], any Error) in
            if s.dead == nil { s.dead = error }
            var out: [CheckedContinuation<Reply, Never>] = []
            for (k, slot) in s.waiters {
                if case .waiting(let c) = slot {
                    out.append(c)
                    s.waiters[k] = nil
                } else {
                    s.waiters[k] = .done(.failure(s.dead!))
                }
            }
            return (out, s.dead!)
        }
        for w in waiters { w.resume(returning: .failure(dead)) }
    }

    // The first outcome wins. A caller that is not yet waiting finds it in its slot.
    @discardableResult
    private func resume(_ key: String, _ r: Reply) -> Bool {
        let (found, cont) = state.withLock { s -> (Bool, CheckedContinuation<Reply, Never>?) in
            switch s.waiters[key] {
            case .registered:
                s.waiters[key] = .done(r)
                return (true, nil)
            case .waiting(let c):
                s.waiters[key] = nil
                return (true, c)
            case .done, nil:
                return (false, nil)
            }
        }
        cont?.resume(returning: r)
        return found
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
