import Foundation

/// The REST client of one `opencode serve`: loopback origin, HTTP basic auth and the wire envelope.
struct OpenCodeHTTP: Sendable {
    static let requestTimeout: TimeInterval = 30
    static let healthTimeout: TimeInterval = 2

    let base: URL
    let username: String
    let password: String
    let wire: OpenCodeWire
    let maxBytes: Int
    let session: URLSession

    init(base: URL, username: String, password: String, wire: OpenCodeWire, maxBytes: Int) {
        self.base = base
        self.username = username
        self.password = password
        self.wire = wire
        self.maxBytes = maxBytes
        let c = URLSessionConfiguration.ephemeral
        // The server is on loopback: a system proxy must not see it.
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForResource = .greatestFiniteMagnitude
        c.httpCookieStorage = nil
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    /// A request with auth. On V1 a directory goes in the query and in `x-opencode-directory`.
    func request(
        _ method: String, _ path: String, directory: String? = nil, query: [URLQueryItem] = [],
        body: JSONValue? = nil, timeout: TimeInterval = requestTimeout
    ) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query
        let dir = wire.eventScoped ? directory.flatMap { $0.isEmpty ? nil : $0 } : nil
        if let dir { items.append(URLQueryItem(name: "directory", value: dir)) }
        if !items.isEmpty { c.queryItems = items }
        var r = URLRequest(url: c.url!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(
            "Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let dir { r.setValue(dir, forHTTPHeaderField: "x-opencode-directory") }
        if let body {
            r.httpBody = body.jsonData
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Runs one REST call. `path` has no wire prefix. A status of 400 or more throws.
    @discardableResult
    func call(
        _ method: String, _ path: String, directory: String? = nil, query: [URLQueryItem] = [],
        body: JSONValue? = nil
    ) async throws -> JSONValue {
        let r = request(method, wire.prefix + path, directory: directory, query: query, body: body)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: r)
        } catch {
            throw AgentBinderError.vendor(
                code: 0, message: "\(wire.harness) \(method) \(path): \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.count > maxBytes ? data.prefix(maxBytes) : data
        guard status < 400 else {
            throw AgentBinderError.vendor(
                code: status, message: "\(wire.harness) \(method) \(path): \(wire.errorText(body, status: status))")
        }
        return wire.decode(body)
    }

    /// The health verdict of one poll.
    enum Health: Equatable {
        case ready
        case notYet
        /// The path answers 404 or HTML: the binary speaks the other wire.
        case wrongWire(String)
    }

    func health() async -> Health {
        let r = request("GET", wire.healthPath, timeout: Self.healthTimeout)
        guard let (data, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else {
            return .notYet
        }
        let type = h.value(forHTTPHeaderField: "Content-Type") ?? ""
        // Quirk: V2 serves its web UI on unknown paths.
        if h.statusCode == 404 || type.hasPrefix("text/html") {
            return .wrongWire("\(wire.healthPath) answers HTTP \(h.statusCode) \(type)")
        }
        return h.statusCode == 200 && wire.ready(data.prefix(64 << 10)) ? .ready : .notYet
    }

    func close() { session.invalidateAndCancel() }
}
