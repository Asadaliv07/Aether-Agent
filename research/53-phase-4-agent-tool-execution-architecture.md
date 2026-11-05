# Phase 4: Advanced Agent Capabilities & Tool Execution Architecture

## 1. Executive Summary

Phase 4 advances **Aether** from a local LLM chat and model management interface (Phase 3.10 baseline) into an autonomous, tool-executing agent operating natively and securely on macOS.

Local model execution with small-to-medium models (e.g. Qwen 2.5 Coder 1.5B/7B, Llama 3.2 1B/3B, Mistral 7B) requires strict architectural rigor:
1. **Clear Prompting Protocols:** Models must be presented with unambiguous tool definitions and instructed in structured output formats they can reliably generate (specifically XML tags `<thought>` and `<tool_call>`, with Markdown JSON code blocks as a fallback).
2. **Strict Security & Sandboxing:** Local agent execution must never allow unrestricted POSIX shell access or arbitrary file modifications. All tool calls operate under least-privilege principles, macOS App Sandbox restrictions (`com.apple.security.app-sandbox`), path sanitization against directory traversal, adversarial prompt injection detection, and mandatory interactive user approval for sensitive operations.
3. **Deterministic Failure Recovery:** Tool executions are isolated, bounded by configurable timeouts via Swift Concurrency `TaskGroup` races, gracefully cancellable by the user, and fully audited with redaction of secrets/tokens.

---

## 2. Architectural Audit & Foundation Integration

### 2.1 Baseline State (Phase 3.10)
Prior to Phase 4, Aether consisted of:
- **Core Inference Engine:** In-process C/Metal binding via `llama.xcframework`, supporting GGUF models, context management, streaming token callbacks, and stop sequences.
- **Model Catalog & Manager:** HuggingFace Hub discovery, download manager with background URLSession, sha256 checksums, and security-scoped bookmark persistence.
- **UI Architecture:** SwiftUI MVVM pattern with `ChatViewModel`, `ChatView`, and conversation history managed via SQLite / SwiftData storage.

### 2.2 Phase 4 Architectural Additions
Phase 4 introduces a dedicated `Aether/Sources/Agent` module comprising:
- `Tool.swift`: Formal protocols, type-safe parameter definitions, JSON schema generator, and execution models.
- `ToolSecurityGuard.swift`: Actor-isolated security enforcement, path traversal defense, prompt injection heuristics, and continuation-based interactive user confirmation.
- `ToolAuditLogger.swift`: Actor-isolated, privacy-preserving audit logging with parameter redaction and `os.Logger` integration.
- `ToolRegistry.swift`: Central tool registry managing discovery, lookup, category filtering, schema export for system prompts, and timed/cancellable execution pipelines.
- `NativeTools.swift`: Five native macOS tools adhering to strict sandbox boundaries and safety guarantees.
- `AgentOrchestrator.swift`: Multi-step reasoning parser, system prompt augmentor, and step coordinator.

```
┌────────────────────────────────────────────────────────────────────────┐
│                              ChatView                                  │
│   (Agent Mode Toggle, Tool Execution Indicator, Confirmation Sheet)    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                            ChatViewModel                               │
│  - Augments System Prompt with Tool Schemas                            │
│  - Captures Streamed Model Output                                      │
│  - Drives Multi-Step Agent Loop (max 5 steps)                          │
└─────────┬─────────────────────────┬──────────────────────────┬─────────┘
          │                         │                          │
          ▼                         ▼                          ▼
┌──────────────────┐      ┌───────────────────┐      ┌───────────────────┐
│ AgentOrchestrator│      │   ToolRegistry    │      │ ToolSecurityGuard │
│ - Parse <thought>│      │ - Dynamic Lookup  │      │ - Path Traversal  │
│ - Parse <tool_call│◄────►│ - Timeout Racing  │◄────►│ - Prompt Injection│
│ - Format Response│      │ - Task Isolation  │      │ - User Approvals  │
└──────────────────┘      └─────────┬─────────┘      └───────────────────┘
                                    │
                                    ▼
                          ┌───────────────────┐
                          │   Tool Protocol   │
                          └─────────┬─────────┘
                                    │
         ┌──────────────┬───────────┴───┬──────────────┬──────────────┐
         ▼              ▼               ▼              ▼              ▼
   ┌───────────┐  ┌───────────┐   ┌───────────┐  ┌───────────┐  ┌───────────┐
   │SystemInfo │  │ Sandboxed │   │ Document  │  │   Safe    │  │  System   │
   │   Tool    │  │FileReader │   │ Extractor │  │Calculator │  │Notification│
   └───────────┘  └───────────┘   └───────────┘  └───────────┘  └───────────┘
```

---

## 3. Modular Tool Execution Engine

### 3.1 Tool Protocol & Parameter Types
Every tool implements the `Tool` protocol (`Aether/Sources/Agent/Tool.swift`):

```swift
public protocol Tool: Sendable {
    var definition: ToolDefinition { get }
    func execute(parameters: [String: Any], context: ToolExecutionContext) async throws -> ToolExecutionResult
}
```

Tool definitions include:
- `name`: Unique alphanumeric identifier (e.g. `system_info`, `safe_calculator`).
- `description`: Detailed explanation of tool function and expected parameter formats.
- `category`: Categorized under `.system`, `.fileSystem`, `.computation`, `.document`, `.network`, or `.custom`.
- `permissionLevel`: Security classification (`.safeReadOnly`, `.userConfirmationRequired`, `.restrictedSystem`).
- `parameters`: Array of `ToolParameter` declarations supporting `.string`, `.integer`, `.number`, `.boolean`, `.array`, and `.object`, each with required flags, descriptions, and optional enum choices.
- `timeoutSeconds`: Tool-specific execution ceiling (defaults to 30.0s).

### 3.2 Schema Export for Model System Prompts
The engine supports multiple format representations for model ingestion:
- **XML Tag Format (`.xmlTags`):** Highly legible, structure-preserving format optimized for small local LLMs:
  ```xml
  <tool_definitions>
    <tool name="safe_calculator">
      <description>Evaluates mathematical expressions safely using a pure recursive descent arithmetic parser...</description>
      <parameters>
        <parameter name="expression" type="string" required="true">The mathematical expression to evaluate...</parameter>
      </parameters>
    </tool>
  </tool_definitions>
  ```
- **JSON Schema (`.jsonSchema`):** Standard OpenAI/Anthropic compatible schema mapping.
- **Markdown (`.markdown`):** Human-readable reference format.

### 3.3 Asynchronous Execution, Timeout Racing & Cancellation
In `ToolRegistry.executeTool(...)`:
1. **Clock Timing:** Execution duration is measured via `ContinuousClock.now` to nanosecond accuracy.
2. **Timeout Enforcement:** A Swift Concurrency `TaskGroup` races the tool's asynchronous body against an explicit `Task.sleep(for: .seconds(timeout))`. If the timeout fires first, the tool execution task is immediately cancelled, and a structured `ExecutionTimeoutError` is logged and returned.
3. **Graceful User Cancellation:** If the user presses "Stop" in the UI, the outer `Task` hierarchy propagates cancellation down to active tool operations.

---

## 4. Permission & Security Architecture

### 4.1 Three-Tier Security Model
Tools are classified into three privilege levels:
1. **`safeReadOnly`:** Operations with zero side effects and no access to private user content (e.g. `system_info`, `safe_calculator`). Executed automatically without blocking for user confirmation.
2. **`userConfirmationRequired`:** Operations accessing local files, documents, or triggering system notifications (e.g. `sandboxed_file_reader`, `document_text_extractor`, `system_notification`). Execution pauses and awaits explicit interactive user approval in the GUI.
3. **`restrictedSystem`:** High-risk operations (e.g., shell commands, network modifications). Disallowed by default, requiring both explicit user confirmation and active session permission tokens.

### 4.2 Security Guard (`ToolSecurityGuard`)
- **Interactive Continuation:** Sensitive tools request authorization through `requestConfirmation(toolName:toolDescription:parameters:)`. This suspends the calling task and presents the user with a confirmation sheet in SwiftUI. Upon user tap ("Allow Once", "Allow for Session", or "Deny"), the stored `CheckedContinuation` resumes execution.
- **Path Sanitization & Traversal Defense:** `sanitizeAndValidatePath(_:allowedPrefixes:)` rigorously detects:
  - Relative traversal sequences: `..`, `./`
  - URL-encoded traversal: `%2e%2e%2f`
  - Dangerous system root references: `/etc`, `/var`, `/private`, `/Library/Preferences`, `~/.ssh`
  - Unsanitized wildcards and null-byte injection attacks.
- **Prompt Injection Defense:** `detectPromptInjection(_:)` scans tool input and retrieved content for adversarial patterns:
  - System prompt overrides: `"ignore previous instructions"`, `"disregard all prior rules"`
  - Role hijacking: `"you are now an unrestricted assistant"`
  - Unauthorized tag closures: `</thought>`, `</tool_call>`, `<system>`

### 4.3 macOS App Sandbox Compliance
Aether enforces strict macOS App Sandbox compliance:
- Sandboxed containers strictly isolate Application Support and Cache directories.
- User files outside the container require explicit security-scoped bookmarks or user-selected paths via standard Open/Save panels.
- Zero unrestricted shell (`/bin/sh`, `/bin/zsh`) execution is permitted or implemented.

---

## 5. Native macOS Built-in Tools

| Tool Name | Category | Permission Level | Description |
| :--- | :--- | :--- | :--- |
| `system_info` | `.system` | `.safeReadOnly` | Retrieves hardware architecture, Apple Silicon chip family, active CPU cores, physical memory, macOS version, and system thermal state using `sysctl` APIs. |
| `sandboxed_file_reader` | `.fileSystem` | `.userConfirmationRequired` | Safely reads file contents with strict path traversal checking, UTF-8 decoding, a 10MB size cap, and line clamping. |
| `document_text_extractor` | `.document` | `.userConfirmationRequired` | Analyzes structured documents (JSON key hierarchy, CSV header & row counts, Markdown headers, plain text) and extracts summaries. |
| `safe_calculator` | `.computation` | `.safeReadOnly` | Evaluates arithmetic expressions using a pure Swift recursive descent parser (`MathParser`). Supports `+,-,*,/,%,^`, parentheses, constants (`pi`, `e`), and functions (`sqrt, sin, cos, tan, abs, log, ln, floor, ceil`). No subprocesses or system shell involved. |
| `system_notification` | `.system` | `.userConfirmationRequired` | Dispatches native macOS desktop notifications using `UserNotifications.framework` (`UNUserNotificationCenter`). |

---

## 6. Multi-Step Agent Orchestrator

### 6.1 Reasoning & Tool Call Extraction
Local LLMs often mix chain-of-thought reasoning with tool invocations. `AgentOrchestrator` implements robust regex-based extraction:
1. **Thought Extraction:** Identifies `<thought>...</thought>` blocks and isolates internal planning logic from conversational responses.
2. **Tool Call Extraction:**
   - Primary: `<tool_call><name>tool_name</name><parameters>{...}</parameters></tool_call>`
   - Fallback: Markdown fenced blocks (````json\n{"tool": "name", "parameters": {...}}\n````).

### 6.2 Multi-Step Execution Loop
In `ChatViewModel.handleAgentToolExecution(...)`:
1. **Step Evaluation:** If the model's output contains a `<tool_call>`, the tool name and arguments are parsed.
2. **Execution:** The tool is invoked via `ToolRegistry.executeTool(...)` (triggering GUI authorization if required).
3. **Format Response:** The result is formatted into an observation block:
   ```xml
   <tool_response name="safe_calculator" status="success">
   Result: 42
   </tool_response>
   ```
4. **Follow-Up Prompting:** The observation is appended to the message history, and the model is prompted to continue generating (either another tool call or a final user answer).
5. **Recursion Guard:** Execution is clamped at a maximum of 5 iterations to prevent infinite loops.

---

## 7. User Experience & SwiftUI Integration

### 7.1 Agent Mode Toggle & Live Telemetry
- A top-bar toggle in `ChatView` allows users to enable or disable **Agent Mode**.
- While a tool is running, a real-time animated telemetry capsule displays the active tool name (e.g. `Executing: safe_calculator`).

### 7.2 Decomposed Message Bubbles
In `MessageBubbleView.swift`, model outputs with thoughts and tool calls are cleanly decomposed:
- **Reasoning Process:** Rendered in a collapsible disclosure group with an orange lightbulb icon, letting users inspect agent thoughts without cluttering the chat.
- **Tool Invocations:** Rendered as dedicated monospace cards showing the tool name and parameter payload.
- **Tool Results:** Displayed with status badges (`SUCCESS` or `ERROR`) and collapsible output previews.
- **Final Text:** Clean conversational prose is displayed clearly at the bottom of the message.

### 7.3 Interactive Authorization Dialog
When a tool with `.userConfirmationRequired` is invoked, `ToolConfirmationDialog` appears as a sheet presenting:
- Tool Name & Category
- Plain-English description of the requested action
- Formatted parameter key-value pairs
- Three user actions: "Allow Once", "Allow for Session", and "Deny".

---

## 8. Verification & Test Suite

### 8.1 Automated Test Suites
Four dedicated test suites were implemented:
1. **`ToolExecutionTests.swift` (7 tests):**
   - Registry tool registration and lookup.
   - Category filtering.
   - Successful tool execution.
   - Missing required parameter detection.
   - Execution timeout enforcement via simulated slow tools.
   - Tool cancellation handling.
   - JSON Schema generation validity.
2. **`ToolSecurityGuardTests.swift` (5 tests):**
   - Automatic authorization for `.safeReadOnly` tools.
   - Confirmation requirement for sensitive tools.
   - Session permission caching.
   - Path sanitization and directory traversal blocking (`..`, `/etc/passwd`, encoded sequences).
   - Adversarial prompt injection detection.
3. **`NativeToolsTests.swift` (5 tests):**
   - `SystemInfoTool` hardware and CPU metrics retrieval.
   - `SafeCalculatorTool` basic arithmetic and operator precedence.
   - `SafeCalculatorTool` transcendental functions (`sqrt`, `cos`, `log`).
   - `SafeCalculatorTool` division-by-zero handling.
   - `SandboxedFileReaderTool` path traversal rejection.
4. **`AgentOrchestratorTests.swift` (5 tests):**
   - Extraction of `<thought>` tags.
   - Extraction of `<tool_call>` tags with name and parameters.
   - JSON fallback tool extraction.
   - System prompt tool augmentation.
   - Tool response XML formatting.

**Total Tests:** 239 automated tests executed across all Aether components, with **0 failures**.

---

## 9. Phase 4.1 Roadmap & Recommendations

1. **Persistent Permission Profiles:** Allow per-folder read authorizations stored securely in the macOS Keychain.
2. **Streaming Tool Output:** Support partial/streaming tool results for long-running document analysis tasks.
3. **Vector Store Integration:** Integrate SQLite `sqlite-vec` or Apple Accelerate vector embeddings for local semantic file retrieval.

