# AETHER — PHASE 3.7 IMPLEMENTATION REPORT
## Multi-Turn Conversation Context, Native Chat Templating, Context Budgeting & Generation Controls

**Project:** Aether  
**Workspace:** `/Users/asadalishaikh/Aether Agent`  
**Reference Repository Collection:** `/Users/asadalishaikh/Aether Agent/reference-repos/`  
**Target Architecture:** Apple Silicon macOS 14.0+ (MacBook Air M5 16 GB primary; 8 GB secondary tier)  
**Date:** October 19, 2026  
**Status:** Completed and Verified under Explicit Phase 3.7 Authorization  

---

## 1. Executive Summary & Authorization Scope

Under explicit user authorization, Phase 3.7 has been designed, implemented, and verified in accordance with the mandatory **Reference-Repository-First Engineering Policy** and strict safety invariants.

### 1.1 Objectives Achieved
1. **Multi-Turn Conversation Context:** Eliminated the architectural limitation where only the single latest user prompt reached inference. Aether now loads chronologically ordered conversation history from `ConversationDatabase`, filters incomplete or failed turns, constructs structured `[PromptMessage]` turns, and submits multi-turn context to the inference engine.
2. **Native Model Chat Templating:** Integrated direct C API calls to `llama_chat_apply_template` and `llama_model_chat_template` from the pinned `llama.framework` (`b11718`, revision `547208dca250ceb3e4c8615598d043f2b602a527`). Implemented two-pass buffer sizing and strict memory ownership (`strdup`/`free`), with architectural fallback verification for ChatML and Llama-3 formats.
3. **Sliding-Window Context Budgeting:** Implemented `ContextBudgeter` adapted algorithmically from Continue (`core/llm/countTokens.ts:compileChatMessages`). Enforces output token reservation (`contextLength - maxTokens`), permanent pinning of index 0 system instructions, and deterministic turn-pair pruning (`(user, assistant)`) from oldest to newest while leaving the persisted SQLite database records 100% unaltered.
4. **Generation Configuration & Controls:** Extended `GenerationConfiguration` to support `systemPrompt`, `temperature`, `maxTokens`, and `stopSequences`. Added a native SwiftUI `GenerationSettingsPopover` accessible from the chat header, plus real-time generation performance metrics (`tok/s`, elapsed seconds).
5. **Database Migration v3:** Applied non-destructive schema migration v3 via SQLite `ALTER TABLE conversations ADD COLUMN ...` adding `system_prompt`, `temperature`, and `max_tokens` columns. Preserved all existing v1 and v2 conversations and messages with default `nil` values.

---

## 2. Architecture: Baseline vs. Final

```
BASELINE ARCHITECTURE (Phase 3.6.5):
User Input ──> ChatViewModel ──> trimmed prompt string ──> InferenceService.generate(prompt:) ──> LlamaInferenceWorker (RAW PROMPT ONLY)

FINAL ARCHITECTURE (Phase 3.7):
User Input
    │
    ▼
ConversationDatabase (SQLite WAL) ──> Fetch chronologically ordered MessageRecords
    │
    ▼
ChatViewModel (Assemble multi-turn [PromptMessage] + resolve per-conversation settings)
    │
    ▼
InferenceService.generate(messages: [PromptMessage], configuration:)
    │
    ├─> ContextBudgeter.budget(messages, contextLength, maxTokens, tokenizer)
    │     ├── Pinned System Instructions (Permanent)
    │     ├── Complete Turn-Pair Pruning (Oldest -> Newest)
    │     └── Output Token Reservation (Context - MaxTokens)
    │
    ├─> ChatTemplateFormatter.apply(template, messages, addAssistantPrompt:)
    │     ├── GGUF Metadata Extraction (llama_model_chat_template)
    │     ├── Two-Pass Sizing Buffer (llama_chat_apply_template)
    │     └── Architecture-Safe Fallbacks (ChatML / Llama-3)
    │
    ▼
LlamaInferenceWorker (Serial Queue com.aether.inference.worker)
    ├── Tokenize Assembled Prompt (llama_tokenize)
    ├── KV Cache Management (llama_decode)
    ├── Incremental Sampler Loop & Stop Sequences Check
    └── Thread-Safe Streaming via UTF8Buffer & CancellationSignal
    │
    ▼
InferenceStream ──> ChatViewModel ──> UI View Updates & Batch Incremental Persistence
```

---

## 3. Reference-Repository Reuse Matrix

In accordance with the mandatory policy, every subsystem inspected candidate reference implementations before code was written.

| Subsystem | Candidate Repository & Source Path | Upstream URL & Revision | License | Reuse Classification | Integration Rationale & Modifications |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Native Model Chat Templating** | `llama.cpp`: `include/llama.h:655,1329`, `src/llama.cpp:510`, `examples/simple-chat/simple-chat.cpp:188` | `https://github.com/ggml-org/llama.cpp.git`<br>`547208dca250ceb3e4c8615598d043f2b602a527` | MIT | **Direct Reuse** | Called `llama_model_chat_template` and `llama_chat_apply_template` directly from the pinned framework. Used two-pass buffer query and safe `strdup`/`free` matching `simple-chat.cpp`. |
| **Context Window Budgeting** | `continue`: `core/llm/countTokens.ts:compileChatMessages` | `https://github.com/continuedev/continue.git`<br>`f91ba05db510cbce09dcb4bf97b10a2bb1285cb8` | Apache 2.0 | **Algorithmic Adaptation** | Ported sliding-window turn-pair pruning into Swift. Guaranteed system instruction permanence (index 0) and output token headroom reservation (`contextLength - maxTokens`). |
| **Conversation History Flow** | `mlx-swift-examples`: `Applications/MLXChatExample/ViewModels/ChatViewModel.swift` | `https://github.com/ml-explore/mlx-swift-examples.git`<br>`004e0e5a9ee9cfc2f0f49ea75f46320a0614ddf9` | MIT | **Pattern-Only Inspiration** | Reused UI binding patterns and message turn lifecycle without adopting MLX dependencies or replacing Aether's SQLite WAL persistence. |
| **Generation Settings UI** | `open-webui`: `src/lib/components/chat/Settings/` | `https://github.com/open-webui/open-webui.git`<br>`8b14a9386cbbefb0c9509df6e680a6d5952d43d9` | MIT | **Pattern-Only Inspiration** | Reused control grouping (Temperature, Max Output Tokens, System Prompt) inside a native SwiftUI popover sheet. |

---

## 4. Source Files Added & Modified

### 4.1 New Source Files
1. `Aether/Sources/Inference/PromptMessage.swift`
   - Immutable, Sendable struct representing individual message turns (`role: String`, `content: String`).
   - Cleanly decoupled from UI ViewModels and SQLite database records.
2. `Aether/Sources/Inference/ChatTemplateFormatter.swift`
   - Swift interface wrapping `llama_chat_apply_template` and `llama_model_chat_template`.
   - Two-pass memory-safe sizing, `strdup`/`free` allocation management, and fallback resolution for ChatML and Llama-3 architectures.
3. `Aether/Sources/Inference/ContextBudgeter.swift`
   - Complete-turn pair sliding-window pruner (`ContextBudgeter.budget`).
   - Enforces output token reservation, pins system prompts, and reports telemetry (`turnsTrimmed`, `totalTokens`, `didPrune`).

### 4.2 New Test Files
1. `Aether/Tests/ChatTemplateFormatterTests.swift`
   - 5 comprehensive unit tests verifying single-turn, multi-turn, Llama-3 fallback, empty message rejection, and unsupported template error handling.
2. `Aether/Tests/ContextBudgeterTests.swift`
   - 7 unit tests verifying token reservation, complete-turn pair pruning, system prompt permanence, over-budget rejection, and 50-turn synthetic conversations.

### 4.3 Modified Files
1. `Aether/Sources/Inference/InferenceWorkerProtocol.swift`
   - Added `getModelChatTemplate() async -> String?`
   - Added `countTokens(for text: String) async throws -> Int`
2. `Aether/Sources/Inference/LlamaInferenceWorker.swift`
   - Implemented `getModelChatTemplate()` via `llama_model_chat_template(model, nil)`.
   - Implemented `countTokens(for:)` via `llama_tokenize(vocab, text, textLen, nil, 0, false, true)`.
   - Added stop sequence evaluation (`configuration.stopSequences`) in token loop.
3. `Aether/Sources/Inference/GenerationConfiguration.swift`
   - Made configuration properties mutable `var`.
   - Added `systemPrompt: String?`, `stopSequences: [String]`, and `.creative` preset.
4. `Aether/Sources/Inference/InferenceService.swift`
   - Implemented `generate(messages: [PromptMessage], configuration: GenerationConfiguration, modelArchitecture: String?) -> InferenceStream`.
   - Coordinated context budgeting, native chat templating, and worker token generation.
   - Exposed `countTokens(for:)` and `getModelChatTemplate()`.
5. `Aether/Sources/Persistence/PersistenceModels.swift`
   - Extended `ConversationRecord` with `systemPrompt: String?`, `temperature: Float?`, and `maxTokens: Int32?`.
6. `Aether/Sources/Persistence/ConversationDatabase.swift`
   - Implemented `applyMigrationV3` adding `system_prompt`, `temperature`, and `max_tokens` columns.
   - Updated `createConversation`, `fetchConversations`, `fetchConversation`, and added `updateConversationSettings`.
7. `Aether/Sources/UI/Chat/ChatViewModel.swift`
   - Assembled chronological `[PromptMessage]` history from database, filtering failed and empty assistant turns.
   - Passed multi-turn context and per-conversation generation configuration to `inferenceService.generate(messages:)`.
   - Added settings properties (`currentSystemPrompt`, `currentTemperature`, `currentMaxTokens`) and `updateCurrentConversationSettings`.
   - Computed real-time performance metrics (`lastTokensPerSecond`, `lastGenerationDurationSeconds`).
8. `Aether/Sources/UI/Chat/ChatView.swift`
   - Added performance metric badge (`tok/s`, duration) in chat header.
   - Added sliders icon opening `GenerationSettingsPopover` for per-conversation settings tuning.
9. `Aether.xcodeproj/project.pbxproj`
   - Registered all new source and test files in `PBXFileReference`, `PBXBuildFile`, `PBXGroup`, and `PBXSourcesBuildPhase`.
10. `Aether/Tests/ConversationDatabaseTests.swift`
    - Added tests for migration v3, default `nil` handling, settings isolation, and connection reopening.
11. `Aether/Tests/ChatViewModelTests.swift`
    - Added multi-turn conversation assembly test and conversation settings isolation test.
12. `Aether/Tests/InferenceGenerationTests.swift` & `Aether/Tests/InferenceLifecycleTests.swift`
    - Updated mock workers to conform to extended `InferenceWorkerProtocol`.

---

## 5. Database Migration Details (Migration v3)

- **Prior Version:** Schema Version 2 (Phase 3.6 catalog persistence).
- **New Version:** Schema Version 3.
- **SQL DDL Applied:**
  ```sql
  ALTER TABLE conversations ADD COLUMN system_prompt TEXT DEFAULT NULL;
  ALTER TABLE conversations ADD COLUMN temperature REAL DEFAULT NULL;
  ALTER TABLE conversations ADD COLUMN max_tokens INTEGER DEFAULT NULL;
  ```
- **Safety & Rollback Verification:**
  - Non-destructive: Existing tables and records are 100% preserved [VERIFIED FACT].
  - Defaults: Unconfigured conversations evaluate to `nil` in Swift and seamlessly use runtime defaults (`temperature: 0.7`, `maxTokens: 2048`, `systemPrompt: nil`) [VERIFIED FACT].
  - Verified across 27 database unit tests in `ConversationDatabaseTests` [MEASURED].

---

## 6. Verification & Test Evidence

### 6.1 Unit & Integration Test Suite
Executed command:
```bash
xcodebuild test -project Aether.xcodeproj -scheme Aether -destination "platform=macOS"
```
**Outcome:** `** TEST SUCCEEDED **` (Exit code: 0) [MEASURED].

| Test Suite | Total Tests | Passed | Failed | Execution Time |
| :--- | :---: | :---: | :---: | :---: |
| `ChatTemplateFormatterTests` | 5 | 5 | 0 | 0.003s |
| `ContextBudgeterTests` | 7 | 7 | 0 | 0.264s |
| `ConversationDatabaseTests` | 27 | 27 | 0 | 0.448s |
| `ChatViewModelTests` | 12 | 12 | 0 | 1.135s |
| `InferenceGenerationTests` | 18 | 18 | 0 | 1.096s |
| `InferenceLifecycleTests` | 18 | 18 | 0 | 12.359s |
| `ModelLibraryTests` | 19 | 19 | 0 | 0.093s |
| **TOTAL** | **106** | **106** | **0** | **15.419s** |

### 6.2 Build Verification

1. **Debug Build:**
   ```bash
   xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Debug -destination "platform=macOS"
   ```
   **Result:** `** BUILD SUCCEEDED **` (Exit code: 0, 0 errors, 0 warnings) [MEASURED].

2. **Release Build:**
   ```bash
   xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Release -destination "platform=macOS"
   ```
   **Result:** `** BUILD SUCCEEDED **` (Exit code: 0, 0 errors, 0 warnings) [MEASURED].

3. **Entitlements & Signing Verification:**
   ```bash
   codesign -d --entitlements :- .../Build/Products/Release/Aether.app
   ```
   **Result:** App Sandbox enabled, App-scope bookmarks enabled, User-selected read-only files enabled, Hardened Runtime disabled for ad-hoc Release per Defect-01 remediation [VERIFIED FACT].

4. **Dynamic Linker Verification:**
   ```bash
   otool -L .../Build/Products/Release/Aether.app/Contents/MacOS/Aether
   ```
   **Result:** Correctly links `@rpath/llama.framework/Versions/Current/llama` and `/usr/lib/libsqlite3.dylib` [VERIFIED FACT].

---

## 7. Hardware & Memory Invariants

- **Primary Hardware Baseline:** MacBook Air M5, 16 GB unified memory.
- **Secondary Hardware Tier:** Apple Silicon Mac, 8 GB unified memory.
- **Context Capacity & OOM Prevention:**
  - Context budgeting strictly reserves `maxTokens` before evaluating prompt text: `availableForPrompt = contextLength - maxTokens`.
  - Oldest complete conversational turns are pruned in pairs until estimated tokens fit within budget.
  - If system prompt + current user turn alone exceed `availableForPrompt`, throws `InferenceError.contextExhausted` safely before native decode, preventing native crash or GPU out-of-memory errors [VERIFIED FACT].
- **Zero In-Memory Duplication:** Conversation messages are queried from SQLite on demand and formatted into a single prompt string immediately before inference.

---

## 8. GUI Verification Status

- **Status:** `NOT VERIFIED — environment limitation`
- **Reason:** The automation agent environment lacks macOS Accessibility permission (`osascript is not allowed assistive access (-1728)`), preventing headless window inspection.
- **Manual GUI Acceptance Checklist for User:**
  1. Launch `Aether.app` from Xcode or DerivedData.
  2. Load a verified local model from the Model Library dropdown in the header.
  3. Send an initial message (e.g., "My favorite color is emerald green.").
  4. Send a follow-up query in the same conversation (e.g., "What is my favorite color?"). Verify the assistant recalls the previous turn.
  5. Click the slider icon (`slider.horizontal.3`) in the header. Update System Instructions (e.g., "Always respond in pirate slang."). Click Save.
  6. Send a new query. Verify the assistant adheres to the updated system instructions.
  7. Verify the header displays the performance badge (e.g., `18.5 tok/s (1.20s)`).
  8. Switch to a second conversation and verify settings remain isolated.

---

## 9. Rollback Instructions

Should it be necessary to revert Phase 3.7 changes:
1. Restore `Aether.xcodeproj/project.pbxproj` from the verified backup:
   ```bash
   cp /Users/asadalishaikh/.gemini/antigravity-ide/brain/35ac1894-9a15-4c7f-a4a2-6970cb20b7b5/scratch/project.pbxproj.pre-phase37 Aether.xcodeproj/project.pbxproj
   ```
2. Remove newly added files:
   ```bash
   rm -f Aether/Sources/Inference/PromptMessage.swift
   rm -f Aether/Sources/Inference/ChatTemplateFormatter.swift
   rm -f Aether/Sources/Inference/ContextBudgeter.swift
   rm -f Aether/Tests/ChatTemplateFormatterTests.swift
   rm -f Aether/Tests/ContextBudgeterTests.swift
   ```
3. Revert modified source files from git or previous milestone backups.

---

## 10. Confirmation of Strict Scope Compliance

- [x] Zero RAG or vector database integration.
- [x] Zero `sqlite-vec` dependencies or schema additions.
- [x] Zero document ingestion or background indexing.
- [x] Zero MCP tool execution or subprocess agents.
- [x] Zero model downloads from the internet.
- [x] Zero production code-signing or entitlement modifications.
- [x] Preserved all user conversation databases and external model files.
- [x] Preserved pinned llama.cpp framework without modification.
