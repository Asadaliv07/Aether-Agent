# Aether Agent Mode — Master Development Tracker

**Status:** ACTIVE  
**Last Updated:** November 7, 2026  
**Current Phase:** PHASE 1 — Agent Core and Execution Architecture (COMPLETED & CLOSED)  
**Current Sub-Phase:** Sub-phase 1.3 — Asynchronous Cancellation, Pause & Human-in-the-Loop Orchestration Hardening (COMPLETED & VERIFIED)  
**Next Sub-Phase:** Sub-phase 2.1 — Request Understanding & Goal Identification Engine (AWAITING APPROVAL)  
**Host Architecture:** macOS 14.0+ (Apple Silicon `arm64`, Swift 6)  
**Strict Implementation Policy:** Exactly ONE sub-phase implemented at a time. Explicit approval required before proceeding to the next sub-phase.

---

## 1. Master Phase & Sub-Phase Overview

| Phase # | Phase Name | Sub-Phases Count | Reference Repositories | Overall Status |
|---|---|---|---|---|
| **Phase 1** | **Agent Core and Execution Architecture** | 3 Sub-Phases | `langgraph`, `openhands`, `mlx-agent` | **COMPLETED & CLOSED** |
| **Phase 2** | **Intelligent Planning and Task Management** | 3 Sub-Phases | `langgraph`, `mini-swe-agent`, `microsoft-agent-framework` | NOT STARTED |
| **Phase 3** | **Tool Registry and Tool Execution** | 3 Sub-Phases | `mcp-servers`, `mini-swe-agent`, `mlx-agent` | NOT STARTED |
| **Phase 4** | **Observation, Evaluation and Self-Correction**| 3 Sub-Phases | `openhands`, `promptfoo`, `mini-swe-agent` | NOT STARTED |
| **Phase 5** | **Persistent Memory and Checkpointing** | 3 Sub-Phases | `mem0`, `langgraph/checkpoint-sqlite`, `grdb-swift` | NOT STARTED |
| **Phase 6** | **Coding and File Engineering** | 3 Sub-Phases | `mini-swe-agent`, `openhands`, `mcp-servers` | NOT STARTED |
| **Phase 7** | **Web Research and Browser Automation** | 3 Sub-Phases | `browser-use`, `mcp-servers/fetch` | NOT STARTED |
| **Phase 8** | **Document and Data Processing** | 3 Sub-Phases | `docling`, `unstructured` | NOT STARTED |
| **Phase 9** | **Semantic Search & Local Knowledge Base (RAG)**| 3 Sub-Phases | `lancedb`, `qdrant`, `chroma` | NOT STARTED |
| **Phase 10** | **Multi-Agent Collaboration** | 2 Sub-Phases | `microsoft-agent-framework`, `langgraph` | NOT STARTED |
| **Phase 11** | **Intelligent Model Selection and Routing** | 2 Sub-Phases | `mlx-swift-lm`, `llama.cpp`, `ollama` | NOT STARTED |
| **Phase 12** | **Agent Workspace and Execution UI** | 3 Sub-Phases | `openhands`, `langfuse`, `osaurus` | NOT STARTED |
| **Phase 13** | **Security, Permissions and Sandboxing** | 3 Sub-Phases | `promptfoo`, `mcp-servers` | NOT STARTED |
| **Phase 14** | **Background Tasks and Long-Running Workflows** | 2 Sub-Phases | `osaurus`, `agenti-loop-agent` (ref only) | NOT STARTED |
| **Phase 15** | **Monitoring, Evaluation and Optimization** | 2 Sub-Phases | `langfuse`, `opentelemetry-swift`, `promptfoo` | NOT STARTED |

---

## 2. Granular Sub-Phase Tracking Table

| Sub-Phase | Title | Primary Repos Used | Affected Files | Status | Test Coverage |
|---|---|---|---|---|---|
| **1.1** | **Agent Execution State Machine & State Graph Core** | `langgraph`, `openhands`, `mlx-agent` | `AgentState.swift`, `AgentExecutionLoop.swift`, `AgentOrchestrator.swift` | **COMPLETED & CLOSED** | 23/23 Passed (283/283 total) |
| **1.2** | **Multi-Step Cyclic Reasoning Engine & Loop Controller** | `langgraph`, `openhands` | `AgentCyclicController.swift`, `ProductionAgentInferenceProvider.swift`, `AgentOrchestrator.swift` | **COMPLETED & CLOSED** | 28/28 Passed (311/311 total) |
| **1.3** | **Asynchronous Cancellation, Pause & Human-in-the-Loop** | `langgraph`, `openhands` | `AgentExecutionLoop.swift`, `AgentState.swift`, `Tool.swift`, `NativeTools.swift`, `ToolSecurityGuard.swift`, `InferenceService.swift`, `ProductionAgentInferenceProvider.swift` | **COMPLETED & CLOSED** | 18/18 Passed (329/329 total) |
| **2.1** | Request Understanding & Goal Identification Engine | `microsoft-agent-framework` | `GoalExtractor.swift`, `AgentPromptBuilder.swift` | NOT STARTED | - |
| **2.2** | Dynamic Task Decomposition & Dependency Graph (DAG) | `langgraph`, `mini-swe-agent` | `TaskDAG.swift`, `TaskPlanner.swift` | NOT STARTED | - |
| **2.3** | Adaptive Execution Plan & Replanning Loop | `langgraph` | `ExecutionPlan.swift`, `ReplanningEngine.swift` | NOT STARTED | - |
| **3.1** | MCP Standardized Schema & Tool Adapters | `mcp-servers` | `Tool.swift`, `ToolRegistry.swift`, `MCPSchema.swift` | NOT STARTED | - |
| **3.2** | Small-Model Resilient Tag & Regex Tool Invocation Parser | `mini-swe-agent` | `ToolCallParser.swift`, `AgentOrchestrator.swift` | NOT STARTED | - |
| **3.3** | Native In-Process System & Diagnostic Tools | `mcp-servers`, `NativeTools.swift` | `NativeTools.swift` | NOT STARTED | - |
| **4.1** | Structured Observation Engine & Output Normalizer | `openhands` | `AgentObservation.swift`, `OutputNormalizer.swift`| NOT STARTED | - |
| **4.2** | Result Evaluation & Pre-Completion Verification Gate | `promptfoo`, `openhands` | `ResultEvaluator.swift` | NOT STARTED | - |
| **4.3** | Automated Self-Correction & Error Recovery Engine | `mini-swe-agent`, `openhands` | `ErrorRecoveryEngine.swift` | NOT STARTED | - |
| **5.1** | SQLite Workflow Checkpointing & State Persistence | `langgraph/checkpoint-sqlite`, `grdb-swift` | `ConversationDatabase.swift`, `AgentCheckpoint.swift`| NOT STARTED | - |
| **5.2** | Dialogue Fact Distillation & User Preference Memory | `mem0` | `MemoryService.swift`, `ConversationDatabase.swift`| NOT STARTED | - |
| **5.3** | Episodic Memory Retrieval & Context Injection | `mem0`, `grdb-swift` | `MemoryService.swift`, `AgentOrchestrator.swift` | NOT STARTED | - |
| **6.1** | Windowed Sandboxed File Reader & Search | `mini-swe-agent` | `CodingTools.swift`, `NativeTools.swift` | NOT STARTED | - |
| **6.2** | Atomic Line-Clamped File Editor & Diff Engine | `mini-swe-agent`, `openhands` | `CodingTools.swift`, `FileDiffEngine.swift` | NOT STARTED | - |
| **6.3** | In-Process Git Integration Tools | `mcp-servers/git` | `GitTools.swift` | NOT STARTED | - |
| **7.1** | Sandboxed Web Fetcher & Markdown Transformer | `mcp-servers/fetch` | `WebTools.swift` | NOT STARTED | - |
| **7.2** | Headless WKWebView Numbered DOM Simplification | `browser-use` | `WebBrowserEngine.swift`, `DOMIndexer.js` | NOT STARTED | - |
| **7.3** | Interactive Web Action Controller | `browser-use` | `WebBrowserEngine.swift` | NOT STARTED | - |
| **8.1** | Structure-Aware Document Partitioner & Element Taxonomy | `unstructured` | `DocumentElement.swift`, `DocumentTextExtractor.swift`| NOT STARTED | - |
| **8.2** | Neural Table Reconstruction & High-Fidelity Doc Ingestion| `docling` | `TableExtractor.swift`, `DoclingModels.swift` | NOT STARTED | - |
| **8.3** | Structure-Preserving Document Chunking (HybridChunker) | `docling` | `HybridChunker.swift` | NOT STARTED | - |
| **9.1** | Embedded Serverless Vector Database (LanceDB) | `lancedb` | `LanceVectorStore.swift` | NOT STARTED | - |
| **9.2** | Local Vector Embedding Pipeline | `mlx-swift`, `swift-transformers`| `EmbeddingService.swift` | NOT STARTED | - |
| **9.3** | Hybrid Dense/Sparse Semantic Search & Grounded Context | `lancedb`, `qdrant` | `RAGService.swift` | NOT STARTED | - |
| **10.1**| Multi-Agent Role Contracts & Supervisor Routing | `microsoft-agent-framework` | `AgentRole.swift`, `SupervisorAgent.swift` | NOT STARTED | - |
| **10.2**| Inter-Agent Message Bus & Subagent Invocation Protocol | `langgraph` | `AgentMessageBus.swift` | NOT STARTED | - |
| **11.1**| Capability-Based Dynamic Model Routing | `ollama`, `ModelCatalogRegistry`| `ModelRouter.swift` | NOT STARTED | - |
| **11.2**| Native Apple Silicon MLX Model Execution Bridge | `mlx-swift`, `mlx-swift-lm` | `MLXInferenceWorker.swift` | NOT STARTED | - |
| **12.1**| Live Plan & Task Progress Visualizer in SwiftUI | `openhands` | `AgentPlanProgressView.swift` | NOT STARTED | - |
| **12.2**| Action/Observation Step Inspector & Code Diff Viewer | `openhands`, `langfuse` | `AgentStepInspectorView.swift`, `DiffView.swift` | NOT STARTED | - |
| **12.3**| Interactive Human-in-the-Loop Authorization Sheet | `Aether/Sources/UI` | `ToolConfirmationDialog.swift` | NOT STARTED | - |
| **13.1**| Fine-Grained Capability & Scope Permission Matrix | `mcp-servers` | `ToolSecurityGuard.swift` | NOT STARTED | - |
| **13.2**| Adversarial Injection Shield & Argument Sanitization | `promptfoo` | `ToolSecurityGuard.swift` | NOT STARTED | - |
| **13.3**| Execution Resource Watchdog & Circuit Breakers | `Aether/Sources/Agent` | `AgentWatchdog.swift` | NOT STARTED | - |
| **14.1**| Background Agent Worker & Menu Bar Controller | `osaurus` | `MenuBarAgentController.swift` | NOT STARTED | - |
| **14.2**| Asynchronous Resumption across App Restarts | `langgraph`, `grdb-swift` | `AgentResumeService.swift` | NOT STARTED | - |
| **15.1**| Structured Trace & Span Telemetry Engine | `langfuse`, `opentelemetry-swift`| `ToolAuditLogger.swift`, `AgentTracer.swift` | NOT STARTED | - |
| **15.2**| Automated Agentic Evaluation & Benchmark Suite | `promptfoo` | `AgentBenchmarkTests.swift` | NOT STARTED | - |

---

## 3. Sub-Phase 1.1 Verification Summary

* **Sub-Phase ID:** 1.1
* **Title:** Agent Execution State Machine & State Graph Core (Remediated, Hardened & Closed)
* **Status:** **COMPLETED & CLOSED**
* **Verification Date:** November 6, 2026
* **Files Created:**
  - `Aether/Sources/Agent/AgentState.swift` (236 lines)
  - `Aether/Sources/Agent/AgentExecutionLoop.swift` (496 lines)
  - `Aether/Tests/AgentExecutionLoopTests.swift` (1,078 lines)
* **Files Modified:**
  - `Aether/Sources/Agent/AgentOrchestrator.swift` (additive, backward compatible)
  - `Aether.xcodeproj/project.pbxproj` (added 3 new Swift files)
* **Test Results:**
  - `AgentExecutionLoopTests`: **23 / 23 passed** (1.255s)
  - Full Regression Suite: **283 / 283 passed** (39.606s, 0 failures, 0 regressions)
* **Key Capabilities Delivered & Verified:**
  - Pure Swift 6 actor-isolated cyclic state machine (`AgentExecutionLoopActor`).
  - Explicit and implicit confirmation pipelines with full observation and evaluation integration.
  - Structured cancellation safety via `withTaskCancellationHandler` and serialized actor cancellation cleanup.
  - Interactive confirmation request identity tracking (`activeConfirmationRequestId: UUID`) and tool identity tracking (`activeConfirmationToolName: String`) with stale, mismatched, and duplicate decision protection.
  - Deterministic pre-cancelled task handling with automatic continuation cleanup and zero leaks.
  - Bounded execution circuit breaker (default `maxSteps = 10`), tool execution timeout watchdog, and strict transition validation.
  - Complete decoupling from LLM inference through `AgentInferenceProvider` protocol.
  - Strongly-typed `AgentPhase`, `AgentAction`, `AgentObservation`, `AgentStepRecord`, and `AgentExecutionEvent`.
  - Deterministic state transition validation rejecting illegal phase jumps.
  - Bounded iteration circuit breaker (`maxSteps`, default 10).
  - Cooperative cancellation safety.
  - Interactive confirmation gates via checked continuations.
  - Pluggable `AgentInferenceProvider` abstraction decoupling inference from the execution engine.

---

## 4. Sub-Phase 1.2 Verification Summary

* **Sub-Phase ID:** 1.2
* **Title:** Multi-Step Cyclic Reasoning Engine & Loop Controller
* **Status:** **COMPLETED & VERIFIED**
* **Verification Date:** November 7, 2026
* **Files Created:**
  - `Aether/Sources/Agent/AgentCyclicController.swift` (340 lines)
  - `Aether/Sources/Agent/ProductionAgentInferenceProvider.swift` (396 lines)
  - `Aether/Tests/ProductionAgentInferenceProviderTests.swift` (723 lines)
* **Files Modified:**
  - `Aether/Sources/Agent/AgentOrchestrator.swift` (additive: `createProductionLoop`, `runProductionLoop`, `parseAction`, `<action>` unwrapping)
  - `Aether.xcodeproj/project.pbxproj` (added 3 new Swift files to project and build phases)
* **Test Results:**
  - `ProductionAgentInferenceProviderTests`: **28 / 28 passed** (0.164s)
  - Combined Agent Tests (`AgentExecutionLoopTests` + `ProductionAgentInferenceProviderTests`): **51 / 51 passed** (1.623s)
  - Full Project Regression Suite: **311 / 311 passed** (41.933s, 0 failures, 0 regressions)
* **Key Capabilities Delivered & Verified:**
  - Production-grade `ProductionAgentInferenceProvider` bridging `AgentExecutionLoopActor` with `InferenceService`.
  - Multi-turn conversational history assembly with role alternating assistant thoughts/actions and user/tool observations.
  - Integration with `ContextBudgeter` ensuring strict sliding-window token management preserving system instructions and user goals.
  - Deterministic tag parsing for `<thought>`, `<tool_call>`, `<final_answer>`, `<confirm_tool>`, and `<action>`.
  - Pure, testable, `Sendable` `AgentCyclicController` detecting consecutive identical actions, repeated tool failures, alternating oscillations (A-B-A-B), and thought stagnation.
  - Dynamic self-correction guidance injection into the LLM conversation stream to resolve reasoning loops non-punitively.
  - Safe circuit-breaker cycle termination preventing runaway resource consumption.
  - Strict Swift 6 actor isolation with zero concurrency warnings and cooperative task cancellation.
  - Complete Direct Mode protection and backward compatibility preservation.

---

## 5. Sub-Phase 1.3 Verification Summary

* **Sub-Phase ID:** 1.3
* **Title:** Asynchronous Cancellation, Pause & Human-in-the-Loop Orchestration Hardening
* **Status:** **COMPLETED & VERIFIED**
* **Verification Date:** November 7, 2026
* **Files Created:**
  - `Aether/Tests/AgentLifecycleHardeningTests.swift` (898 lines)
* **Files Modified:**
  - `Aether/Sources/Agent/AgentState.swift` (added `.paused` phase, `AgentResumeCheckpoint` enum with 5 cases, valid transitions)
  - `Aether/Sources/Agent/AgentExecutionLoop.swift` (added `sessionSignal`, `activeOperationSignal`, actor-managed `start()` / `run()`, post-authorization synchronous commit gate, single-winner pause/confirmation resolvers, confirmation watchdog)
  - `Aether/Sources/Agent/Tool.swift` (added `cancellationSignal` property to `ToolExecutionContext`)
  - `Aether/Sources/Agent/NativeTools.swift` (added cancellation checkpoints to `SandboxedFileReaderTool`, `DocumentTextExtractorTool`, and `SystemNotificationTool`)
  - `Aether/Sources/Agent/ToolSecurityGuard.swift` (added testable `setAuthorizationDelay`)
  - `Aether/Sources/Inference/InferenceService.swift` (threaded `cancellationSignal` pass-through to LLM streaming worker)
  - `Aether/Sources/Agent/ProductionAgentInferenceProvider.swift` (forwarded operation-scoped `cancellationSignal` to `InferenceService`)
  - `Aether.xcodeproj/project.pbxproj` (registered `AgentLifecycleHardeningTests.swift`)
* **Test Results:**
  - `AgentLifecycleHardeningTests`: **18 / 18 passed** (0.720s)
  - `AgentExecutionLoopTests`: **23 / 23 passed** (1.336s)
  - `ProductionAgentInferenceProviderTests`: **28 / 28 passed** (0.164s)
  - Combined Agent Subsystem Tests: **69 / 69 passed**
  - Full Project Regression Suite: **329 / 329 passed** (108.032s, 0 failures, 0 regressions across all 15 test suites)
* **Key Invariants Delivered & Verified:**
  1. **Authoritative Session vs. Operation Cancellation Separation:**
     - Session cancellation via `loop.sessionSignal` cancels all in-flight inference, tool execution, and the actor run task permanently.
     - Operation cancellation via `loop.activeOperationSignal` interrupts in-flight inference decode without terminating the agent session or discarding state.
     - Native workers abort prompt processing and token generation immediately via C11 atomic flag (`aether_atomic_flag_set`).
     - Resumption allocates a brand-new uncancelled `CancellationSignal` instance while the prior signal remains aborted.
  2. **Synchronous Tool Dispatch Commit Gate & Deferred Tool Policy:**
     - Common decision gate handles `.authorized`, `.requiresUserConfirmation`, `.denied`, and tool lookup failures.
     - Precedence strictly enforced: Session Cancellation > Pending Pause > Security Outcome.
     - Phase transitions to `.executing` only at the synchronous dispatch commit point with zero intervening awaits.
     - Once committed to execution, tools run to completion (preserving observations and atomic state mutations).
     - Observation recorded exactly once before suspending at pause gate.
  3. **Human-in-the-Loop Confirmation Watchdog & Race Protection:**
     - 60.0s watchdog timer with single-winner atomic continuation resolution.
     - Strict identity checks for `requestId: UUID` and `toolName: String`. Stale or mismatched decisions are safely rejected.
     - External task cancellation and session cancellation while awaiting confirmation abort immediately without leaks.
  4. **Actor-Managed Run Task Lifecycle:**
     - `start() -> Task<AgentState, Never>?` stores active task reference, rejects duplicate start calls (`nil`), and cleans up task reference on exit.
     - `run()` bridges task cancellation to actor `cancel()` via `withTaskCancellationHandler`.
  5. **100% Direct Mode Isolation & Zero Regression:**
     - Zero modifications to `ChatViewModel.swift`, `ChatView.swift`, or direct conversation persistence.
     - All 311 pre-existing tests pass with zero regressions; 18 new lifecycle tests pass deterministically.


---

## 6. Real LLM Tool-Calling Validation & Filesystem Execution Hardening Summary

* **Milestone:** Real LLM Tool-Calling Validation & Filesystem Execution Hardening
* **Status:** **COMPLETED & VERIFIED**
* **Verification Date:** November 7, 2026
* **Host Architecture:** macOS 14.0+, Apple Silicon (`arm64`), Swift 6.0
* **Model Validated:** Qwen 2.5 Coder 7B GGUF (`/Users/asadalishaikh/Desktop/qwen2.5-coder/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463`)
* **Test Suites & Results:**
  - `RealModelToolExecutionTests`: **16 / 16 PASSED** (66.161s)
  - Full Project Regression Suite: **376 / 376 PASSED** (215.353s, 0 failures, 0 regressions)
* **Real-Model Scenarios Validated:**
  - **Test A (Folder Creation on Desktop):** User requested "Create a folder named AetherProjects on my Desktop." $\rightarrow$ Qwen 2.5 Coder 7B parsed the request, emitted `<name>create_folder</name><parameters><path>Desktop/AetherProjects</path></parameters>`, passed through `ToolSecurityGuard` directory validation, created `AetherProjects` on disk, ingested the tool response, and emitted verified natural-language confirmation.
  - **Test B & C (File Creation & Content Writing):** User requested "Create a file named README.txt on Desktop and write a short project description into it." $\rightarrow$ Model proposed and executed `create_file` with content payload, verified non-empty content on disk.
  - **Test D (Directory Listing):** User requested "Show me the files inside Desktop." $\rightarrow$ Model invoked `list_directory`, received structured JSON listing of files.
  - **Test E (Multi-Step Execution):** User requested creating `DemoProject`, adding `README.md` and `notes.txt` $\rightarrow$ Model performed 4 consecutive cyclic turns (`create_folder` $\rightarrow$ `create_file` $\rightarrow$ `create_file` $\rightarrow$ `declareComplete`), creating all folders and files on disk.
  - **Test F (Natural-Language Variations):** User requested "Make a new directory on Desktop called TestDir." $\rightarrow$ Correctly mapped to `create_folder` and executed.
  - **Test G (Missing Information Handling):** Prompted with "Create a folder." $\rightarrow$ Model refused to invent arbitrary folder names/paths and prompted the user for the required folder name and destination.
* **Key Components Hardened:**
  - `AuthorizedDirectoryManager`: Multi-root directory management, read-only roots, desktop resolution without path duplication, sandbox boundary enforcement.
  - `ToolSecurityGuard`: Directory authorization validation, read-only root modification blocks, prompt injection defense, interactive confirmation gates.
  - `ProductionAgentInferenceProvider`: Support for XML `<tool_call>`, bare `<name>/<parameters>`, JSON dictionaries with `"arguments"` / `"parameters"` / `"input"`, JSON arrays, unclosed tag truncation, ReAct syntax, and function-call fallbacks.
  - `ToolRegistry` & `MCPFilesystemServer`: End-to-end MCP JSON-RPC protocol execution over in-memory transport.

---

## 7. Browser & Desktop Application Automation Summary

* **Milestone:** Browser & Desktop Application Automation
* **Status:** **COMPLETED & VERIFIED**
* **Verification Date:** November 7, 2026
* **Host Architecture:** macOS 14.0+, Apple Silicon (`arm64`), Swift 6.0
* **Model Validated:** Qwen 2.5 Coder 7B GGUF (`/Users/asadalishaikh/Desktop/qwen2.5-coder/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463`)
* **Test Suites & Results:**
  - `AutomationIntegrationTests`: **17 / 17 PASSED** (65.196s)
  - Full Project Regression Suite: **393 / 393 PASSED** (175.761s, 0 failures, 0 regressions)
* **Architecture & Capabilities Delivered:**
  1. **Browser Automation Engine (`Aether/Sources/Agent/Automation/`):**
     - Native WebKit engine (`WebKitBrowserAutomationProvider`) running on `@MainActor` with out-of-process isolation.
     - Deterministic mock engine (`MockBrowserAutomationProvider`) for headless CI and isolated unit testing.
     - Full DOM inspection converting active HTML documents into clean semantic Markdown.
     - 15 browser tools conforming to `Tool` protocol:
       - `browser_open`: Navigates to HTTP/HTTPS URLs and extracts page title and description.
       - `browser_get_page_content`: Extracts page content as structured Markdown or raw text with optional character truncation.
       - `browser_get_page_metadata`: Returns URL, title, HTTP status, and description.
       - `browser_find_element`: Discovers elements matching CSS selector, visible text, or ARIA role.
       - `browser_click`: Simulates user click on identified DOM elements.
       - `browser_type`: Enters text into focused or targeted input/textarea controls.
       - `browser_fill_form`: Automatically matches form input keys to IDs, names, and labels.
       - `browser_scroll`: Scrolls viewport up, down, top, or bottom.
       - `browser_go_back` / `browser_go_forward` / `browser_refresh`: Navigates session history and reloads.
       - `browser_get_screenshot`: Captures base64 PNG snapshots or writes images to disk.
       - `browser_list_tabs` / `browser_close_tab`: Coordinates multi-tab sessions.
       - `browser_wait_for_element`: Polls for asynchronous element appearance with bounded timeouts.
  2. **Desktop Application Automation Engine:**
     - Native macOS Accessibility API provider (`NativeDesktopAutomationProvider` & `AccessibilityInspector`) using `AXUIElement` and `NSWorkspace`.
     - In-memory mock desktop provider (`MockDesktopAutomationProvider`) for unit testing without accessibility permission gates.
     - 13 desktop application tools conforming to `Tool` protocol:
       - `app_list_running`: Enumerates active macOS processes and bundle identifiers with optional name filters.
       - `app_get_frontmost`: Identifies current active foreground application.
       - `app_launch`: Launches whitelisted macOS applications or activates existing running instances.
       - `app_get_windows`: Queries application windows, titles, and minimized states.
       - `app_get_accessibility_tree`: Recursively traverses accessibility hierarchy up to configurable depth.
       - `app_find_element`: Discovers UI controls by role, title, or identifier.
       - `app_click`: Performs accessibility press actions (`kAXPressAction`).
       - `app_type_text`: Sets text in focused controls or synthesizes `CGEvent` keystrokes.
       - `app_press_key`: Simulates key events (`return`, `escape`, `tab`, `space`, `up`, `down`, etc.).
       - `app_scroll`: Scrolls accessibility containers vertically.
       - `app_get_element_value` / `app_set_element_value`: Reads and writes element values directly via AX APIs.
       - `app_capture_screenshot`: Captures window screenshots.
  3. **Security, Permission & Injection Protections:**
     - Application Whitelist in `ToolSecurityGuard`: Restricts desktop automation strictly to approved productivity apps (`Finder`, `Safari`, `TextEdit`, `Notes`, `System Settings`, `System Preferences`). Blocks arbitrary process spawning.
     - Browser URL Filtering in `ToolSecurityGuard`: Rejects non-HTTP(S) protocols (`file:`, `javascript:`, `data:`) and AWS/GCP cloud metadata IP ranges (`169.254.169.254`).
     - Prompt Injection Defense: Detects adversarial jailbreaks embedded in untrusted webpage text, tagging extracted content to prevent instruction overrides.
     - macOS Permission Manager (`AutomationPermissionManager`): Authoritative checking of Accessibility (`AXIsProcessTrusted`) and Screen Recording (`CGPreflightScreenCaptureAccess`), generating actionable user instructions and System Settings deep links when permissions are withheld.
  4. **Real LLM Tool Selection & Multi-Step Reasoning:**
     - Verified with Qwen 2.5 Coder 7B GGUF local model.
     - Accurately selects `browser_open` for web browsing requests ("Open the Swift Wikipedia page and extract summary").
     - Accurately selects `app_launch` and `app_get_accessibility_tree` for macOS app control requests ("Open TextEdit and inspect its windows").
     - Synthesizes execution results into natural-language user confirmations.


---

## 8. Tool-Call Argument Generation & Placeholder Hardening Summary

* **Milestone:** Tool-Call Argument Generation & Placeholder Hardening
* **Status:** **COMPLETED & VERIFIED**
* **Verification Date:** November 7, 2026
* **Host Architecture:** macOS 14.0+, Apple Silicon (`arm64`), Swift 6.0
* **Model Validated:** Qwen 2.5 Coder 7B GGUF (`/Users/asadalishaikh/Desktop/qwen2.5-coder/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463`)
* **Test Suite & Verification Results:**
  - `RealModelToolExecutionTests`: **23 / 23 PASSED** (including `testRealModelCreateFolderWithRealArguments` and 6 new deterministic argument tests)
  - Full Project Regression Suite: **400+ / 400+ PASSED** (0 failures, 0 regressions across all suites)
* **Root Causes Identified & Remediated:**
  1. **Prompt Specification Flaw:** `AgentOrchestrator.swift` historically presented generic `<param>value</param>` as the example template in its system prompt, causing smaller models to imitate generic tags instead of named XML parameter tags.
  2. **Schema-Agnostic Tag Extraction:** XML parsing previously treated `<parameters>` purely as generic dictionaries without tool definition schema awareness, causing positional parameter tags to lose their semantic key mapping.
  3. **Absence of Placeholder Path Guardrails:** No defense-in-depth screening existed for hallucinated or generic example paths such as `/path/to/new/folder` or `[path]`.
* **Architecture & Hardening Delivered:**
  1. **Tool Definition Parameter Schema Exposure:**
     - Both `ToolRegistry.formatToolsForPrompt(style: .xmlTags)` and `ProductionAgentInferenceProvider.buildSystemPrompt(tools:)` explicitly inject every tool's parameter names, types, presence (`required` / `optional`), and descriptions.
  2. **Explicit System Prompt Guidance:**
     - Updated prompt examples with concrete tool call demonstrations using `create_folder` with `Desktop/AetherTest` in both XML (`<path>Desktop/AetherTest</path>`) and JSON (`{"name": "create_folder", "arguments": {"path": "Desktop/AetherTest"}}`).
     - Added critical rules prohibiting generic `<param>` / `<parameter>` tags, strictly forbidding placeholder paths (`/path/to/new/folder`, `path/to/...`, `<path>`), and instructing the LLM to ask the user for clarification inside `<final_answer>` when required parameters are missing.
  3. **Schema-Aware XML and JSON Argument Resolution:**
     - `ProductionAgentInferenceProvider.parseXMLParameters`:
       - Extracts named tags (`<path>Desktop/AetherTest</path>`).
       - Extracts attribute-named tags (`<param name="path">Desktop/AetherTest</param>`).
       - Schema-driven positional tag resolution: When generic positional `<param>` tags are emitted, checks against `availableTools`. If the parameter count unambiguously maps to 1 remaining parameter (or 1 remaining required parameter), safely resolves to that parameter name.
       - Rejects ambiguous positional mappings: When a tool has multiple required parameters (e.g. `move_file` requiring `source_path` and `destination_path`), positional parameters are not guessed, leaving them unmapped and triggering strict `SecurityValidationError.missingRequiredParameter`.
     - `ProductionAgentInferenceProvider.parseJSONDictionaryOrArray`:
       - Accepts named dictionary arguments under `"arguments"`, `"parameters"`, or `"input"`.
       - Supports positional JSON arrays if unambiguous against the tool schema.
  4. **Multi-Layer Placeholder Path Shielding:**
     - `ToolSecurityGuard.isPlaceholderPath`: Detects substring patterns (`/path/to/`, `path/to/`, `/your/path/`, `<path>`, `[path]`, `{path}`, `placeholder`, etc.) and exact matches (`/path/to/new/folder`, `/path/to/folder`).
     - `ToolSecurityGuard.validateParameters`: Checks all path-related parameters and throws `SecurityValidationError.placeholderPath`.
     - `ToolSecurityGuard.authorize`: Rejects placeholder paths with `.denied(reason: "Placeholder path '...' is not a valid destination.")`.
     - `AuthorizedDirectoryManager.validateAndResolve`: Throws `SecurityValidationError.placeholderPath` before attempting path resolution.
     - `MCPFilesystemServer`: Checks placeholder paths in all mutating handlers (`handleCreateFolder`, `handleCreateFile`).
  5. **Real-Model End-to-End Validation (`Qwen 2.5 Coder 7B`):**
     - User request: *"Create a folder named AetherTest on my Desktop."*
     - Model Output: Emitted thought and `<tool_call>` with named parameter `<path>Desktop/AetherTest</path>`.
     - Dispatched Arguments: `["path": "Desktop/AetherTest"]`.
     - Tool Execution: Created directory at `~/Desktop/AetherTest` on disk in 0.001033s.
     - Observation Ingested: `[create_folder] Success: {"message": "Folder created successfully: AetherTest", ...}`.
     - Natural Confirmation Emitted: *"Created the folder 'AetherTest' on your Desktop successfully."*
