import AgentBinder
import Foundation

/// A failure of a provider call: an HTTP status, an error event in the stream, or a bad stream.
public struct ProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The provider, `"anthropic"` or `"openai"`.
    public var provider: String
    /// The HTTP status. Nil for a failure inside the stream.
    public var status: Int?
    /// The request id of the provider, from `request-id` or `x-request-id`.
    public var requestID: String?
    /// The error type of the provider, for example `"rate_limit_error"`.
    public var type: String?
    /// The error text of the provider, or the response body.
    public var message: String
    /// The wait that the provider asked for, from `retry-after-ms` or `retry-after`.
    public var retryAfter: Duration?

    /// Makes an error.
    public init(
        provider: String, status: Int? = nil, requestID: String? = nil, type: String? = nil, message: String,
        retryAfter: Duration? = nil
    ) {
        self.provider = provider
        self.status = status
        self.requestID = requestID
        self.type = type
        self.message = message
        self.retryAfter = retryAfter
    }

    /// The failure family and the machine code.
    public var classification: Classification {
        Classifier.classify(
            [type, message].compactMap { $0 }.joined(separator: ": "), status: status, harness: .native)
    }

    /// The stable machine code, for example `"native.rate_limited"`.
    public var code: String { classification.code }

    /// The text for logs.
    public var description: String {
        var head: [String] = []
        if let status { head.append("http \(status)") }
        if let type, !type.isEmpty { head.append(type) }
        var s = provider + ": " + (head.isEmpty ? "" : head.joined(separator: " ") + ": ") + message
        if let requestID, !requestID.isEmpty { s += " (request \(requestID))" }
        return s
    }
}
