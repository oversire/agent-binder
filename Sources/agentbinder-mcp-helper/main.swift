import Foundation

// A stdio MCP server for the live tests. Its one tool "marker" returns the first argument.
let phrase = CommandLine.arguments.dropFirst().first ?? "agentbinder-marker"

func send(_ v: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: v) else { return }
    FileHandle.standardOutput.write(d + Data([0x0A]))
}

func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

while let line = readLine() {
    guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        let method = m["method"] as? String, let id = m["id"]
    else { continue }
    switch method {
    case "initialize":
        let version = (m["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
        reply(
            id,
            [
                "protocolVersion": version, "capabilities": ["tools": [:]],
                "serverInfo": ["name": "agentbinder-mcp-helper", "version": "1.0.0"],
            ])
    case "tools/list":
        reply(
            id,
            [
                "tools": [
                    [
                        "name": "marker", "description": "Returns the marker phrase of this server.",
                        "inputSchema": ["type": "object", "properties": [:]],
                        "annotations": ["readOnlyHint": true],
                    ]
                ]
            ])
    case "tools/call":
        reply(id, ["content": [["type": "text", "text": phrase]]])
    case "ping":
        reply(id, [:])
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]])
    }
}
