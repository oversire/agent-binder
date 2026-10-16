import Foundation
import Network

@testable import AgentBinder

/// A small HTTP/1.1 server on 127.0.0.1 for the OpenCode tests.
///
/// A REST reply closes its connection. A GET of an event path stays open as a chunked
/// `text/event-stream`, and ``push(_:)`` writes to each open stream.
final class TestHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        /// Lowercase names.
        var headers: [String: String]
        var body: Data

        var json: JSONValue? { JSONValue.parse(body) }
    }

    struct Reply: Sendable {
        var status: Int
        var contentType: String
        var body: Data

        init(status: Int = 200, contentType: String = "application/json", _ body: String = "{}") {
            self.status = status
            self.contentType = contentType
            self.body = Data(body.utf8)
        }

        static func json(_ s: String) -> Reply { Reply(s) }
        static let empty = Reply(status: 204, "")
        static let notFound = Reply(status: 404, contentType: "text/plain", "not found")
    }

    typealias Handler = @Sendable (Request) -> Reply?

    private struct State {
        var requests: [Request] = []
        var routes: [String: Reply] = [:]
        var handlers: [Handler] = []
        var streams: [Int: NWConnection] = [:]
        var nextStream = 0
    }

    let eventPaths: Set<String>
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agentbinder.test-http")
    private let state = Locked(State())

    private init(listener: NWListener, eventPaths: Set<String>) {
        self.listener = listener
        self.eventPaths = eventPaths
    }

    static func start(eventPaths: Set<String> = ["/event", "/api/event"]) async throws -> TestHTTPServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        let s = TestHTTPServer(listener: l, eventPaths: eventPaths)
        l.newConnectionHandler = { [weak s] c in s?.accept(c) }
        let ready = Latch()
        l.stateUpdateHandler = { st in
            if case .ready = st { ready.open() }
        }
        l.start(queue: s.queue)
        guard await ready.wait(timeout: .seconds(5)) else { throw TimeoutError(description: "listener not ready") }
        return s
    }

    deinit { listener.cancel() }

    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func http(_ wire: OpenCodeWire, maxBytes: Int = 1 << 20) -> OpenCodeHTTP {
        OpenCodeHTTP(base: url, username: "u", password: "p", wire: wire, maxBytes: maxBytes)
    }

    // MARK: script

    /// Answers `METHOD path` with a reply. A later route for the same pair wins.
    func route(_ method: String, _ path: String, _ reply: Reply) {
        state.withLock { $0.routes["\(method) \(path)"] = reply }
    }

    /// A handler runs before the routes. It returns nil to pass.
    func on(_ h: @escaping Handler) { state.withLock { $0.handlers.append(h) } }

    var requests: [Request] { state.value.requests }

    func requests(_ method: String, _ path: String) -> [Request] {
        requests.filter { $0.method == method && $0.path == path }
    }

    /// The event-stream connections that are open now.
    var openStreams: Int { state.value.streams.count }

    /// Writes one SSE event with a data line to each open stream.
    func push(_ json: String) { pushRaw("data: \(json)\n\n") }

    func pushRaw(_ text: String) {
        let chunk = Data((String(text.utf8.count, radix: 16) + "\r\n" + text + "\r\n").utf8)
        for c in state.value.streams.values { c.send(content: chunk, completion: .idempotent) }
    }

    /// Closes each open stream, as a server restart would.
    func dropStreams() {
        let all = state.withLock { s -> [NWConnection] in
            defer { s.streams = [:] }
            return Array(s.streams.values)
        }
        for c in all {
            c.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }

    func stop() {
        dropStreams()
        listener.cancel()
    }

    // MARK: connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.answer(c, req)
                return
            }
            if done || error != nil {
                c.cancel()
                return
            }
            self.read(c, buf)
        }
    }

    private func answer(_ c: NWConnection, _ r: Request) {
        state.withLock { $0.requests.append(r) }
        if r.method == "GET" && eventPaths.contains(r.path) {
            let id = state.withLock { s -> Int in
                s.nextStream += 1
                s.streams[s.nextStream] = c
                return s.nextStream
            }
            let head =
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\n\r\n"
            // Like the real servers, the stream starts with one event. URLSession holds the
            // response head until the first body bytes come.
            let hello =
                r.path.hasPrefix("/api")
                ? #"data: {"type":"server.connected","data":{}}"#
                : #"data: {"type":"server.connected","properties":{}}"#
            let first = hello + "\n\n"
            let chunk = String(first.utf8.count, radix: 16) + "\r\n" + first + "\r\n"
            c.send(content: Data((head + chunk).utf8), completion: .idempotent)
            c.stateUpdateHandler = { [weak self] st in
                switch st {
                case .cancelled, .failed: self?.state.withLock { _ = $0.streams.removeValue(forKey: id) }
                default: break
                }
            }
            return
        }
        let (handlers, routes) = state.withLock { ($0.handlers, $0.routes) }
        let reply = handlers.lazy.compactMap { $0(r) }.first ?? routes["\(r.method) \(r.path)"] ?? .notFound
        var head = "HTTP/1.1 \(reply.status) X\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
        if !reply.contentType.isEmpty { head += "Content-Type: \(reply.contentType)\r\n" }
        c.send(content: Data((head + "\r\n").utf8) + reply.body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// A full request, or nil when more bytes must come.
    static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        let target = URLComponents(string: String(first[1]))
        var query: [String: String] = [:]
        for q in target?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        return Request(
            method: String(first[0]), path: target?.path ?? String(first[1]), query: query, headers: headers,
            body: Data(body.prefix(length)))
    }
}
