import Foundation
import Testing

@testable import AgentBinder
@testable import AgentBinderNative

@Suite("NativeDriverTests")
struct NativeDriverTests {
    struct Closing: ToolSet {
        let log: Locked<[String]>
        var name = "c"
        var fail = false
        func tools() async throws -> [any Tool] {
            if fail { throw NativeError("x", "list broke") }
            return [EchoTool()]
        }
        func close() async { log.withLock { $0.append("closed") } }
    }

    @Test func detect() async throws {
        let m = ScriptedModel([])
        let none = await runtime(config(m)).detect(.native)
        #expect(none.supported && none.ready && none.auth == .ok && none.features == .builtIn(.native))
        #expect(!none.features.fileSystem)
        let empty = await runtime(config(m) { $0.credentials = { Credentials(format: .anthropic, apiKey: "") } })
            .detect(.native)
        #expect(!empty.ready && empty.auth == .missing && empty.authDetail == "no API key")
        let failing = await runtime(config(m) { $0.credentials = { throw NativeError("kc", "keychain locked") } })
            .detect(.native)
        #expect(failing.auth == .missing && failing.authDetail?.contains("keychain locked") == true)
    }

    @Test func noDriverWithoutSetup() async throws {
        let rt = await runtime(config(ScriptedModel([])))
        await rt.setDriver(nil, for: .native)
        await #expect(throws: AgentBinderError.noDriver(.native)) { _ = try await rt.start(request()) }
        await rt.close()
    }

    @Test func credentials() async throws {
        let seen = Locked<[String]>([])
        let m = ScriptedModel([])
        var c = NativeConfig(newModel: { cr, model in
            seen.withLock { $0.append("\(cr.apiKey)/\(model ?? "-")") }
            return m
        })
        let rt = await runtime(c)
        var r = request()
        r.credentials = nil
        await #expect(throws: NativeError.config("native session needs credentials")) { _ = try await rt.start(r) }
        c.credentials = { Credentials(format: .openai, apiKey: "from-config") }
        await rt.setDriver(NativeDriver(c), for: .native)
        r.model = "m1"
        _ = try await rt.start(r)
        _ = try await rt.start(request())
        #expect(seen.value == ["from-config/m1", "k/-"])
        c.newModel = { _, _ in throw NativeError("bad_model", "no such model") }
        await rt.setDriver(NativeDriver(c), for: .native)
        await #expect(throws: NativeError("bad_model", "no such model")) { _ = try await rt.start(request()) }
        await rt.close()
    }

    @Test func ownedSetsCloseWithTheSession() async throws {
        let log = Locked<[String]>([])
        let shared = Closing(log: Locked([]))
        let m = ScriptedModel([])
        let d = NativeDriver(
            config(m) {
                $0.toolSets = [shared]
                $0.toolSetFactories = [{ Closing(log: log, name: "own") }]
            })
        let rt = Runtime(options: .init(useLoginShellPath: false))
        await rt.setDriver(d, for: .native)
        let s = try await rt.start(request())
        #expect(log.value.isEmpty)
        await s.close()
        #expect(log.value == ["closed"] && shared.log.value.isEmpty)
        _ = try await rt.start(request(id: "s2"))
        await d.close()
        #expect(log.value == ["closed", "closed"])
        await #expect(throws: NativeError.config("native driver is closed")) { _ = try await rt.start(request()) }
        await rt.close()
    }

    @Test func openFailuresCloseOwnedSets() async throws {
        let log = Locked<[String]>([])
        let m = ScriptedModel([])
        let rt = await runtime(
            config(m) {
                $0.toolSetFactories = [{ Closing(log: log) }, { Closing(log: log, name: "bad", fail: true) }]
            })
        await #expect(throws: NativeError.config("native: toolset bad: list broke")) {
            _ = try await rt.start(request())
        }
        #expect(log.value == ["closed", "closed"])

        let rt2 = await runtime(
            config(m) {
                $0.toolSetFactories = [{ Closing(log: log) }, { throw NativeError("f", "factory broke") }]
            })
        await #expect(throws: NativeError("f", "factory broke")) { _ = try await rt2.start(request()) }
        #expect(log.value.count == 3)

        let rt3 = await runtime(config(m) { $0.toolSetFactories = [{ Closing(log: log) }] })
        var r = request()
        r.skills = [Skill(directory: URL(fileURLWithPath: "/no/such/skill"))]
        await #expect(throws: NativeError.self) { _ = try await rt3.start(r) }
        #expect(log.value.count == 4)
        await rt.close()
        await rt2.close()
        await rt3.close()
    }

    @Test func builtinsHideHostKeys() async throws {
        let dir = try Scratch()
        let m = ScriptedModel([
            .parts(
                StreamPart.calls(
                    .call("1", "bash", #"{"command":"echo [$ANTHROPIC_API_KEY][$OPENAI_API_KEY][$MINE]"}"#))),
            .parts(StreamPart.text("ok")),
        ])
        let rt = Runtime(
            options: .init(
                useLoginShellPath: false,
                environment: ["ANTHROPIC_API_KEY": "host", "OPENAI_API_KEY": "host", "PATH": "/usr/bin:/bin"]))
        await rt.setDriver(NativeDriver(config(m) { $0.builtinTools = true }), for: .native)
        var r = request(dir.url)
        r.environment = ["MINE": "x", "OPENAI_API_KEY": "mine"]
        r.permissions = PermissionPolicy(allowTools: ["bash"])
        let s = try await rt.start(r)
        let sink = Sink(s)
        try await s.prompt(Prompt("go"))
        try await sink.waitResults(1)
        #expect(sink.tools.last?.output == "[][mine][x]\n")
        #expect(m.requests.value[0].tools.map(\.name) == ["bash", "read", "write", "edit", "glob", "grep"])
        await rt.close()
    }

    @Test func toolTableKeepsOrder() {
        var t = ToolTable()
        t.add(EchoTool(name: "a"))
        t.add(EchoTool(name: "b"))
        t.add(EchoTool(name: "a", readOnly: false))
        #expect(t.specs.map(\.name) == ["a", "b"] && t["a"]?.spec.annotations.readOnly == false && t["c"] == nil)
    }
}
