import Foundation

@testable import AgentBinder
@testable import AgentBinderNative

/// A tool that echoes its `text` input.
struct EchoTool: Tool {
    struct In: Decodable, Sendable { var text: String }
    var name = "echo"
    var readOnly = true
    var kind = ToolKind.other

    var spec: ToolSpec {
        ToolSpec(
            name: name, inputSchema: ToolSpec.strings(["text"], required: ["text"]),
            annotations: ToolAnnotations(readOnly: readOnly, kind: kind))
    }

    func call(_ input: Data?) async throws -> ToolResult {
        try await FuncTool(spec) { (i: In) in "echo: \(i.text)" }.call(input)
    }
}
