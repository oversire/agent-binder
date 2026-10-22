# ``AgentBinderNative``

Run a model loop in process, for an app with no agent CLI installed.

## Overview

`AgentBinderNative` gives a driver for the `native` harness. Register it on a runtime with `setDriver(_:for:)`.
It calls the provider API with the `Credentials` of the request.
The product has no external dependencies. For the servers of `StartRequest.mcpServers`, link `AgentBinderMCP` and set ``NativeConfig/mcpFactory``.
