/// The errors of the library. Each case has a stable machine ``code``. The library ships no UI text.
public enum AgentBinderError: Error, Sendable, Equatable {
    /// The runtime has no driver for the harness.
    case noDriver(Harness)
    /// The binary resolver did not find the executable. `searched` lists the folders.
    case binaryNotFound(Harness, searched: [String])
    /// The host app runs in the App Sandbox, so it cannot run vendor CLIs.
    case sandboxed
    /// The installed version is below the floor of the library.
    case belowVersionFloor(Harness, version: String, floor: String)
    /// The protocol handshake failed.
    case handshakeFailed(String)
    /// The protocol handshake did not complete in time.
    case handshakeTimeout
    /// The vendor cannot resume the session.
    case resumeUnsupported
    /// The harness does not have the capability.
    case unsupported(String)
    /// A turn runs, and the harness cannot take a second prompt now.
    case turnActive
    /// No turn runs.
    case noActiveTurn
    /// The session is closed.
    case sessionClosed
    /// A frame is larger than the frame limit.
    case frameTooLarge
    /// The request is not valid.
    case invalidRequest(String)
    /// The feature needs an isolated home (``StartRequest/home``) for this harness.
    case homeRequired(feature: String)
    /// The child process did not start.
    case launch(String)
    /// A request to the vendor did not get a reply in time.
    case timeout(String)
    /// The vendor replied with an error.
    case vendor(code: Int, message: String)

    /// The stable machine code of the error.
    public var code: String {
        switch self {
        case .noDriver: return "no_driver"
        case .binaryNotFound: return "binary_not_found"
        case .sandboxed: return "sandboxed"
        case .belowVersionFloor: return "below_version_floor"
        case .handshakeFailed: return "handshake_failed"
        case .handshakeTimeout: return "handshake_timeout"
        case .resumeUnsupported: return "resume_unsupported"
        case .unsupported: return "unsupported"
        case .turnActive: return "turn_active"
        case .noActiveTurn: return "no_active_turn"
        case .sessionClosed: return "session_closed"
        case .frameTooLarge: return "frame_too_large"
        case .invalidRequest: return "invalid_request"
        case .homeRequired: return "home_required"
        case .launch: return "launch"
        case .timeout: return "timeout"
        case .vendor: return "vendor_error"
        }
    }
}

extension AgentBinderError: CustomStringConvertible {
    /// A log line for the error. It is not UI text.
    public var description: String {
        switch self {
        case .noDriver(let h): return "agentbinder: no driver for harness \(h)"
        case .binaryNotFound(let h, let searched):
            return "agentbinder: \(h.binaryName) not found (searched \(searched.joined(separator: ":")))"
        case .sandboxed: return "agentbinder: the host app runs in the App Sandbox"
        case .belowVersionFloor(let h, let v, let floor):
            return "agentbinder: \(h) \(v) is below the supported floor \(floor)"
        case .handshakeFailed(let m): return "agentbinder: handshake failed: \(m)"
        case .handshakeTimeout: return "agentbinder: handshake timeout"
        case .resumeUnsupported: return "agentbinder: session resume not supported"
        case .unsupported(let m): return "agentbinder: unsupported: \(m)"
        case .turnActive: return "agentbinder: a turn is active"
        case .noActiveTurn: return "agentbinder: no active turn"
        case .sessionClosed: return "agentbinder: session closed"
        case .frameTooLarge: return "agentbinder: frame too large"
        case .invalidRequest(let m): return "agentbinder: invalid request: \(m)"
        case .homeRequired(let f): return "agentbinder: \(f) needs StartRequest.home"
        case .launch(let m): return "agentbinder: launch: \(m)"
        case .timeout(let m): return "agentbinder: \(m): timeout"
        case .vendor(let c, let m): return "agentbinder: vendor error \(c): \(m)"
        }
    }
}
