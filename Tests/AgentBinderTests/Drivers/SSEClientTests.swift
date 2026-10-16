import Foundation
import Testing

@testable import AgentBinder

private func events(_ text: String, maxLine: Int = 1 << 20, split: Int = 1 << 30) -> [String] {
    var p = SSEParser(maxLine: maxLine)
    var out: [Data] = []
    let bytes = Array(text.utf8)
    var i = 0
    while i < bytes.count {
        out += p.feed(bytes[i..<min(i + split, bytes.count)])
        i += split
    }
    if let last = p.finish() { out.append(last) }
    return out.map { String(decoding: $0, as: UTF8.self) }
}

@Suite("SSEParserTests")
struct SSEParserTests {
    @Test func dataLines() {
        #expect(events("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n") == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test func multiLineDataJoins() {
        #expect(events("data: one\ndata:  two \n\n") == ["one\ntwo"])
    }

    @Test func otherFieldsAreIgnored() {
        #expect(events("event: message\nid: 7\nretry: 100\n: keep-alive\ndata: x\n\n: ping\n\n") == ["x"])
    }

    @Test func carriageReturns() {
        #expect(events("data: x\r\n\r\ndata: y\r\n \r\n") == ["x", "y"])
    }

    @Test func byteAtATime() {
        #expect(events("data: héllo\n\ndata: ü\n\n", split: 1) == ["héllo", "ü"])
    }

    @Test func overlongLineIsDroppedWhole() {
        let long = "data: " + String(repeating: "z", count: 100)
        #expect(events(long + "\n\ndata: ok\n\n", maxLine: 32, split: 7) == ["ok"])
    }

    @Test func endFlushesTheLastEvent() {
        #expect(events("data: a\n\ndata: tail") == ["a", "tail"])
        #expect(events("data: \n\n") == [])
    }
}

@Suite("SSEClientTests")
struct SSEClientTests {
    @Test func streamsAndReconnects() async throws {
        let srv = try await TestHTTPServer.start()
        let got = Locked<[String]>([])
        let opened = Locked(0)
        let client = SSEClient(http: srv.http(.v1))
        let t = Task {
            try await client.run(
                directory: "/w", onOpen: { opened.withLock { $0 += 1 } },
                onEvent: { d in got.withLock { $0.append(String(decoding: d, as: UTF8.self)) } })
        }
        try await eventually { srv.openStreams == 1 }
        srv.pushRaw("data: a\n\n")
        srv.pushRaw("data: b")
        srv.pushRaw("\n\n")
        try await eventually { got.value.dropFirst() == ["a", "b"] }
        #expect(got.value.first?.contains("server.connected") == true)
        #expect(opened.value == 1)
        let r = try #require(srv.requests("GET", "/event").first)
        #expect(r.query["directory"] == "/w" && r.headers["x-opencode-directory"] == "/w")
        #expect(r.headers["accept"] == "text/event-stream")
        #expect(r.headers["authorization"] == "Basic " + Data("u:p".utf8).base64EncodedString())
        srv.dropStreams()
        _ = try await withTimeout { try await t.value }
    }

    @Test func errorStatusThrows() async throws {
        let srv = try await TestHTTPServer.start(eventPaths: [])
        srv.route("GET", "/api/event", TestHTTPServer.Reply(status: 401, "{}"))
        let client = SSEClient(http: srv.http(.v2))
        await #expect(throws: AgentBinderError.self) {
            try await client.run(directory: nil, onOpen: { Issue.record("opened") }, onEvent: { _ in })
        }
    }
}
