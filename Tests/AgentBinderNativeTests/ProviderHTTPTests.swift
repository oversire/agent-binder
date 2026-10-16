import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("ProviderHTTPTests")
struct ProviderHTTPTests {
    @Test func retryable() {
        for s in [408, 409, 429, 500, 529] { #expect(ProviderHTTP.retryable(status: s, shouldRetry: nil)) }
        for s in [400, 401, 403, 404, 413] { #expect(!ProviderHTTP.retryable(status: s, shouldRetry: nil)) }
        #expect(ProviderHTTP.retryable(status: 400, shouldRetry: "true"))
        #expect(!ProviderHTTP.retryable(status: 503, shouldRetry: "FALSE"))
    }

    @Test func wait() {
        #expect(ProviderHTTP.wait(attempt: 0, retryAfter: nil, jitter: 0) == .milliseconds(500))
        #expect(ProviderHTTP.wait(attempt: 1, retryAfter: nil, jitter: 0.25) == .milliseconds(750))
        #expect(ProviderHTTP.wait(attempt: 9, retryAfter: nil, jitter: 0) == .seconds(8))
        #expect(ProviderHTTP.wait(attempt: 0, retryAfter: .seconds(3), jitter: 0) == .seconds(3))
        #expect(ProviderHTTP.wait(attempt: 0, retryAfter: .seconds(90), jitter: 0) == .milliseconds(500))
    }

    @Test func retryAfter() {
        func h(_ f: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 429, httpVersion: nil, headerFields: f)!
        }
        #expect(ProviderHTTP.retryAfter(h(["retry-after-ms": "250", "retry-after": "9"])) == .milliseconds(250))
        #expect(ProviderHTTP.retryAfter(h(["retry-after": "1.5"])) == .milliseconds(1500))
        #expect(ProviderHTTP.retryAfter(h(["retry-after": "Wed, 21 Oct 2015 07:28:00 GMT"])) == .zero)
        #expect(ProviderHTTP.retryAfter(h(["retry-after": "soon"])) == nil)
        #expect(ProviderHTTP.retryAfter(h([:])) == nil)
    }

    @Test func errorDescription() {
        let e = ProviderError(
            provider: "anthropic", status: 429, requestID: "req_1", type: "rate_limit_error", message: "slow")
        #expect(e.description == "anthropic: http 429 rate_limit_error: slow (request req_1)")
        #expect(ProviderError(provider: "openai", message: "x").description == "openai: x")
    }

    @Test func sseDecoder() throws {
        var d = SSEDecoder()
        var out: [SSEEvent] = []
        let text = ": comment\r\nevent: a\r\ndata: 1\r\ndata:2\r\nid: 7\r\n\r\n\ndata: tail"
        for b in Array(text.utf8) {
            if let e = try d.feed(b) { out.append(e) }
        }
        if let e = d.finish() { out.append(e) }
        #expect(out == [SSEEvent(event: "a", data: "1\n2"), SSEEvent(event: "", data: "tail")])
        #expect(d.finish() == nil)
    }
}
