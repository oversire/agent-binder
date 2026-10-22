# ``AgentBinderMCP``

Connect MCP servers to the in-process model loop of `AgentBinderNative`.

## Overview

`AgentBinderNative` has no external dependencies. This product adds the MCP Swift SDK and swift-log.
Set ``MCPToolSet/factory`` on `NativeConfig.mcpFactory`. Then the native harness connects the servers of `StartRequest.mcpServers`.
Without it, a native session with MCP servers fails at open with the `mcp_unavailable` code.

## Topics

### Tool sets

- ``MCPToolSet``
