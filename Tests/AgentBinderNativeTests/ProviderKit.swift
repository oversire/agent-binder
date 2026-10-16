import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

/// A canned HTTP reply.
struct Reply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var failure: URLError?

    static func sse(_ fixture: String) throws -> Reply {
        Reply(headers: ["content-type": "text/event-stream"], body: try Data(contentsOf: Stub.fixture(fixture)))
    }

    static func sse(text: String) -> Reply {
        Reply(headers: ["content-type": "text/event-stream"], body: Data(text.utf8))
    }

    static func status(_ s: Int, _ body: String = "", headers: [String: String] = [:]) -> Reply {
        Reply(status: s, headers: headers, body: Data(body.utf8))
    }

    static func fail(_ c: URLError.Code) -> Reply { Reply(failure: URLError(c)) }
}

/// A recorded request.
struct Seen: Sendable {
    var url: URL
    var headers: [String: String]
    var body: JSONValue
}

/// Serves the replies of one test. The `x-stub` header picks the test, so tests run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let replies = Locked<[String: [Reply]]>([:])
    static let seen = Locked<[String: [Seen]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "x-stub") ?? ""
        let s = Seen(
            url: request.url!, headers: request.allHTTPHeaderFields ?? [:],
            body: JSONValue.parse(Self.body(request)) ?? .null)
        Self.seen.withLock { $0[key, default: []].append(s) }
        let r = Self.replies.withLock { all -> Reply? in
            guard var list = all[key], !list.isEmpty else { return nil }
            let r = list.removeFirst()
            all[key] = list
            return r
        }
        guard let r else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let f = r.failure {
            client?.urlProtocol(self, didFailWithError: f)
            return
        }
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(_ r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open()
        defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

/// The stub of one test.
struct Stub {
    let key = UUID().uuidString
    /// One session for all tests: the `x-stub` header routes the replies.
    static let shared: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }()

    var session: URLSession { Self.shared }
    let waits = Locked<[Duration]>([])

    init(_ replies: [Reply]) {
        StubProtocol.replies.withLock { [key] in $0[key] = replies }
    }

    var requests: [Seen] { StubProtocol.seen.value[key] ?? [] }

    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native/\(name)")
    }

    func credentials(_ f: Credentials.Format, headers: [String: String] = [:]) -> Credentials {
        Credentials(format: f, apiKey: "k", headers: headers.merging(["x-stub": key]) { a, _ in a })
    }

    func http(_ h: inout ProviderHTTP) {
        let waits = waits
        h.sleep = { d in waits.withLock { $0.append(d) } }
    }

    func anthropic(
        model: String? = nil, headers: [String: String] = [:], _ edit: (inout AnthropicModel.Options) -> Void = { _ in }
    ) throws -> AnthropicModel {
        var o = AnthropicModel.Options(session: session)
        edit(&o)
        var m = try AnthropicModel(credentials: credentials(.anthropic, headers: headers), model: model, options: o)
        http(&m.http)
        return m
    }

    func openai(model: String = "gpt-test", baseURL: URL? = nil, headers: [String: String] = [:]) throws -> OpenAIModel
    {
        var m = try OpenAIModel(
            credentials: credentials(.openai, headers: headers), model: model,
            options: OpenAIModel.Options(baseURL: baseURL, session: session))
        http(&m.http)
        return m
    }
}

/// The parts of one stream, and the error that ended it.
func collect(_ m: some Model, _ r: ModelRequest) async -> (parts: [StreamPart], error: (any Error)?) {
    var parts: [StreamPart] = []
    do {
        for try await p in m.stream(r) { parts.append(p) }
        return (parts, nil)
    } catch {
        return (parts, error)
    }
}

extension ModelRequest {
    static let hi = ModelRequest(messages: [.user("hi")])
}
