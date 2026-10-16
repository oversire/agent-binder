import AgentBinder
import Foundation

/// The hints of a tool. The loop asks for approval unless the tool is read-only and not an
/// `ToolKind.exec` or `ToolKind.mcp` tool.
public struct ToolAnnotations: Sendable, Equatable {
    /// The tool changes nothing.
    public var readOnly: Bool
    /// The tool can destroy data.
    public var destructive: Bool
    /// A second call with the same input changes nothing more.
    public var idempotent: Bool
    /// The tool reaches outside the workspace.
    public var openWorld: Bool
    /// The coarse class of the tool.
    public var kind: ToolKind

    /// Makes annotations.
    public init(
        readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false, openWorld: Bool = false,
        kind: ToolKind = .other
    ) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
        self.kind = kind
    }
}

/// The description of a tool that the model gets.
public struct ToolSpec: Sendable, Equatable {
    /// The name. Providers take `^[a-zA-Z0-9_-]{1,64}$`.
    public var name: String
    /// A short title.
    public var title: String
    /// What the tool does.
    public var description: String
    /// The JSON schema of the input, as raw JSON. Nil means an object with no properties.
    public var inputSchema: Data?
    /// The hints.
    public var annotations: ToolAnnotations

    /// Makes a spec.
    public init(
        name: String, title: String = "", description: String = "", inputSchema: Data? = nil,
        annotations: ToolAnnotations = ToolAnnotations()
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    /// True when a call needs a decision of the approver.
    var needsApproval: Bool {
        annotations.kind == .mcp || annotations.kind == .exec || !annotations.readOnly
    }

    /// A schema for an object with string properties.
    static func strings(_ names: [String], required: [String]) -> Data {
        let props = names.map { "\(JSONValue.quote($0)):{\"type\":\"string\"}" }.joined(separator: ",")
        let req = required.map(JSONValue.quote).joined(separator: ",")
        return Data(#"{"type":"object","properties":{\#(props)},"required":[\#(req)]}"#.utf8)
    }
}

/// A tool that the model can call.
public protocol Tool: Sendable {
    /// The description of the tool.
    var spec: ToolSpec { get }
    /// Runs the tool. A tool failure is a result with ``ToolResult/isError``. A throw means that the
    /// tool could not run at all.
    func call(_ input: Data?) async throws -> ToolResult
}

/// A group of tools with one owner.
public protocol ToolSet: Sendable {
    /// The name, for errors.
    var name: String { get }
    /// The tools. The loop calls it once when a session opens.
    func tools() async throws -> [any Tool]
    /// Releases the resources of the set.
    func close() async
}

/// A tool set with a fixed list of tools.
public struct StaticToolSet: ToolSet {
    /// The name, for errors.
    public let name: String
    private let list: [any Tool]

    /// Makes a set.
    public init(_ name: String, _ tools: [any Tool]) {
        self.name = name
        list = tools
    }

    /// The tools.
    public func tools() async throws -> [any Tool] { list }

    /// Does nothing.
    public func close() async {}
}

/// A tool from a typed function.
///
/// An empty input decodes as `{}`. A decode failure and a throw of the function give an error result.
/// A `String` output is the text of the result. Any other output is its JSON text.
public struct FuncTool<In: Decodable & Sendable, Out: Encodable & Sendable>: Tool {
    /// The description of the tool.
    public let spec: ToolSpec
    private let fn: @Sendable (In) async throws -> Out

    /// Makes a tool. The spec must carry the input schema.
    public init(_ spec: ToolSpec, _ fn: @escaping @Sendable (In) async throws -> Out) {
        self.spec = spec
        self.fn = fn
    }

    /// Decodes the input, runs the function and encodes the output.
    public func call(_ input: Data?) async throws -> ToolResult {
        let raw = input.flatMap { $0.isEmpty ? nil : $0 } ?? Data("{}".utf8)
        let value: In
        do {
            value = try JSONDecoder().decode(In.self, from: raw)
        } catch {
            return .text("invalid input: \(error)", isError: true)
        }
        let out: Out
        do {
            out = try await fn(value)
        } catch {
            return .text(String(describing: error), isError: true)
        }
        // Changed on purpose: a string output is the text itself, not a JSON string.
        if let s = out as? String { return .text(s) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .text(String(decoding: try enc.encode(out), as: UTF8.self))
    }
}
