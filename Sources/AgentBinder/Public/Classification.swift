import Foundation

/// The failure family of an error text. A consumer maps the family and the code to its own words.
public enum FailureClass: String, Sendable, Codable {
    /// No failure family. A harness failure such as `error_max_turns` has this class.
    case none = ""
    /// The login is missing or bad.
    case auth
    /// A plan limit, a rate limit or the credits stopped the work.
    case limit
    /// The plan does not include the request.
    case entitlement
    /// The vendor is overloaded.
    case overloaded
    /// The CLI is too old, or the wire changed.
    case `protocol`
    /// No rule matched.
    case unknown
}

/// A failure family and a stable machine code.
public struct Classification: Sendable, Equatable {
    /// The failure family.
    public var cls: FailureClass
    /// The machine code, for example `"rate_limited"`, or `"claude.rate_limited"` with a harness.
    public var code: String
    /// The text that the classifier read, trimmed.
    public var message: String

    /// Makes a classification.
    public init(cls: FailureClass, code: String, message: String = "") {
        self.cls = cls
        self.code = code
        self.message = message
    }

    /// The end reason of the family.
    public var endReason: EndReason {
        switch cls {
        case .auth: return .auth
        case .entitlement: return .entitlement
        case .limit: return .limit
        case .overloaded: return .overloaded
        case .protocol: return .protocol
        case .none, .unknown: return .failed
        }
    }
}

/// Classifies error texts into failure families.
///
/// Give it error-shaped text only: a result error field, a stderr tail or an HTTP status field.
/// Assistant prose and tool output give false positives, because vendors use ordinary words
/// such as "capacity" and "credentials".
public enum Classifier {
    private struct Rule {
        var cls: FailureClass
        var code: String
        var phrases: [String]
    }

    // Most specific first. Each phrase matches on word boundaries, so "429" never matches "14290".
    private static let rules: [Rule] = [
        Rule(
            cls: .limit, code: "credits_exhausted",
            phrases: [
                "out of credits", "credit balance", "credit exhausted", "no credits", "insufficient credits",
                "agent credit",
            ]),
        Rule(
            cls: .limit, code: "rate_limited",
            phrases: [
                "rate limit", "rate_limit", "429", "too many requests", "usage limit", "session limit",
                "weekly limit", "5-hour limit", "quota exceeded", "quota reached", "limit reached",
                "limit exceeded", "over usage", "usage cap",
            ]),
        Rule(
            cls: .entitlement, code: "plan_refused",
            phrases: [
                "entitlement", "not entitled", "upgrade required", "subscription required",
                "no active subscription", "plan does not include", "access denied for your plan",
            ]),
        Rule(
            cls: .auth, code: "invalid_credentials",
            phrases: [
                "invalid api key", "invalid_api_key", "authentication_error", "authentication failed",
                "unauthorized", "401",
            ]),
        Rule(cls: .auth, code: "token_revoked", phrases: ["token has been revoked", "token revoked"]),
        Rule(
            cls: .auth, code: "not_logged_in",
            phrases: [
                "not logged in", "please run /login", "please login", "login required", "credentials",
                "oauth token",
            ]),
        Rule(cls: .auth, code: "token_refresh_failed", phrases: ["oauth refresh failed", "invalid_grant"]),
        Rule(cls: .overloaded, code: "capacity", phrases: ["overloaded", "529", "503", "server error", "capacity"]),
        Rule(
            cls: .protocol, code: "cli_too_old",
            phrases: ["unrecognized subcommand", "unknown subcommand", "invalid subcommand"]),
        Rule(
            cls: .protocol, code: "wire_drift",
            phrases: ["protocol", "json-rpc", "parse error", "unexpected message", "invalid frame"]),
    ]

    // A bare status number counts only after one of these words.
    private static let statusCues: Set<String> = [
        "http", "https", "status", "code", "api", "error", "err", "response",
    ]

    /// Classifies an error text. `status` is an HTTP status from the wire, when one is known.
    public static func classify(_ text: String, status: Int? = nil, harness: Harness? = nil) -> Classification {
        let low = Array(text.lowercased().utf8)
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for r in rules {
            for p in r.phrases where containsWord(low, Array(p.utf8)) {
                return Classification(cls: r.cls, code: code(harness, r.code), message: message)
            }
        }
        if let status, let cls = classForStatus(status) {
            return Classification(cls: cls, code: code(harness, "http_\(status)"), message: message)
        }
        return Classification(cls: .unknown, code: code(harness, "unknown"), message: message)
    }

    /// Classifies an error result. A harness failure subtype such as `error_max_turns` has the class
    /// ``FailureClass/none``.
    public static func classify(_ r: TurnResult, harness: Harness? = nil) -> Classification {
        var text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = r.subtype }
        var c = classify(text, harness: harness)
        if c.cls == .unknown && !r.subtype.isEmpty && r.subtype != "success" {
            c = Classification(cls: .none, code: code(harness, r.subtype), message: text)
        }
        if c.message.isEmpty { c.message = text }
        return c
    }

    private static func classForStatus(_ status: Int) -> FailureClass? {
        switch status {
        case 401, 403: return .auth
        case 402, 429: return .limit
        case 502, 503, 504, 529: return .overloaded
        default: return nil
        }
    }

    private static func code(_ h: Harness?, _ reason: String) -> String {
        guard let h else { return reason }
        return h.rawValue + "." + reason
    }

    // Underscores are delimiters, so a vendor token such as "error_max_turns" still yields its words.
    private static func containsWord(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let numeric = needle.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        var start = 0
        while start + needle.count <= hay.count {
            if hay[start..<(start + needle.count)].elementsEqual(needle) {
                let end = start + needle.count
                let before = start == 0 || !isWord(hay[start - 1])
                let after = end >= hay.count || !isWord(hay[end])
                if before && after && (!numeric || isStatusNumber(hay, start, end)) { return true }
            }
            start += 1
        }
        return false
    }

    // The number is the only token in the text, or a cue word stands in front of it.
    private static func isStatusNumber(_ s: [UInt8], _ start: Int, _ end: Int) -> Bool {
        if !s[..<start].contains(where: isWord) && !s[end...].contains(where: isWord) { return true }
        var i = start
        while i > 0 && !isWord(s[i - 1]) { i -= 1 }
        var j = i
        while j > 0 && isWord(s[j - 1]) { j -= 1 }
        guard j < i else { return false }
        return statusCues.contains(String(decoding: s[j..<i], as: UTF8.self))
    }

    private static func isWord(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
    }
}
