import Foundation

@testable import AgentBinder

/// Runs `/bin/sh -c script` with a ``LineAdapter``.
struct ShellDriver: Driver {
    var script = "read -r line || true"
    var name: String { "shell" }

    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        let launch = Launch(
            binary: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: r.environment,
            resume: false)
        return try await runtime.startWire(r, launch, adapter: LineAdapter())
    }

    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        throw AgentBinderError.resumeUnsupported
    }
}

/// A driver with no sessions. It counts its model and limits probes.
final class CountingDriver: ModelListing, LimitsReading, Sendable {
    let calls = Locked(0)
    let failure = Locked<AgentBinderError?>(nil)
    let gate = Latch()
    let models: [ModelInfo]

    init(open: Bool = true, models: [ModelInfo] = [ModelInfo(id: "m1", isDefault: true), ModelInfo(id: "m2")]) {
        self.models = models
        if open { gate.open() }
    }

    var name: String { "counting" }

    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        throw AgentBinderError.unsupported("counting driver")
    }

    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        throw AgentBinderError.resumeUnsupported
    }

    func models(_ q: ModelQuery, runtime: RuntimeContext) async throws -> [ModelInfo] {
        calls.withLock { $0 += 1 }
        await gate.wait()
        if let f = failure.value { throw f }
        return models
    }

    func readLimits(_ q: ModelQuery, runtime: RuntimeContext) async throws -> Limits {
        Limits(plan: "pro", windows: [LimitWindow(key: .fiveHour, minutes: 300, usedPercent: 12)])
    }
}

/// A driver with no capability. It stands in for a CLI driver in detect tests.
struct PlainDriver: Driver {
    var name: String { "plain" }

    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        throw AgentBinderError.unsupported("plain driver")
    }

    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        throw AgentBinderError.resumeUnsupported
    }
}

/// A driver that answers detect itself, as an in-process harness does.
struct InProcessDriver: SelfDetecting {
    var name: String { "in-process" }

    func start(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        throw AgentBinderError.unsupported("in-process driver")
    }

    func resume(_ r: StartRequest, runtime: RuntimeContext) async throws -> any Session {
        throw AgentBinderError.resumeUnsupported
    }

    func detect(runtime: RuntimeContext) async throws -> Detection {
        Detection(harness: .native, supported: true, auth: .ok)
    }
}

/// A clock that a test moves.
final class TestClock: Sendable {
    private let t = Locked(Date(timeIntervalSince1970: 1_800_000_000))

    var now: @Sendable () -> Date { { [t] in t.value } }

    func advance(_ seconds: TimeInterval) { t.withLock { $0.addTimeInterval(seconds) } }
}
