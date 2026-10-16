import AgentBinder
import Foundation

/// Sends one streaming provider request, with retries before the first byte of the response.
struct ProviderHTTP: Sendable {
    static let maxRetries = 2
    static let maxBody = 64 << 10

    let provider: String
    let session: URLSession
    /// The wait between two tries. Tests replace it.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Opens the response body. A non-2xx status throws ``ProviderError``.
    func open(_ r: URLRequest) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            let failure: ProviderError
            let retry: Bool
            do {
                let (bytes, resp) = try await session.bytes(for: r)
                let h = resp as? HTTPURLResponse
                let status = h?.statusCode ?? 0
                if (200..<300).contains(status) { return bytes }
                failure = try await error(status: status, response: h, body: bytes)
                retry = Self.retryable(status: status, shouldRetry: h?.value(forHTTPHeaderField: "x-should-retry"))
            } catch let e as URLError where e.code != .cancelled {
                failure = ProviderError(provider: provider, type: "connection_error", message: e.localizedDescription)
                retry = true
            }
            guard retry, attempt < Self.maxRetries else { throw failure }
            try await sleep(Self.wait(attempt: attempt, retryAfter: failure.retryAfter))
            attempt += 1
        }
    }

    /// Retries a timeout, a conflict, a rate limit and a server error. `x-should-retry` wins.
    static func retryable(status: Int, shouldRetry: String?) -> Bool {
        switch shouldRetry?.lowercased() {
        case "true": return true
        case "false": return false
        default: return status == 408 || status == 409 || status == 429 || status >= 500
        }
    }

    /// The wait that the provider asked for, up to 60 s, else min(0.5 s × 2ⁿ, 8 s) less up to 25 % jitter.
    static func wait(attempt: Int, retryAfter: Duration?, jitter: Double = .random(in: 0...0.25)) -> Duration {
        if let retryAfter, retryAfter >= .zero, retryAfter <= .seconds(60) { return retryAfter }
        let base = min(0.5 * pow(2, Double(attempt)), 8)
        return .milliseconds(Int(base * (1 - jitter) * 1000))
    }

    private func error(
        status: Int, response h: HTTPURLResponse?, body: URLSession.AsyncBytes
    ) async throws
        -> ProviderError
    {
        var data = Data()
        for try await b in body {
            data.append(b)
            if data.count >= Self.maxBody { break }
        }
        let text = String(decoding: data, as: UTF8.self)
        var type: String?
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both providers send {"error":{"type":…,"message":…}}.
        if let v = JSONValue.parse(data), let e = v["error"] {
            type = e["type"]?.string ?? e["code"]?.string
            message = e["message"]?.string ?? e.string ?? message
        }
        let id = h?.value(forHTTPHeaderField: "request-id") ?? h?.value(forHTTPHeaderField: "x-request-id")
        return ProviderError(
            provider: provider, status: status, requestID: id, type: type, message: message,
            retryAfter: Self.retryAfter(h))
    }

    static func retryAfter(_ h: HTTPURLResponse?) -> Duration? {
        if let ms = h?.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init) {
            return .milliseconds(Int(ms))
        }
        guard let v = h?.value(forHTTPHeaderField: "retry-after") else { return nil }
        if let s = Double(v) { return .milliseconds(Int(s * 1000)) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let d = f.date(from: v) else { return nil }
        return .milliseconds(Int(max(0, d.timeIntervalSinceNow) * 1000))
    }
}
