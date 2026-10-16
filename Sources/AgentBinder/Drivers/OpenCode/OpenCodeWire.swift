import Foundation

/// The HTTP surface of one `opencode serve` generation.
enum OpenCodeWire: String, Sendable {
    /// OpenCode 1.x: unprefixed routes, and an event bus for each directory.
    case v1
    /// OpenCode 2.x: `/api` routes, `{data: …}` envelopes, and one event bus for each server.
    case v2

    /// The harness that the sessions of this wire report.
    var harness: Harness { self == .v1 ? .opencode : .opencode2 }

    var prefix: String { self == .v1 ? "" : "/api" }

    // Quirk: 2.0.26 removed /api/health, so V2 reads /api/info.
    var healthPath: String { self == .v1 ? "/global/health" : "/api/info" }

    var eventPath: String { self == .v1 ? "/event" : "/api/event" }

    /// True when the server publishes the events of a session only to a stream of the same directory.
    var eventScoped: Bool { self == .v1 }

    /// True when a health body says that the server serves this wire.
    func ready(_ body: Data) -> Bool {
        guard let v = JSONValue.parse(body) else { return false }
        switch self {
        case .v1: return v["healthy"]?.bool == true
        case .v2: return !v["version"].stringValue.isEmpty
        }
    }

    /// The type, the payload and the session id of one bus frame. Nil drops the frame.
    func frame(_ raw: Data) -> (type: String, payload: JSONValue, sessionID: String)? {
        guard let v = JSONValue.parse(raw) else { return nil }
        let type = v["type"].stringValue
        guard !type.isEmpty else { return nil }
        switch self {
        case .v1:
            guard let p = v["properties"], p.object != nil else { return nil }
            let id = [
                p["sessionID"], p["sessionId"], p.at("info", "sessionID"), p.at("part", "sessionID"),
            ].lazy.compactMap { $0?.string }.first { !$0.isEmpty }
            guard let id else { return nil }
            return (type, p, id)
        case .v2:
            let p = v["data"].flatMap { $0.object != nil ? $0 : nil } ?? .object([:])
            // Shell events carry the id in their metadata.
            let id = [p["sessionID"], p.at("info", "metadata", "sessionID")].lazy.compactMap { $0?.string }
                .first { !$0.isEmpty }
            guard let id else { return nil }
            return (type, p, id)
        }
    }

    /// The payload of a REST reply. V2 wraps it in `{data: …}`.
    func decode(_ body: Data) -> JSONValue {
        let v = body.isEmpty ? JSONValue.null : JSONValue.parse(body) ?? .null
        guard self == .v2 else { return v }
        if let d = v["data"], d != .null { return d }
        return v
    }

    /// The text of an HTTP error reply.
    func errorText(_ body: Data, status: Int) -> String {
        let v = JSONValue.parse(body)
        let keys: [JSONValue?] =
            self == .v1
            ? [v?["error"], v?.at("data", "message")]
            : [v?["message"], v?["error"], v?["_tag"]]
        return keys.lazy.compactMap { $0?.string }.first { !$0.isEmpty } ?? "HTTP \(status)"
    }

    /// The wire of an `opencode --version` line: the first field that parses as a version decides.
    /// A major of 2 or more is V2. No version is V1.
    init(versionLine line: String?) {
        let fields = (line ?? "").split(whereSeparator: \.isWhitespace)
        let major = fields.lazy.compactMap { parseSemver(String($0))?.0 }.first
        self = (major ?? 1) >= 2 ? .v2 : .v1
    }
}
