import Foundation

/// One model that a harness offers.
public struct ModelInfo: Sendable, Codable, Hashable {
    /// The value that ``StartRequest/model`` and ``ModelSettable/setModel(_:)`` take.
    public var id: String
    /// The display name. Nil means use ``id``.
    public var name: String?
    /// A short vendor note, for example the context size.
    public var description: String?
    /// True for the model that the harness uses when no model is set.
    public var isDefault: Bool

    /// Makes a model record.
    public init(id: String, name: String? = nil, description: String? = nil, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case isDefault = "default"
    }

    /// Decodes a model record. Missing fields take their defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    /// Encodes a model record. Empty fields are left out.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        if isDefault { try c.encode(true, forKey: .isDefault) }
    }
}

/// The install and config home that a model list or a limits read is for.
public struct ModelQuery: Sendable {
    /// The executable. Nil lets the binary resolver search for it.
    public var binary: URL?
    /// The config home, as in ``StartRequest/home``.
    public var home: URL?
    /// The environment, as in ``StartRequest/environment``.
    public var environment: [String: String]
    /// The working directory. Some vendors read project config.
    public var workingDirectory: URL?

    /// Makes a query.
    public init(
        binary: URL? = nil, home: URL? = nil, environment: [String: String] = [:], workingDirectory: URL? = nil
    ) {
        self.binary = binary
        self.home = home
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}
