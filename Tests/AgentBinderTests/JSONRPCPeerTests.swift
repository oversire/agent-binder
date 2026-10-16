import Foundation
import Testing

@testable import AgentBinder

/// A peer with a captured stdin.
private struct Harness {
    let peer: JSONRPCPeer
    let written = Locked<[Data]>([])

    init(fail: (any Error)? = nil) {
        let written = written
        let w = FrameWriter(harness: .fake, log: nil, onSessionID: { _ in }) { d in
            if let fail { throw fail }
            written.withLock { $0.append(d) }
        }
        peer = JSONRPCPeer(writer: w)
    }

    func frame(_ i: Int) async throws -> JSONValue {
        try await eventually { written.value.count > i }
        return JSONValue.parse(written.value[i])!
    }

    func raw(_ i: Int) -> String { String(decoding: written.value[i], as: UTF8.self) }

    func reply(_ id: JSONValue, _ result: String) -> JSONRPCPeer.Inbound {
        peer.handle(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id.jsonString),\"result\":\(result)}".utf8))
    }
}

private struct Boom: Error, Equatable {}

private func isResponse(_ i: JSONRPCPeer.Inbound) -> Bool {
    if case .response = i { return true }
    return false
}

@Suite("JSONRPCPeerTests")
struct JSONRPCPeerTests {
    @Test func requestSendsNumericIDAndMatchesReply() async throws {
        let h = Harness()
        let call = Task { try await h.peer.request("session/new", params: ["cwd": "/tmp"]) }
        let f = try await h.frame(0)
        #expect(f["id"] == .int(1))
        #expect(f["method"] == "session/new")
        #expect(f["jsonrpc"] == "2.0")
        #expect(h.raw(0).contains("\"id\":1,"))
        #expect(isResponse(h.reply(f["id"]!, "{\"ok\":true}")))
        #expect(try await call.value == ["ok": true])
        #expect(h.peer.pending == 0)
    }

    @Test func respondEchoesStringID() async throws {
        let h = Harness()
        let line =
            #"{"jsonrpc":"2.0","id":"req-7","method":"session/request_permission","params":{"sessionId":"ses_1"}}"#
        guard case .request(let id, let method, let params) = h.peer.handle(Data(line.utf8)) else {
            Issue.record("not a request")
            return
        }
        #expect(id == "req-7" && method == "session/request_permission")
        #expect(params?["sessionId"] == "ses_1")
        try await h.peer.respond(id: id, result: ["outcome": "selected"])
        let f = try await h.frame(0)
        #expect(f["id"] == "req-7")
        #expect(f["result"]?["outcome"] == "selected")
    }

    @Test func numberIDRoundTripsAsInteger() async throws {
        let h = Harness()
        guard case .request(let id, _, _) = h.peer.handle(Data(#"{"id":4,"method":"x"}"#.utf8)) else {
            Issue.record("not a request")
            return
        }
        try await h.peer.respond(id: id, result: .null)
        #expect(h.raw(0).contains("\"id\":4,"))
    }

    @Test func timeoutRemovesWaiterAndDropsLateReply() async throws {
        let h = Harness()
        do {
            try await h.peer.request("turn/start", timeout: .milliseconds(20))
            Issue.record("expected a timeout")
        } catch let e as AgentBinderError {
            #expect(e.code == "timeout")
        }
        #expect(h.peer.pending == 0)
        guard case .response(let r) = h.reply(.int(1), "{}") else {
            Issue.record("not a response")
            return
        }
        #expect(!r.delivered)
    }

    @Test func cancelRemovesWaiter() async throws {
        let h = Harness()
        let call = Task { try await h.peer.request("initialize") }
        _ = try await h.frame(0)
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(h.peer.pending == 0)
    }

    @Test func cancelBeforeStart() async throws {
        let h = Harness()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await h.peer.request("initialize")
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(h.peer.pending == 0)
    }

    @Test func sendErrorRemovesWaiterAndMarksDead() async throws {
        let h = Harness(fail: Boom())
        await #expect(throws: Boom.self) { try await h.peer.request("session/new") }
        #expect(h.peer.pending == 0)
        #expect(h.peer.dead is Boom)
    }

    @Test func unknownResponseIDIsIgnored() async throws {
        let h = Harness()
        guard case .response(let r) = h.peer.handle(Data(#"{"jsonrpc":"2.0","id":999,"result":{"stale":true}}"#.utf8))
        else {
            Issue.record("not a response")
            return
        }
        #expect(r.id == .int(999) && !r.delivered)
        let call = Task { try await h.peer.request("session/new") }
        let f = try await h.frame(0)
        _ = h.reply(f["id"]!, "{\"ok\":true}")
        #expect(try await call.value == ["ok": true])
    }

    @Test func failAllReleasesEveryWaiter() async throws {
        let h = Harness()
        let calls = (0..<2).map { _ in Task { try await h.peer.request("session/prompt") } }
        _ = try await h.frame(1)
        h.peer.failAll(Boom())
        for c in calls { await #expect(throws: Boom.self) { try await c.value } }
        #expect(h.peer.pending == 0)
        #expect(h.peer.dead is Boom)
        // The first error stays.
        h.peer.failAll(AgentBinderError.sessionClosed)
        #expect(h.peer.dead is Boom)
        await #expect(throws: Boom.self) { try await h.peer.notify("session/cancel") }
    }

    @Test func respondErrorKeepsStringID() async throws {
        let h = Harness()
        try await h.peer.respondError(id: "acp-3", code: JSONRPCError.methodNotFound, message: "method not found")
        let f = try await h.frame(0)
        #expect(f["id"] == "acp-3")
        #expect(f["error"] == ["code": -32601, "message": "method not found"])
    }

    @Test func classification() {
        let h = Harness()
        #expect(
            h.peer.handle(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#.utf8))
                == .notification(method: "session/update", params: [:]))
        #expect(
            h.peer.handle(Data(#"{"id":4,"method":"session/request_permission"}"#.utf8))
                == .request(id: 4, method: "session/request_permission", params: nil))
        #expect(
            h.peer.handle(Data(#"{"id":"p1","method":"fs/read_text_file","params":{}}"#.utf8))
                == .request(id: "p1", method: "fs/read_text_file", params: [:]))
        #expect(h.peer.handle(Data("not json at all".utf8)) == .invalid(Data("not json at all".utf8)))
        #expect(h.peer.handle(Data()) == .invalid(Data()))
        #expect(h.peer.handle(Data("{}".utf8)) == .invalid(Data("{}".utf8)))
    }

    @Test func responseIsDeliveredOnce() async throws {
        let h = Harness()
        let call = Task { try await h.peer.request("initialize") }
        let id = try await h.frame(0)["id"]!
        guard case .response(let r) = h.reply(id, "{\"ok\":true}") else { return }
        #expect(r.delivered && r.result == ["ok": true])
        #expect(try await call.value == ["ok": true])
        guard case .response(let again) = h.reply(id, "{\"ok\":true}") else { return }
        #expect(!again.delivered)
        let next = Task { try await h.peer.request("session/new") }
        _ = h.reply(try await h.frame(1)["id"]!, "{}")
        #expect(try await next.value == [:])
    }

    @Test func errorReplyThrowsRPCError() async throws {
        let h = Harness()
        let call = Task { try await h.peer.request("session/prompt") }
        let id = try await h.frame(0)["id"]!
        _ = h.peer.handle(
            Data(
                #"{"id":\#(id.jsonString),"error":{"code":-32000,"message":"usage limit reached","data":{"x":1}}}"#.utf8
            ))
        do {
            _ = try await call.value
            Issue.record("expected an error")
        } catch let e as JSONRPCError {
            #expect(e == JSONRPCError(code: -32000, message: "usage limit reached", data: ["x": 1]))
            #expect(e.description == #"jsonrpc error -32000: usage limit reached ({"x":1})"#)
        }
    }

    @Test func decodesResult() async throws {
        struct Out: Decodable {
            var sessionId: String
            var modes: [String]
        }
        let h = Harness()
        let call = Task { try await h.peer.request("session/new", as: Out.self) }
        _ = h.reply(try await h.frame(0)["id"]!, #"{"sessionId":"ses_9","modes":["ask","auto"]}"#)
        let out = try await call.value
        #expect(out.sessionId == "ses_9" && out.modes == ["ask", "auto"])
    }

    @Test func hundredConcurrentRequests() async throws {
        let h = Harness()
        try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
            for i in 0..<100 {
                group.addTask { (i, try await h.peer.request("echo", params: .int(Int64(i)))) }
            }
            try await eventually { h.written.value.count == 100 }
            // Reply in reverse order, with the params as the result.
            for d in h.written.value.reversed() {
                let f = JSONValue.parse(d)!
                _ = h.reply(f["id"]!, f["params"]!.jsonString)
            }
            var n = 0
            for try await (i, v) in group {
                #expect(v == .int(Int64(i)))
                n += 1
            }
            #expect(n == 100)
        }
        #expect(h.peer.pending == 0)
    }

    @Test func idPrefixAndSharedCounter() async throws {
        let w = FrameWriter(harness: .fake, log: nil, onSessionID: { _ in }) { _ in }
        let p = JSONRPCPeer(writer: w, idPrefix: "ab-")
        #expect(p.nextID() == "ab-1")
        #expect(try await p.send("x") == "ab-2")
        #expect(p.pending == 0)
    }

    @Test func noWriterIsClosed() async throws {
        let p = JSONRPCPeer()
        await #expect(throws: AgentBinderError.sessionClosed) { try await p.notify("x") }
    }
}
