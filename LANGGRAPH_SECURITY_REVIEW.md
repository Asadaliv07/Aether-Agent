# AETHER × LANGGRAPH SECURITY REVIEW
## Threat Model, Authorization Gates, and Sandboxing Analysis

**Platform:** macOS 14.0+ (Apple Silicon Metal Accelerated)  
**Host Application:** Aether macOS (Swift 6.0 Strict Concurrency, App Sandbox)  
**Runtime:** Dedicated Python Sidecar (`Aether/Resources/Sidecars/MultiAgent/.venv`)  
**Engines:** Microsoft Agent Framework (`agent-framework-core==1.24.0`) + LangGraph (`langgraph==1.2.20`)  
**Security Classification:** High-Assurance / Zero-Trust Sidecar Boundary  
**Date:** November 11, 2026  

---

## 1. Executive Security Summary

The integration of **LangGraph 1.2.20** into Aether adheres strictly to the **Swift-First Sovereign Security Architecture**:
1. **Swift Owns Application Authority:** The Python runtime (hosting both Microsoft Agent Framework and LangGraph) remains a subordinate worker process connected via line-delimited JSON-RPC 2.0 over standard I/O pipes. The Python sidecar cannot directly invoke operating system APIs, access user files outside authorized sandboxes, or bypass Swift's security gates.
2. **Cryptographic Tool Authorization (`ApprovalToken`):** Any tool invocation requested by a LangGraph node must be routed back through Swift's `MultiAgentToolBridge` and validated by `ToolSecurityGuard`. Restricted tools require single-use SHA-256 HMAC cryptographic approval tokens signed by Swift.
3. **Defense-in-Depth Middleware:** LangGraph nodes are wrapped with automated prompt-injection screening, secret/credential scrubbing, path-traversal prevention, and strict timeout enforcement.
4. **Session Isolation:** LangGraph state persistence using `PersistentAetherCheckpointer` isolates state strictly by `session_id` (`thread_id`), preventing cross-session data leakage.

---

## 2. Threat Modeling & Attack Surface Analysis

```
+--------------------------------------------------------------------------------+
|                             Aether macOS (Host App)                            |
|  [AppKit / SwiftUI] -> [ToolSecurityGuard] -> [AuthorizedDirectoryManager]     |
|                                     ^                                          |
|                                     | 16MB Line-Delimited JSON-RPC 2.0         |
|                                     v                                          |
|  [MultiAgentSidecarManager] <===============> [server.py (MultiAgentServer)]   |
+--------------------------------------------------------------------------------+
                                                        |
                 +--------------------------------------+--------------------------------------+
                 |                                                                             |
                 v                                                                             v
+----------------------------------+                                         +----------------------------------+
|  Microsoft Agent Framework 1.24  |                                         |        LangGraph Engine 1.2      |
|  - Sequential/Parallel/Handoff   |                                         |  - StateGraph Node Execution     |
|  - SpecialistRegistry            |                                         |  - Conditional Routing / HITL    |
|  - SwiftToolBridge Client        |                                         |  - PersistentAetherCheckpointer  |
+----------------------------------+                                         +----------------------------------+
                 |                                                                             |
                 +--------------------------------------+--------------------------------------+
                                                        |
                                                        v
                                       +----------------------------------+
                                       |       Security Middleware        |
                                       |  1. PromptInjectionScreener      |
                                       |  2. SecretScrubber (API/Key PII) |
                                       |  3. PathTraversalGuard           |
                                       +----------------------------------+
```

| Attack Vector | Threat Level | Defense Mechanism | Residual Risk |
| :--- | :--- | :--- | :--- |
| **Prompt Injection via Graph Input** | High | `PromptInjectionScreener` inspects every incoming turn for jailbreak patterns, system prompt overrides, and role confusion before nodes execute. | Low (Continuous heuristic & regex update) |
| **Tool Abuse / Privilege Escalation** | Critical | 3-tier permission model enforced by Swift `ToolSecurityGuard`. High-risk tools require interactive confirmation and cryptographic tokens. | Minimal |
| **Path Traversal via Tool Parameters** | High | `PathTraversalGuard` in sidecar middleware and `AuthorizedDirectoryManager` in Swift ensure paths stay within sanctioned directories. | Minimal |
| **Secret / Key Leakage in Graph State** | Medium | `SecretScrubber` strips OpenAI keys, AWS tokens, GitHub PATs, and bearer tokens from node outputs prior to state serialization. | Low |
| **Replay Attacks on Tool Executions** | High | Single-use `ApprovalToken` with unique UUID, timestamp TTL (60s), and SHA-256 HMAC over parameters. Replayed tokens fail validation. | Negligible |
| **Cross-Session State Bleed** | High | Checkpoint directory keyed by `session_id`; LangGraph graphs compiled with independent `thread_id` configurations. | Negligible |
| **Sidecar Process Hang / Resource Exhaustion** | Medium | Dynamic timeouts (`timeoutSeconds` per workflow), hardware-adaptive concurrency limits, and sub-process lifecycle termination. | Low |

---

## 3. Cryptographic Tool Authorization Protocol

When a LangGraph node triggers a tool execution (such as `calculator`, `system_info`, or `file_reader`):
1. **Sidecar Dispatch:** LangGraph calls `self.tool_bridge.execute_tool(tool_name, parameters, agent_role, task_id)`.
2. **IPC Dispatch:** A `tool_request` JSON payload is sent over stdout to Swift.
3. **Swift Security Inspection:** `MultiAgentToolBridge.handleToolRequest()` routes the request to `ToolSecurityGuard`:
   - **Tier 1 (Safe Read-Only):** Automatically executed within sandbox.
   - **Tier 2 (User Confirmation Required):** Swift suspends execution and requests user approval. If approved, an ephemeral `ApprovalToken` is generated.
   - **Tier 3 (Restricted System):** Requires explicit confirmation and valid HMAC signature.
4. **Validation Logic:**
   ```swift
   guard token.toolName == toolName,
         token.sessionId == sessionId,
         token.timestamp + 60.0 > Date().timeIntervalSince1970,
         !usedTokens.contains(token.id) else {
       return .failure("ApprovalToken invalid or expired.")
   }
   ```
5. **Execution & Audit:** Only after validation does `ToolRegistry` execute the tool. All invocations are logged to `ToolAuditLogger`.

---

## 4. LangGraph Middleware Security Enforcement

### 4.1. Prompt Injection Screening
Every node in `LangGraphWorkflowEngine._execute_agent_node()` executes prompt screening prior to calling the language model:
```python
user_input = state.get("goal", "")
if state.get("messages"):
    user_input = state["messages"][-1].get("content", user_input)
self.injection_screener.screen_text(user_input)
```
Identifies patterns such as:
- `"ignore previous instructions"`
- `"disregard all prior system rules"`
- `"you are now in developer debug mode"`
- `"DAN mode enabled"`

Violations trigger immediate `SecurityException`, aborting the graph step and notifying Swift via `AGENT_FAILED` telemetry.

### 4.2. Secret Scrubbing
Before updating `AetherGraphState["agent_outputs"]` or emitting `AGENT_COMPLETED` events, the output text is scrubbed:
```python
scrubbed_response = self.secret_scrubber.scrub(raw_response)
```
Redacts:
- API Keys: `sk-[a-zA-Z0-9]{32,}`, `ghp_[a-zA-Z0-9]{36}`, `AKIA[0-9A-Z]{16}`
- Private Keys: `-----BEGIN [A-Z ]+ PRIVATE KEY-----`
- Passwords & Auth Tokens in JSON / URI schemes.

### 4.3. Path Traversal Mitigation
Any file system references in tool calls or node states are sanitized:
- Directory traversal sequences (`../`, `..\\`) are strictly rejected.
- Null-byte injections (`%00`) are blocked.
- Paths are resolved to their canonical absolute representations and verified against allowed sandbox roots.

---

## 5. Human-in-the-Loop (HITL) Interruption Security

For workflows requiring human intervention:
1. **Deterministic Interruption:** LangGraph graphs can compile with `interrupt_before` or `interrupt_after` on sensitive node boundaries (e.g. `approval_node`).
2. **State Freezing:** When interrupted, `AetherGraphState` is committed to durable storage via `PersistentAetherCheckpointer`.
3. **Telemetry Notification:** An `approvalRequired` event is emitted to Swift with the exact pending action.
4. **Secure Resumption:** The graph can only resume via `supervisor.resumeGraph(sessionId:approvalData:)`, verifying that the user approved the pending operation before continuing to the subsequent node.

---

## 6. Audit & Test Verification Results

All security guarantees were verified using dedicated unit and integration tests:

| Test Case | Description | Verification Method | Status |
| :--- | :--- | :--- | :--- |
| `testApprovalGatePreventsUnauthorizedToolExecution` | Rejects unregistered/unauthorized tools | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `testApprovalTokenValidationAndExecution` | Validates valid cryptographic tokens | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `testApprovalTokenExpirationRejected` | Rejects expired tokens (> 60s) | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `testApprovalTokenParameterTamperingRejected` | Rejects tampered parameter payloads | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `testApprovalTokenReplayAttackRejected` | Rejects replay of used tokens | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `testToolPathTraversalBlockedBySidecarMiddleware` | Blocks `../../etc/passwd` injection | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `testPromptInjectionScreeningRejectsAttacks` | Blocks prompt injection jailbreaks | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `testCrossSessionContextIsolation` | Verifies zero leakage between sessions | XCTest (`MultiAgentSecurityTests`) | **PASS** |
| `test_langgraph_prompt_injection_rejection` | LangGraph input screening rejection | Pytest (`test_langgraph_integration.py`) | **PASS** |
| `test_langgraph_secret_scrubbing` | LangGraph output API key redaction | Pytest (`test_langgraph_integration.py`) | **PASS** |
| `test_langgraph_path_traversal_blocking` | LangGraph tool path traversal blocked | Pytest (`test_langgraph_integration.py`) | **PASS** |
| `test_langgraph_session_isolation` | Multi-session state divergence | Pytest (`test_langgraph_integration.py`) | **PASS** |

---

## 7. Conclusion

The LangGraph integration maintains full parity with Aether's established enterprise security posture. The host Swift application remains sovereign, tool executions are strictly gated, inputs and outputs are screened and sanitized, and durable state storage respects macOS App Sandbox boundaries.

