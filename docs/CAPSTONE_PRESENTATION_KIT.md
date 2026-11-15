# Aether: Capstone Presentation Kit & Technical Defense Guide

**Project:** Aether — Local-First Personal AI Agent for Apple Silicon Macs  
**Version:** v1.0.0 (Phase 4 Capstone Edition)  
**Target Audience:** Academic Evaluators, Industry Judges, Technical Reviewers  
**Language/Frameworks:** Swift 6, SwiftUI, AppKit, Metal Performance Shaders, C/C++ (`llama.xcframework`)  
**Deployment Target:** macOS 14.0+ (Sonoma, Sequoia) on Apple Silicon (`arm64`)  

---

## 1. Polished Project Introduction

### The Elevator Pitch
> "Aether is a local-first personal AI agent engineered natively in Swift 6 for Apple Silicon Macs. Unlike cloud-tethered assistants that transmit user prompts, documents, and credentials to remote servers, Aether executes local open-weight large language models entirely within Apple Silicon unified memory using direct Metal GPU acceleration. 
> During inference and tool execution, zero conversational data is transmitted off-device. Combining an autonomous multi-step execution loop with an interactive human-in-the-loop security architecture, Aether provides capable tool-calling workflows strictly bounded by the macOS App Sandbox."

### The Problem Statement
1. **Cloud Data Transmission:** Mainstream AI agents (ChatGPT, Claude, Copilot) require users to stream private code, documents, and credentials to third-party cloud infrastructure.
2. **Runtime Overhead:** Web-wrapped desktop runtimes (Electron/Chromium) introduce significant memory overhead and multi-process IPC complexity.
3. **Unchecked Agent Actions:** Unsandboxed CLI agents can execute destructive shell commands or file modifications silently without human authorization.

### The Aether Solution
- **Local Metal Inference:** In-process C/C++ inference using Metal Performance Shaders directly on Apple Silicon unified memory. Conversational data never leaves the host machine.
- **Controlled Network Scope:** Network access is isolated to user-initiated Hugging Face catalog searches and model downloads via background `URLSession` under the `com.apple.security.network.client` sandbox entitlement.
- **Measured Native Footprint:** Pure Swift 6 / SwiftUI application with a measured resident set size (RSS) of approximately 120 MB at idle before loading model weights.
- **Security-First Tooling:** Kernel-enforced macOS App Sandbox (`com.apple.security.app-sandbox`), path traversal prevention, prompt injection heuristics, and interactive Swift Concurrency continuation sheets for sensitive actions.

---

## 2. Concise 5-Minute Presentation Narration

### [0:00 – 0:45] Scene 1: The Privacy & Apple Silicon Thesis
*(Visual: Clean macOS desktop showing system specifications and launching Aether.app from Applications)*

**Spoken Narration:**
> "Good morning, evaluators. Today, I am presenting Aether, an autonomous personal AI agent engineered natively for macOS on Apple Silicon.
> In modern software development, AI agents are increasingly indispensable, yet virtually all mainstream solutions rely on proprietary cloud APIs. This creates a severe trade-off between capability and privacy.
> Aether addresses this by running the complete inference and tool-execution stack on-device. By taking advantage of Apple Silicon's unified memory architecture—where the CPU and Metal GPU share high-bandwidth RAM without PCIe transfer bottlenecks—Aether runs quantized local models with real-time streaming, zero cloud subscriptions, and full data privacy during local model execution."

### [0:45 – 1:30] Scene 2: Architecture & Native Runtime
*(Visual: Aether window opens. Split view showing sidebar, Model Library, and Chat)*

**Spoken Narration:**
> "Notice the responsiveness of the native interface. Built with native Swift 6 and SwiftUI rather than an Electron wrapper, Aether has a measured idle memory footprint of approximately 120 megabytes before model weights are allocated.
> In the sidebar, we have our Conversation History backed by an in-container SQLite database, and our Model Library. Let's look at how Aether manages local AI models."

### [1:30 – 2:30] Scene 3: Model Management & Hugging Face Hub
*(Visual: Model Library view, showing curated GGUF models, quantization badges, RAM estimates, and download actions)*

**Spoken Narration:**
> "Aether integrates an on-device Hugging Face catalog browser. Users can explore open-weight models such as Qwen 2.5 Coder, Llama 3.2, and Mistral across various quantization tiers—from lightweight 1.5-billion parameter models up to 14-billion parameter models.
> Network access is strictly scoped to this feature: downloads run via Apple's background URLSession with resume capabilities, SHA-256 integrity verification, and security-scoped bookmark persistence. Once downloaded, models are bound in-process to our Metal inference engine."

### [2:30 – 3:30] Scene 4: Autonomous Agent Loop & Planning Summaries
*(Visual: Switch to Chat, toggle Agent Mode ON. Prompt: "Calculate the surface area of a cylinder with radius 4.2 cm and height 12.8 cm, explaining your work.")*

**Spoken Narration:**
> "Now let's examine Aether's autonomous agent engine. When Agent Mode is enabled, Aether injects structured tool definitions and protocols into the model's system prompt.
> As tokens stream from our local Metal backend, our streaming parser identifies the model's `<thought>` tags in real time. Rather than exposing raw tags, the UI isolates these model-generated planning summaries into a dedicated, collapsible disclosure card with an orange indicator. This gives the user clear visibility into the model's planned sequence of actions without cluttering the final response."

### [3:30 – 4:15] Scene 5: Native Tool Execution & Arithmetic Precision
*(Visual: Model emits `<tool_call><name>safe_calculator</name>...`. Top-bar displays "Executing: safe_calculator". Green SUCCESS badge appears in bubble)*

**Spoken Narration:**
> "Local language models frequently hallucinate floating-point arithmetic. Here, the model recognizes it needs mathematical accuracy and emits a structured tool call to `safe_calculator`.
> Because calculation has no side effects, our Tool Registry immediately executes the expression using a pure Swift recursive descent arithmetic parser. There are zero shell commands, zero subprocesses, and zero external network calls. The computed result is fed back into the context, allowing the agent to synthesize the final verified answer."

### [4:15 – 5:00] Scene 6: Human-in-the-Loop Security & Conclusion
*(Visual: Prompt: "Inspect /Users/Shared/notes.txt and summarize it." Interface halts and displays ToolConfirmationDialog sheet. Click "Allow Once")*

**Spoken Narration:**
> "Now, consider what happens when an agent needs to touch the file system. I ask Aether to inspect a local document. File system access is sensitive, so the agent loop suspends using Swift Concurrency continuations and presents our `ToolConfirmationDialog`.
> The user retains complete authority: they see the exact tool name, permission tier, and target path, and can grant one-time permission, trust for the session, or deny execution. Our Security Guard actively validates against path traversal attacks like `../` escapes and scans for adversarial prompt injections.
> In conclusion, Aether proves that personal AI agents can be autonomous, secure, and privacy-preserving entirely on Apple Silicon. All 251 automated tests pass with a 100% success rate across 15 test suites. Thank you, and I look forward to your questions."

---

## 3. Feature-by-Feature Demonstration Sequence

| Step | User Action | UI Reaction | Evaluator Value Demonstrated |
| :---: | :--- | :--- | :--- |
| **1** | Launch `Aether.app` | Window appears cleanly (~120 MB RSS measured idle footprint). | Proves native desktop architecture vs heavy Electron runtimes. |
| **2** | Open **Model Library** | Shows curated GGUF models with quantization tags (Q4_K_M, Q8_0), estimated RAM, and download states. | Shows self-contained model lifecycle management without external tools like Ollama. |
| **3** | Select Chat & Toggle **Agent Mode** | Header chip updates to active green with agent telemetry capsule. | Demonstrates mode isolation between standard chat and autonomous tool execution. |
| **4** | Send Complex Math Prompt | Real-time token streaming; `<thought>` tag collapses into "Reasoning Process" card. | Demonstrates real-time stream parsing and extraction of model-generated planning summaries. |
| **5** | Tool Dispatch (`safe_calculator`) | Monospace parameter card appears; tool runs; returns exact mathematical result with green badge. | Proves safe tool dispatch, pure Swift arithmetic parsing, and zero hallucination. |
| **6** | Trigger Sensitive File Read | `ToolConfirmationDialog` modal sheet animates onto screen, pausing execution. | Proves human-in-the-loop security gate and continuation-based execution pause. |
| **7** | Click "Allow Once" | Modal dismisses; file content is clamped and summarized in conversational prose. | Demonstrates resume of suspended agent loop with verified output synthesis. |
| **8** | Inspect macOS Console | Filter `com.aether.agent` / `ToolAudit`; show duration and redacted parameters. | Proves structured audit logging and automatic redaction of sensitive keys. |

---

## 4. Technical Architecture Explanation (For Evaluators)

Aether is architected in four strict horizontal layers:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           1. UI & PRESENTATION                          │
│  SwiftUI 6 + AppKit Windowing • MVVM Pattern • @Observable State        │
│  ChatView • MessageBubbleView • ToolConfirmationDialog • ModelLibrary   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         2. AGENT EXECUTION LAYER                        │
│  AgentOrchestrator Actor • Tag Parser (<thought>, <tool_call>)          │
│  Multi-Step Coordination (Max 5 Steps) • Continuation Approval Gates    │
└───────────────────┬─────────────────────────────────┬───────────────────┘
                    │                                 │
                    ▼                                 ▼
┌──────────────────────────────────────┐  ┌───────────────────────────────┐
│         3. TOOL RUNTIME & SAFETY     │  │     4. LOCAL INFERENCE ENGINE │
│  ToolRegistry Actor                  │  │  InferenceService Actor       │
│  ToolSecurityGuard Actor             │  │  llama.xcframework (C/C++)    │
│  - Path Traversal Defense (.. check) │  │  Metal Compute Kernels        │
│  - Prompt Injection Heuristics       │  │  StreamingStopFilter          │
│  - Redacted ToolAuditLogger          │  │  Context Buffer Management    │
│  Native Tools: Calc, SysInfo, Files  │  │  Unified Memory Utilization   │
└──────────────────────────────────────┘  └───────────────────────────────┘
```

### Architectural Key Points:
1. **Actor Isolation & Concurrency:** All shared state components (`AgentOrchestrator`, `ToolRegistry`, `ToolSecurityGuard`, `ToolAuditLogger`, `InferenceService`) are implemented as Swift Actors. This enforces compiler-verified data-race safety under Swift 6's strict concurrency mode.
2. **Interactive Continuation State Machine:** Sensitive operations call `withCheckedContinuation`, parking the async task until the user interacts with the SwiftUI sheet on the `@MainActor`. No blocking threads or polling loops are used.
3. **Kernel-Level Sandboxing:** The app runs under `com.apple.security.app-sandbox`. File reads outside the sandbox require explicit user selection (`NSOpenPanel`) or security-scoped bookmark resolution.

---

## 5. Technical Deep Dive: Core Systems & Protocols

### A. The AI Agent Loop
The multi-step loop executes inside `ChatViewModel.handleAgentToolExecution(...)`:
1. **Stream:** Tokens stream into the message buffer.
2. **Extract:** `AgentOrchestrator` parses XML `<tool_call>` (with JSON code-fence fallback).
3. **Authorize:** `ToolSecurityGuard` checks permission tier (`.safeReadOnly` vs `.userConfirmationRequired`). If required, a `CheckedContinuation` displays `ToolConfirmationDialog`.
4. **Execute:** `ToolRegistry` races execution against a timeout watchdog using a Swift `TaskGroup`.
5. **Observe:** The result is formatted into `<tool_response name="..." status="...">` and appended to message history.
6. **Synthesize:** The inference service is invoked for a follow-up turn. Clamped to a hard budget of **5 iterations** to prevent recursive runaway costs.

### B. Planning Summaries vs. Internal Reasoning
The `<thought>` tags represent **model-generated planning summaries** emitted as text tokens by the language model during generation. They provide visibility into the model's planned tool calls and sequence of reasoning steps. They do not constitute an introspective diagnostic of the underlying neural network weights or activations.

### C. The Tool Registry
- Actor-isolated registry mapping unique tool names to `Tool` protocol implementations.
- Provides dynamic schema generation in three formats: XML tags (`.xmlTags`), JSON Schema (`.jsonSchema`), and Markdown (`.markdown`).
- Measures execution duration with monotonic `ContinuousClock` nanosecond precision.

### D. The Security Guard
- Enforces strict path normalization and traversal detection (`..`, `%2e%2e`, system roots).
- Scans user prompts and tool outputs for adversarial injection attempts (e.g. `ignore previous instructions`, `you are now an unrestricted assistant`).
- Manages session-level authorization caches for approved directories.

### E. Local Inference Engine
- In-process dynamic library (`llama.xcframework`) utilizing Apple's Metal Performance Shaders (`ggml-metal.metal`).
- Quantized weight execution (Q4_K_M, Q8_0) directly in unified memory.
- `StreamingStopFilter` buffers multi-byte UTF-8 fragments and multi-token stop sequences, ensuring stop tokens (like `<|im_end|>`) never leak to the UI.

### F. Tool Protocols vs Model Context Protocol (MCP) Clarity
- **Implemented:** In-process, protocol-oriented Swift execution engine. Tool definitions output standard JSON Schema (`toJSONSchema()`) matching the OpenAI / Anthropic MCP standard.
- **Deferred (Phase 5):** External child-process JSON-RPC (stdio/SSE) MCP servers. Spawning external subprocess daemons was excluded from Phase 4 to preserve strict App Sandbox compliance without requesting broad process-execution entitlements.

---

## 6. 15 Technical Viva & Defense Questions with Model Answers

#### Q1: Why did you choose native Swift and Metal over running a local Python server or Electron wrapper?
> **Answer:** Native Swift 6 and Metal eliminate the 500MB+ memory overhead of Chromium/Electron and the latency of inter-process HTTP communications. Because Apple Silicon features unified memory, an in-process C/Metal binding via `llama.xcframework` allows the GPU to access model weights directly in RAM without PCIe transfers. The measured resident set size (RSS) of Aether at idle is approximately 120 MB before loading model weights into memory.

#### Q2: How does Aether handle multi-step agent reasoning without getting trapped in infinite loops?
> **Answer:** In `ChatViewModel.handleAgentToolExecution`, we enforce an explicit execution budget clamped at a maximum of 5 iterations. Each step consumes one iteration of the budget. If the model fails to produce a terminal answer within 5 turns, execution halts gracefully and prompts the user, preventing infinite loops and runaway resource consumption.

#### Q3: Why is `com.apple.security.cs.disable-library-validation` present in your entitlements? What are its security implications?
> **Answer:** The embedded framework `llama.framework` is vendored from upstream `llama.cpp` (MIT License, Georgi Gerganov) and compiled as a standalone Mach-O binary. When macOS compiles with Hardened Runtime, `dyld` mandates that all dynamically loaded frameworks share the exact same Apple Developer Team ID as the host executable. Because this project is signed ad-hoc (`CODE_SIGN_IDENTITY = "-"`), the Team IDs do not match and dyld aborts process launch without this entitlement.
> 
> *Security Implications:* Disabling library validation allows `dyld` to map the vendored `llama.framework`. However, it does **not** weaken the macOS App Sandbox (`com.apple.security.app-sandbox = true`), which is enforced independently at the kernel level (Seatbelt/MACF policy), strictly isolating file system access, network sockets, and system resources.

#### Q4: How do you prevent directory traversal attacks in the `sandboxed_file_reader` tool?
> **Answer:** `ToolSecurityGuard.sanitizeAndValidatePath` performs multiple defensive checks before any file operation: it normalizes relative path sequences, rejects parent directory traversal (`..`), checks for URL-encoded traversal (`%2e%2e`), verifies null-byte hygiene, and explicitly blocks system root paths like `/etc`, `/var`, `/private`, and `~/.ssh`. Furthermore, the file read operation is clamped to 10 MB and 200 lines to prevent buffer exhaustion.

#### Q5: How does the Human-in-the-Loop approval mechanism work asynchronously in Swift Concurrency?
> **Answer:** When a tool requiring authorization (such as `sandboxed_file_reader`) is dispatched, `ToolSecurityGuard` suspends the calling async task using `withCheckedContinuation`. It stores the continuation and presents `ToolConfirmationDialog` on the `@MainActor`. When the user clicks "Allow Once", "Allow for Session", or "Deny", the stored continuation is resumed with the boolean verdict, unblocking the execution pipeline cleanly without polling.

#### Q6: How are model planning steps displayed to the user?
> **Answer:** The system prompt instructs models to wrap their planned actions inside `<thought>...</thought>` tags. During token generation, `AgentOrchestrator` applies regular expression stream parsing to detect and isolate these blocks. The SwiftUI `MessageBubbleView` renders these model-generated planning summaries inside a collapsible disclosure card with an orange indicator, keeping the conversational text clean while providing visibility into the model's planned tool calls.

#### Q7: What happens if a tool hangs or takes an excessive amount of time?
> **Answer:** `ToolRegistry.executeTool` wraps execution in a Swift `TaskGroup` that races the tool's execution against an explicit timeout watchdog using `Task.sleep(for: .seconds(timeout))`. If the timeout fires first, the tool execution task is cancelled, and a structured `ExecutionTimeoutError` is logged and returned to the model as an error observation, preserving application responsiveness.

#### Q8: How does your calculator tool prevent remote code execution or injection attacks?
> **Answer:** Unlike implementations that pass expressions to `/bin/sh` or Python's `eval()`, Aether's `SafeCalculatorTool` uses a pure Swift recursive descent arithmetic parser (`MathParser`). It evaluates only defined mathematical operators (`+,-,*,/,%,^`) and specific transcendental functions (`sqrt`, `cos`, `log`, etc.). It contains zero subprocesses, zero shell invocations, and zero dynamic code execution.

#### Q9: How are model stop sequences handled during token streaming?
> **Answer:** We implemented a dedicated `StreamingStopFilter` actor. Because stop sequences (such as `<|im_end|>` or `\nUser:`) can be split across multiple incoming token chunks or multi-byte UTF-8 boundaries, the filter buffers partial prefix matches and only emits verified safe text. If a stop sequence is matched, generation terminates immediately and the matched sequence is stripped from the output.

#### Q10: How does Aether preserve user privacy during tool execution?
> **Answer:** All tool execution is tracked by `ToolAuditLogger`, which routes to Apple's unified logging system (`os.Logger`). Before any parameter dictionary is logged or stored in the in-memory audit history, all keys containing substrings like `token`, `secret`, `key`, or `password` are automatically redacted with `[REDACTED]`. During local model execution, no prompt or conversation data is sent over the network.

#### Q11: Does Aether connect to external Anthropic Model Context Protocol (MCP) servers?
> **Answer:** Aether's tool declarations export standard JSON Schema definitions (`toJSONSchema()`) compatible with the Anthropic MCP and OpenAI tool formats. However, external child-process MCP server connectivity (JSON-RPC over stdio or SSE) is deferred to Phase 5. Aether currently executes tools in-process to maintain strict App Sandbox compliance without requesting broad process-execution entitlements.

#### Q12: How are downloaded models persisted across application launches?
> **Answer:** Downloaded GGUF files are stored within the app's sandboxed `Application Support/com.aether.Aether/Models` container. For user-imported models selected via `NSOpenPanel`, Aether generates security-scoped bookmarks stored in SQLite, allowing the application to re-obtain sandboxed access on subsequent launches without prompting the user.

#### Q13: What quantization formats are supported, and what are their trade-offs?
> **Answer:** Aether supports standard GGUF quantization formats: Q4_K_M, Q5_K_M, and Q8_0. Q4_K_M offers the optimal balance between perplexity and memory bandwidth for small models (reducing a 7B model from 14GB in FP16 to ~4.5GB), enabling it to run comfortably on an 8GB or 16GB Apple Silicon Mac. Q8_0 provides near-FP16 fidelity for larger unified memory configurations.

#### Q14: How did you verify the application's correctness and reliability?
> **Answer:** Aether maintains an automated test suite of 251 unit and integration tests across 15 test suites. This includes tests for Metal inference context management, streaming stop filtering, model download states, tool parameter validation, path traversal guards, prompt injection detection, settings persistence, markdown code block rendering, and multi-step agent loops. All 251 tests pass with a 100% success rate in 32 seconds.

#### Q15: What are the code signing and Gatekeeper limitations of this release?
> **Answer:** Aether v1.0.0 is distributed as an ad-hoc signed release (`CODE_SIGN_IDENTITY = "-"`) with Hardened Runtime enabled. Because the project does not currently use a paid Apple Developer ID certificate, the application is not notarized by Apple. When downloaded on an external Mac, macOS Gatekeeper identifies the app as from an unidentified developer. Evaluators can launch the application using standard macOS Gatekeeper controls: by right-clicking (or Control-clicking) `Aether.app` in Finder and selecting **Open**.

---

## 7. Final Homingo Capstone Submission Description

```text
Project Title:
Aether — Local-First Personal AI Agent for Apple Silicon Macs

Short Description:
A native macOS AI agent engineered in Swift 6 that executes local open-weight LLMs via Metal GPU acceleration, featuring autonomous multi-step execution, safe tool calling, and human-in-the-loop security within the macOS App Sandbox.

Primary Technology Stack:
Swift 6, SwiftUI, AppKit, Metal Performance Shaders, llama.xcframework (C/C++), SQLite, macOS App Sandbox.

GitHub Repository:
https://github.com/Asadaliv07/Aether-Agent

Release Version:
v1.0.0 (Phase 4 Capstone Edition - Prepared locally; pending publication)

Direct DMG Download:
[Pending Publication - Will be available at: https://github.com/Asadaliv07/Aether-Agent/releases/tag/v1.0.0 once published]

Key Engineering Achievements:
1. Native Apple Silicon Architecture: 100% local Metal inference with zero cloud dependency during model execution and a measured idle memory footprint of ~120 MB RSS before model weights.
2. Autonomous Agent Loop: Multi-step execution loop with real-time extraction of model-generated planning summaries (<thought>) into collapsible disclosure cards.
3. Modular Tool Execution Engine: In-process tool registry supporting pure Swift arithmetic parsing (safe_calculator), Darwin hardware telemetry (system_info), sandboxed file inspection, and desktop notifications.
4. Human-in-the-Loop Security Gate: Interactive Swift Concurrency continuation modal (ToolConfirmationDialog) requiring explicit user approval for file operations, backed by path traversal and prompt injection defenses.
5. Integrated Model Catalog: In-app Hugging Face browser with background download management and SHA-256 integrity verification.
6. Rigorous Automated Verification: 251 automated unit and integration tests passing with a 100% success rate across 15 test suites.
```
