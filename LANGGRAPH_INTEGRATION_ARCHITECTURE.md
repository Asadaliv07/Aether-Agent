# AETHER × LANGGRAPH INTEGRATION ARCHITECTURE
## Architectural Specification & Integration Assessment

**Platform:** macOS 14.0+ (Apple Silicon Metal Accelerated)  
**Host Application:** Aether macOS (Swift 6.0 Strict Concurrency, SwiftUI, AppKit)  
**Dual Framework Strategy:** Microsoft Agent Framework (`agent-framework-core==1.24.0`) + LangGraph (`langgraph==1.2.20`)  
**IPC Boundary:** Robust JSON-RPC 2.0 over Standard I/O (16MB Frame Guard, Generation Tracking, Approval Tokens)  
**Status:** Approved Architectural Blueprint

---

## 1. Architectural Overview

Aether evolves from a single-framework orchestration engine into a **unified dual-engine multi-agent platform**. Users and internal subsystems can select either the **Microsoft Agent Framework (MAF)** or **LangGraph** as their execution backend without changing application contracts, native tool integrations, local Metal inference, or security policies.

```
                           +-----------------------------------+
                           |       Aether macOS Application    |
                           |   (Swift 6.0, SwiftUI, AppKit)    |
                           +-----------------+-----------------+
                                             |
                                             v
                           +-----------------+-----------------+
                           |   Unified MultiAgentSupervisor    |
                           |   (Framework Routing & Control)   |
                           +-----------------+-----------------+
                                             |
                      +----------------------+----------------------+
                      |                                             |
                      v                                             v
     +--------------------------------+            +--------------------------------+
     |   MAF Orchestration Backend    |            |   LangGraph Execution Backend  |
     | (Agent Framework Core 1.24.0)  |            |  (LangGraph 1.2.20 StateGraph) |
     +----------------+---------------+            +----------------+---------------+
                      |                                             |
                      +----------------------+----------------------+
                                             |
                                             v
                           +-----------------+-----------------+
                           |     MultiAgentSidecarManager      |
                           |  (JSON-RPC 2.0 / Stdin & Stdout)  |
                           +-----------------+-----------------+
                                             |
                      +----------------------+----------------------+
                      |                                             |
                      v                                             v
     +--------------------------------+            +--------------------------------+
     |  Native Swift Tools & Security |            |   Aether Local LLM Inference   |
     | (ToolSecurityGuard, SHA-256    |            | (Apple Silicon Metal GGUF via  |
     |  ApprovalToken, Sandbox Roots) |            |   llama.xcframework / In-Proc) |
     +--------------------------------+            +--------------------------------+
```

---

## 2. Invariants & Preservation Rules

1. **Swift Authority Remains Sovereign:**
   Swift retains exclusive authority over file system access, process lifecycle, local LLM generation, tool security policies, and user confirmations. Neither MAF nor LangGraph may execute tools without passing through Swift's `ToolSecurityGuard` and verifying single-use `ApprovalToken` cryptographic hashes.

2. **Offline-First & Local Hardware Acceleration:**
   All agent nodes in LangGraph utilize Aether's native local Apple Silicon Metal LLM (`InferenceService`) through `AetherChatClient` and the line-delimited `model_request` / `model_response` IPC loop. No external API keys or remote cloud services are required.

3. **Zero MAF Regression:**
   Existing MAF workflows (`WorkflowOrchestrator`, `SpecialistRegistry`, `AgentRoleType`, `AetherSessionManager`) remain fully operational, maintaining 100% test pass rates across both Swift and Python test suites.

4. **Zero Embedded Packaging In This Milestone:**
   Packaging standalone CPython runtimes or `.app` distribution bundles is explicitly deferred until LangGraph integration, testing, and stabilization are verified.

---

## 3. LangGraph Backend Architecture

### 3.1. Typed Graph State (`AetherGraphState`)
LangGraph state transitions are strictly typed using Python `TypedDict` and Pydantic models:

```python
class AetherGraphState(TypedDict):
    goal: str
    current_role: str
    step_count: int
    messages: List[Dict[str, Any]]
    agent_outputs: Dict[str, str]
    final_answer: str
    next_role: Optional[str]
    is_interrupted: bool
    requires_approval: bool
    pending_action: Optional[Dict[str, Any]]
    error: Optional[str]
```

### 3.2. Supported StateGraph Topologies
1. **Sequential Chain Graph:**
   Direct node sequence (`START -> Planner -> Coder -> Reviewer -> END`).
2. **Parallel Fan-Out / Fan-In Graph:**
   Planner branches concurrently into multiple specialist nodes (`Researcher`, `Coder`), then gathers into an `Aggregator` node before final synthesis.
3. **Dynamic Conditional Routing (Evaluator-Optimizer / Handoff):**
   Supervisor or Triage agent assesses intermediate outputs and uses conditional edges (`add_conditional_edges`) to route execution dynamically or terminate with approval.
4. **Human-in-the-Loop Interruption:**
   When an action requires approval, the graph pauses via LangGraph interruption, persists a checkpoint, and emits an `approvalRequired` event to Swift. Resumption occurs with `resume_graph`.

### 3.3. Checkpoint Persistence & Sandboxing
LangGraph checkpoints are integrated with Aether's sandboxed storage manager:
- Directory: `~/Library/Application Support/Aether/Checkpoints/`
- Schema version: `1.1.0`
- Bounded retention: maximum 20 checkpoints per session with automated LRU cleanup.

---

## 4. Swift & Protocol Integration

### 4.1. Protocol Schema Additions
`SidecarRequest` supports an explicit `framework` parameter:
```json
{
  "type": "request",
  "request": {
    "protocol_version": "1.0.0",
    "request_id": "req_101",
    "session_id": "sess_202",
    "operation": "run_sequential",
    "payload": {
      "framework": "langgraph",
      "goal": "Refactor parser",
      "roles": ["planner", "coder", "reviewer"]
    }
  }
}
```

### 4.2. Swift API Additions
In `MultiAgentProtocol.swift`:
```swift
public enum OrchestrationFramework: String, Codable, Sendable, CaseIterable {
    case maf = "maf"
    case langgraph = "langgraph"
}
```

In `MultiAgentSupervisor.swift`:
All workflow methods (`executeSequential`, `executeParallel`, `executeHandoff`) accept an optional `framework: OrchestrationFramework = .maf` parameter, enabling callers to toggle seamlessly between backends. Furthermore, `executeGraph` and `resumeGraph` provide native access to arbitrary StateGraph workflows.

---

## 5. Security & Isolation Controls
- All LangGraph node executions run within the sandboxed Python sidecar process.
- Tool invocations by LangGraph agents require a valid, non-expired, single-use `ApprovalToken`.
- Prompt injection screening and secret scrubbing middleware apply uniformly across both MAF and LangGraph agent turns.
- Maximum step limits and recursion depth limits prevent infinite graph loops.

