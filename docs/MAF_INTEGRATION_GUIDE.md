# Microsoft Agent Framework (MAF) Integration Guide for Aether

This document provides the authoritative engineering specification and operational reference for the official **Microsoft Agent Framework (MAF)** integration into **Aether**.

---

## 1. System Architecture Overview

Aether pairs native Apple Silicon execution with the official Microsoft Agent Framework (`agent-framework-core==1.24.0`). Swift retains application authority, security gating, local Metal inference, and SQLite conversation persistence, while the sandboxed Python sidecar orchestrates multi-agent topologies and execution states.

```
+---------------------------------------------------------------------------------+
|                               AETHER APPLICATION                                |
|    +--------------------+    +--------------------+    +-------------------+    |
|    |    SwiftUI Chat    |    |  InferenceService  |    | ToolSecurityGuard |    |
|    |   ChatViewModel    |    |  llama.xcframework |    | SQLite (App Supp) |    |
|    +---------+----------+    +---------+----------+    +---------+---------+    |
+--------------|-------------------------|-------------------------|--------------+
               |                         |                         |
               | (1) Dispatch Task       | (4) Metal Inference     | (6) Gated Tool Exec
               v                         v                         v
+---------------------------------------------------------------------------------+
|                       SWIFT MULTI-AGENT INTEGRATION LAYER                       |
|    +-------------------------+                     +-----------------------+    |
|    |  MultiAgentSupervisor   |<------------------->| MultiAgentSidecarMgr  |    |
|    +-------------------------+                     +-----------+-----------+    |
|    |  MultiAgentToolBridge   |                                 |                |
|    |  MultiAgentProtocol     |                                 | (2) JSON-RPC   |
+------------------------------+---------------------------------|----------------+
                                                                 |     stdin/out
                                                                 v
+---------------------------------------------------------------------------------+
|                     SANDBOXED PYTHON MAF SIDECAR RUNTIME                        |
|                                                                                 |
|    +-----------------------------------------------------------------------+    |
|    |                            MultiAgentServer                           |    |
|    |   - JSON-RPC 2.0 Dispatcher (asyncio line-delimited stream)           |    |
|    +-----------------------------------+-----------------------------------+    |
|                                        |                                        |
|         +------------------------------+-------------------------------+        |
|         v                                                              v        |
|    +----------------------------+            +----------------------------+     |
|    |     SpecialistRegistry     |            |    WorkflowOrchestrator    |     |
|    |  - 7 Built-in Specialists  |            |  - Sequential Chains       |     |
|    |  - Custom Dynamic Roles    |            |  - Parallel Fan-Out/In     |     |
|    |  - Security Middlewares    |            |  - Dynamic Agent Handoffs  |     |
|    +-------------+--------------+            +-------------+--------------+     |
|                  |                                         |                    |
|                  v                                         v                    |
|    +----------------------------+            +----------------------------+     |
|    |     AetherChatClient       |            |    AetherSessionManager    |     |
|    |  - Swift Metal Delegate    |            |  - MAF FileCheckpointStore |     |
|    |  - Token Stream Yielding   |            |  - Crash Recovery on Disk  |     |
|    |  - Fallback Mock Engine    |            |  - Concurrency Locks       |     |
|    +----------------------------+            +----------------------------+     |
|                                                                                 |
|    +-----------------------------------------------------------------------+    |
|    |                      Official MAF Middleware Pipeline                 |    |
|    |  - PromptInjectionScreeningMiddleware (ChatMiddleware)               |    |
|    |  - SecretScrubbingMiddleware (ChatMiddleware - Token & Key Scrubbing)  |    |
|    |  - ToolExecutionGuardMiddleware (FunctionMiddleware - Path Traversal)  |    |
|    |  - ExecutionBudgetMiddleware (AgentMiddleware - Retries & Step Bounds) |    |
|    +-----------------------------------------------------------------------+    |
|                                                                                 |
|    +-----------------------------------------------------------------------+    |
|    |                     SwiftToolBridge (FunctionTool)                    |    |
|    |  - Wraps native Aether & MCP tools into MAF FunctionTool objects       |    |
|    |  - Dispatches tool invocations back to Swift for 3-tier authorization  |    |
|    +-----------------------------------------------------------------------+    |
+---------------------------------------------------------------------------------+
```

---

## 2. Directory and File Layout

### Native Swift Integration (`Aether/Sources/Agent/MultiAgent/`)
- `MultiAgentProtocol.swift`: Strongly-typed Swift 6 models for JSON-RPC requests, responses, event streams, agent metadata, checkpoints, and telemetry.
- `MultiAgentTransport.swift`: Transport abstractions (`AnyMultiAgentTransport`, `SubprocessMultiAgentTransport`, `InMemoryMultiAgentTransport`).
- `MultiAgentSidecarManager.swift`: Subprocess lifecycle manager executing Python virtual environment with non-blocking async pipes.
- `MultiAgentToolBridge.swift`: Authorization proxy intercepting sidecar tool requests and routing them through `ToolSecurityGuard` and user approval sheets.
- `MultiAgentSupervisor.swift`: Main coordinating actor providing public Swift APIs for workflows, registries, sessions, and telemetry.

### Sandboxed Python Sidecar (`Aether/Resources/Sidecars/MultiAgent/`)
- `server.py`: JSON-RPC 2.0 server processing incoming operations over standard input and delivering structured responses and events over standard output.
- `agents.py`: `SpecialistRegistry` managing built-in roles (`supervisor`, `planner`, `researcher`, `coder`, `analyst`, `reviewer`, `assistant`) and dynamic custom roles.
- `workflow.py`: `WorkflowOrchestrator` constructing and running MAF `WorkflowBuilder` topologies with `ResultAggregator` and step checkpointing.
- `session.py`: `AetherSessionManager` integrating MAF's durable `FileCheckpointStorage` for disk recovery, concurrency locking, and turn management.
- `model_client.py`: `AetherChatClient` providing streaming and non-streaming LLM responses via Swift IPC or deterministic test generators.
- `tools.py`: `SwiftToolBridge` wrapping tools into MAF `FunctionTool` instances.
- `middleware.py`: MAF security and guardrail middleware pipeline.
- `observability.py`: OpenTelemetry tracing spans and secret sanitization helpers.
- `protocol.py`: Pydantic V2 schemas for protocol validation.
- `tests/test_maf_integration.py`: Unit and integration test suite executing under `unittest` and `pytest`.

---

## 3. JSON-RPC Protocol Specification

Communication occurs over line-delimited JSON on `stdin` and `stdout`. All diagnostic logs are redirected to `stderr` to prevent stream corruption.

### Requests
```json
{
  "type": "request",
  "request": {
    "protocol_version": "1.0.0",
    "request_id": "req_1731234567_0",
    "session_id": "sess_default",
    "operation": "run_sequential",
    "payload": {
      "goal": "Refactor inference worker into actor",
      "roles": ["planner", "coder", "reviewer"],
      "timeout_seconds": 60.0
    }
  }
}
```

### Supported Operations
| Operation | Description |
|---|---|
| `initialize` | Handshake verifying protocol version, active tools, and MAF status. |
| `list_agents` | Returns all registered built-in and dynamic agents with metadata. |
| `get_agent` | Retrieves configuration and tools for a specific agent. |
| `register_agent` | Dynamically registers a custom specialist agent with system instructions. |
| `update_agent` | Activates or deactivates an existing agent. |
| `delete_agent` | Removes a custom agent from the registry. |
| `invoke_agent` | Dispatches a direct turn to a single specialist agent. |
| `run_sequential` | Executes a sequential chain workflow using MAF `WorkflowBuilder.add_chain`. |
| `run_parallel` | Executes a parallel fan-out/fan-in workflow with `ResultAggregator`. |
| `run_handoff` | Performs dynamic triage and agent-to-agent delegation. |
| `checkpoint_session` | Durably saves workflow execution state using `FileCheckpointStorage`. |
| `restore_session` | Restores workflow execution state from disk across sidecar restarts. |
| `get_metrics` | Returns OpenTelemetry invocation counters, latency, and tool telemetry. |
| `cancel` | Halts in-flight workflow tasks and child subprocesses. |
| `shutdown` | Gracefully closes the sidecar server. |

---

## 4. Multi-Agent Topologies

### Sequential Chain
```
[User Goal]
     |
     v
[Planner] ---> [Coder] ---> [Reviewer]
     |              |             |
     v              v             v
 (Checkpoint)  (Checkpoint)  (Checkpoint) ---> [Final Output]
```

### Parallel Fan-Out / Fan-In
```
                   [Planner]
                       |
        +--------------+--------------+
        |                             |
        v                             v
  [Researcher]                    [Analyst]
        |                             |
        +--------------+--------------+
                       |
                       v
              [ResultAggregator]
                       |
                       v
                  [Reviewer]
                       |
                       v
                 [Final Output]
```

### Dynamic Handoff
```
[User Request]
     |
     v
[Supervisor (Triage)]
     |
     +--- (Routes based on domain) ---> [Specialist (e.g. Coder)]
                                                  |
                                                  v
                                            [Final Output]
```

---

## 5. Security & Governance Implementation

1. **3-Tier Tool Authorization:** Tools are registered with `ToolPermissionTier`:
   - `safeReadOnly`: Read-only queries execute without UI prompt.
   - `userConfirmationRequired`: Filesystem writes, deletions, and commands display an interactive confirmation modal sheet in SwiftUI before execution.
   - `restrictedSystem`: System-critical commands are blocked by default.
2. **Path Traversal Shielding:** `ToolExecutionGuardMiddleware` screens all tool argument values for `..` or URL-encoded `%2e%2e` sequences and immediately raises a `PermissionError`.
3. **Prompt Injection Mitigation:** `PromptInjectionScreeningMiddleware` evaluates incoming text for instruction overrides (e.g. `ignore previous instructions`, `bypass mode`) and aborts execution before model inference.
4. **Secret Scrubbing:** `SecretScrubbingMiddleware` scrubs OpenAI, GitHub, Bearer tokens, and generic API keys from outgoing assistant messages using regex sanitization.
5. **Durable Crash Resistance:** `FileCheckpointStorage` writes checkpoints atomically (`os.replace`) to `~/.aether/checkpoints`. State survives sidecar termination and restart.

---

## 6. Verification and Testing

### Running Swift Tests
```bash
xcodebuild test -scheme Aether \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:AetherTests/MultiAgentTests \
  -only-testing:AetherTests/MultiAgentSecurityTests \
  -only-testing:AetherTests/AgentOrchestratorTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

### Running Python MAF Sidecar Tests
```bash
cd "Aether/Resources/Sidecars/MultiAgent"
PYTHONPATH=. .venv/bin/pytest tests/test_maf_integration.py -v
```

