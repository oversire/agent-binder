# ``AgentBinder``

Drive the coding-agent CLIs on a Mac over their structured protocols, with one event model.

## Overview

A ``Runtime`` starts a ``Session`` for one ``Harness``. The session gives an `AsyncStream` of ``Event`` values.
Each CLI uses its own login. The library never reads a vendor token.

## Topics

### Essentials

- ``Runtime``
- ``StartRequest``
- ``Session``
- ``Event``

### Prompts and permissions

- ``Prompt``
- ``PromptAttachment``
- ``PermissionPolicy``
- ``Decision``

### Session setup

- ``MCPServer``
- ``Skill``
- ``Credentials``

### Discovery

- ``Detection``
- ``Features``
- ``ModelInfo``
- ``Limits``

### Transcripts

- ``TranscriptReader``
- ``TranscriptDigest``
- ``TranscriptBudget``
- ``TranscriptError``

### Errors

- ``AgentBinderError``
