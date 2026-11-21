import Foundation

/// A scripted driver for tests. It runs a shell script that speaks a small NDJSON vocabulary, so a
/// consumer can test its event pump without a vendor binary.
///
/// The session writes one line to the stdin of the script for each call:
/// `{"type":"user","text":…}` for a prompt, `{"type":"steer","text":…}` for a steer during a turn,
/// `{"type":"set_model","model":…}` for a model change and `{"type":"decision","id":…,"allow":…}` for
/// an answer.
///
/// The script writes these lines to stdout: `init`, `assistant`, `thought`, `user`, `tool`, `permission`,
/// `usage`, `status`, `result` and `error`.
public struct FakeDriver: Driver, ModelListing {
    /// The environment key of the script, when ``script`` is nil.
    public static let scriptEnvironmentKey = "AGENTBINDER_FAKE_SCRIPT"
    /// The environment key of the model list, as a JSON array of ``ModelInfo``, when ``modelList`` is empty.
    public static let modelsEnvironmentKey = "AGENTBINDER_FAKE_MODELS"
    /// The script when no other script is set. It reads one prompt and answers it. It echoes the next
    /// stdin line, for example a steer, as a `user` event. Then it ends the turn.
    public static let defaultScript = #"""
        read -r line || true
        echo '{"type":"assistant","text":"working"}'
        if read -r next; then
          printf '{"type":"user","text":"got: %s"}\n' "$(printf '%s' "$next" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        fi
        echo '{"type":"result","subtype":"success","text":"done"}'
        """#

    /// The shell script. Nil reads ``scriptEnvironmentKey``, then uses ``defaultScript``.
    public var script: String?
    /// A different working directory. Nil uses ``StartRequest/workingDirectory``.
    public var workingDirectory: URL?
    /// The list that ``Runtime/models(_:query:)`` returns. Empty reads ``modelsEnvironmentKey``.
    public var modelList: [ModelInfo]
    /// False makes each steer fail with ``AgentBinderError/unsupported(_:)``, so
    /// ``Session/send(_:)`` holds a prompt during a turn and sends it after the result.
    public var steers: Bool

    /// Makes a fake driver.
    public init(script: String? = nil, workingDirectory: URL? = nil, modelList: [ModelInfo] = [], steers: Bool = true) {
        self.script = script
        self.workingDirectory = workingDirectory
        self.modelList = modelList
        self.steers = steers
    }

    /// The name of the driver.
    public var name: String { Harness.fake.rawValue }

    /// Starts the script.
    public func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        let text = script ?? r.environment[Self.scriptEnvironmentKey] ?? runtime.environment[Self.scriptEnvironmentKey]
        let launch = Launch(
            binary: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", text ?? Self.defaultScript],
            environment: r.environment, resume: r.sessionID != nil)
        let adapter = FakeAdapter(steers: steers)
        let wire = try await runtime.startWire(r, launch, adapter: adapter, directory: workingDirectory)
        if let id = r.sessionID { wire.setID(id) }
        if let one = r.oneShot {
            try await wire.runOneShot(one.prompt, closeInput: true)
        }
        return FakeSession(wire: wire, adapter: adapter)
    }

    /// Starts the script. The fake harness keeps no state, so a resume is a start with the id set.
    public func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        try await start(r, runtime: runtime)
    }

    /// Returns ``modelList``, else the list in ``modelsEnvironmentKey``.
    public func models(_ q: ModelQuery, runtime: RuntimeContext) async throws -> [ModelInfo] {
        if !modelList.isEmpty { return modelList }
        guard let raw = q.environment[Self.modelsEnvironmentKey] ?? runtime.environment[Self.modelsEnvironmentKey],
            !raw.isEmpty
        else { return [] }
        do {
            return try JSONDecoder().decode([ModelInfo].self, from: Data(raw.utf8))
        } catch {
            throw AgentBinderError.invalidRequest("\(Self.modelsEnvironmentKey): \(error)")
        }
    }
}

/// The session of the fake harness. It has every optional capability.
final class FakeSession: WireBacked, ModelSettable, Steerable, SessionModelListing {
    let wire: WireSession
    private let adapter: FakeAdapter

    init(wire: WireSession, adapter: FakeAdapter) {
        self.wire = wire
        self.adapter = adapter
    }

    var offeredModels: [ModelInfo] { adapter.offeredModels }

    func setModel(_ id: String) async throws {
        try await wire.writer.write(JSONValue.object(["type": "set_model", "model": .string(id)]))
    }
}
