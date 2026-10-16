import Foundation

/// The provider credentials of a native session. The CLI drivers ignore them.
///
/// The library never reads the environment or the Keychain to fill them.
public struct Credentials: Sendable, Equatable {
    /// The provider wire.
    public var format: Format
    /// A different provider endpoint. Nil uses the provider default.
    public var baseURL: URL?
    /// The bearer credential.
    public var apiKey: String
    /// Extra HTTP headers for each provider call.
    public var headers: [String: String]

    /// Makes credentials.
    public init(format: Format, apiKey: String, baseURL: URL? = nil, headers: [String: String] = [:]) {
        self.format = format
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.headers = headers
    }

    /// The provider wire formats.
    public enum Format: String, Sendable, Codable {
        /// The Anthropic Messages API.
        case anthropic
        /// The OpenAI Chat Completions API and compatible gateways.
        case openai
    }
}
