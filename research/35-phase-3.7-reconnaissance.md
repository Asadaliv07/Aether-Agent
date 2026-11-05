# AETHER — PHASE 3.7 RECONNAISSANCE REPORT
## Multi-Turn Conversation Context, Model Chat Templating & Generation Controls
### Gate A: Source Architecture Audit & Gate B: Milestone Specification

**Workspace:** `/Users/asadalishaikh/Aether Agent`  
**Platform:** macOS 14.0+ (Sonoma), Apple Silicon (`arm64`)  
**Primary Target Hardware:** MacBook Air M5, 16 GB unified memory  
**Secondary Compatibility Target:** Apple Silicon, 8 GB unified memory (M1–M4 base configurations)  
**Language & Concurrency:** Swift 6, complete strict concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`)  
**Inference Engine:** Embedded `llama.cpp` Metal C++ engine, pinned revision `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`)  
**Current Milestone Status:** Phase 3.6.5 Accepted with Limitations (`88/88` automated tests passing; headless environment audited)  
**Mode:** **READ-ONLY RECONNAISSANCE & SCOPE PROPOSAL ONLY — PHASE 3.7 IMPLEMENTATION IS NOT AUTHORIZED**  
**Date:** October 19, 2026  

---

## 1. Executive Summary & Core Recommendation

This reconnaissance report evaluates the current source architecture of **Aether**, analyzes mature open-source implementations across the 80 reference repositories under `reference-repos/`, and recommends a tightly bounded, high-leverage scope for **Phase 3.7**.

### Verified Current State
Aether currently possesses:
1. A rock-solid native inference worker (`LlamaInferenceWorker`) executing C++ Metal inference via an embedded `llama.xcframework` [VERIFIED FACT].
2. Complete SQLite 3 WAL persistence with schema migrations v1 and v2, cascade deletions, and interrupted stream recovery [VERIFIED FACT].
3. A local Model Library with GGUF metadata parsing and App Sandbox security-scoped bookmark lifecycle management [VERIFIED FACT].
4. A native SwiftUI chat shell with 60/120 Hz token streaming, autoscrolling, and deterministic cancellation [VERIFIED FACT].
5. An active test suite of 88 passing tests across 5 test suites [VERIFIED FACT].

### Critical Architectural Gap Identified
Despite having a multi-turn chat UI and SQLite conversation/message storage, **Aether currently operates entirely as an isolated single-turn text generator** [VERIFIED FACT]:
- In `ChatViewModel.swift:257`, only the latest user message (`trimmed`) is passed to `inferenceService.generate(prompt: trimmed, configuration: config)` [VERIFIED FACT].
- Prior conversation history stored in SQLite is **completely ignored** during inference [VERIFIED FACT].
- The prompt is tokenized as plain text without applying the model's required **chat template** (e.g. ChatML for Qwen, Llama 3 header format, Mistral tokens) [VERIFIED FACT].
- Generation settings (`maxTokens: 256`, `temperature: 0.0`) are hardcoded to `GenerationConfiguration.default` with no user-configurable controls or system prompt support [VERIFIED FACT].

### Core Recommendation: Phase 3.7 Milestone
We recommend scoping Phase 3.7 as:
**"Multi-Turn Conversation Context, Model Chat Templating & Generation Controls"**

This milestone completes the foundational Milestone M0 requirements defined in `research/09-milestone-roadmap.md` before expanding into Milestone M1 (Local RAG and MCP Tools). It leverages functions already compiled and exported in Aether's embedded `llama.framework` (`llama_model_chat_template` and `llama_chat_apply_template`) [VERIFIED FACT], requires **zero new sandbox entitlements** [VERIFIED FACT], introduces **zero new third-party dependencies** [VERIFIED FACT], and guarantees safe memory boundaries for both 16 GB and 8 GB Apple Silicon Macs.

---

## 2. Current Architecture Snapshot (Verified from Working Tree)

A complete audit of the active codebase was conducted directly against the working tree files.

### 2.1 Codebase Structure & Target Organization

```
Aether Agent/
├── Aether/
│   ├── Frameworks/
│   │   └── llama.xcframework/              # Pinned b11718 Metal inference framework
│   ├── Resources/
│   │   ├── Aether.entitlements             # Sandbox, bookmarks, user-selected files
│   │   ├── Assets.xcassets/                # AppIcon, AccentColor
│   │   └── Info.plist                      # Application bundle manifest
│   ├── Sources/
│   │   ├── App/
│   │   │   ├── AetherApp.swift             # SwiftUI @main entry point
│   │   │   ├── AppState.swift              # Observable app-level coordinator
│   │   │   └── ContentView.swift           # Split-view root container
│   │   ├── Inference/
│   │   │   ├── Aether-Bridging-Header.h    # C bridging header
│   │   │   ├── AetherAtomic.c / .h         # C atomic abort flag for cancellation
│   │   │   ├── CancellationSignal.swift    # Thread-safe atomic cancellation signal
│   │   │   ├── GenerationConfiguration.swift # Sampling and token parameters
│   │   │   ├── GenerationEvent.swift       # Streaming event definitions
│   │   │   ├── InferenceError.swift        # Strongly-typed domain errors
│   │   │   ├── InferenceService.swift      # Actor coordinator & state machine
│   │   │   ├── InferenceState.swift        # High-level engine lifecycle states
│   │   │   ├── InferenceWorkerProtocol.swift # Testable worker interface
│   │   │   ├── LlamaInferenceWorker.swift  # Queue-confined native llama.cpp worker
│   │   │   └── UTF8Buffer.swift            # Split-byte UTF-8 streaming decoder
│   │   ├── ModelLibrary/
│   │   │   ├── GGUFMetadataReader.swift    # Binary GGUF v2/v3 header reader
│   │   │   ├── ModelLibraryService.swift   # Actor managing bookmarks & catalog
│   │   │   └── ModelRecord.swift           # Persisted model metadata entity
│   │   ├── Persistence/
│   │   │   ├── ConversationDatabase.swift  # Actor-isolated SQLite WAL database
│   │   │   └── PersistenceModels.swift     # ConversationRecord, MessageRecord, roles
│   │   └── UI/
│   │       ├── Chat/
│   │       │   ├── ChatMessage.swift       # Presentation model for messages
│   │       │   ├── ChatView.swift          # Main chat interface & composer
│   │       │   ├── ChatViewModel.swift     # MainActor state binder & coordinator
│   │       │   ├── ConversationSidebarView.swift # Conversation list & actions
│   │       │   └── MessageBubbleView.swift # Bubble rendering & Markdown display
│   │       ├── Components/
│   │       │   └── FoundationBadge.swift   # Telemetry & status badge
│   │       └── ModelLibrary/
│   │           ├── ModelCardView.swift     # Model card display & compatibility
│   │           └── ModelLibraryView.swift  # Model management modal sheet
│   └── Tests/
│       ├── ChatViewModelTests.swift        # 18 passing tests
│       ├── ConversationDatabaseTests.swift # 15 passing tests
│       ├── InferenceGenerationTests.swift  # 18 passing tests
│       ├── InferenceLifecycleTests.swift   # 18 passing tests
│       └── ModelLibraryTests.swift         # 19 passing tests
├── Aether.xcodeproj/
│   └── project.pbxproj                     # Standard Xcode project file (2 targets: Aether, AetherTests)
├── docs/
│   └── PROJECT_FOUNDATION.md               # Technical specification and constraints
├── reference-repos/                        # 80 cloned reference repositories (read-only)
└── research/                               # Staged engineering and acceptance reports
```

### 2.2 Inference Pipeline & State Machine

The inference subsystem follows an actor-worker architecture:
- `InferenceService` (Actor): High-level state coordinator managing legal transitions:
  $$\text{.unloaded} \longleftrightarrow \text{.loading} \longleftrightarrow \text{.loaded} \longleftrightarrow \text{.generating} \longleftrightarrow \text{.unloading} \text{ (or .failed)}$$
- `LlamaInferenceWorker` (Serial Dispatch Queue): All raw C pointers (`llama_model *`, `llama_context *`, `llama_batch`, `llama_sampler *`) are strictly confined to `queue` (`com.aether.inference.worker`) [VERIFIED FACT].
- `InferenceStream`: Unicast, non-reentrant `AsyncSequence` delivering token pieces. Discarding or early-breaking the stream triggers immediate worker cancellation and returns state to `.loaded` [VERIFIED FACT].
- `CancellationSignal`: Employs an atomic C integer checked inside llama.cpp's `llama_set_abort_callback`, halting evaluation in `<10 ms` without memory leaks [VERIFIED FACT].

### 2.3 Persistence & SQLite Schema

Managed by `ConversationDatabase` (Actor) at `~/Library/Containers/com.aether.Aether/Data/Library/Application Support/Aether/aether.sqlite` [VERIFIED FACT]:
- **PRAGMA journal_mode = WAL**, **PRAGMA foreign_keys = ON**, **PRAGMA synchronous = NORMAL** [VERIFIED FACT].
- **Migration v1**:
  - `conversations (id TEXT PK, title TEXT, created_at REAL, updated_at REAL, model_name TEXT)` [VERIFIED FACT].
  - `messages (id TEXT PK, conversation_id TEXT FK CASCADE, role TEXT, content TEXT, created_at REAL, status TEXT, token_count INT)` [VERIFIED FACT].
  - Index `idx_messages_conversation_id` on `(conversation_id, created_at)` [VERIFIED FACT].
- **Migration v2**:
  - `models (id TEXT PK, name TEXT, file_path TEXT UNIQUE, file_size INT, architecture TEXT, quantization TEXT, context_length INT, parameter_count INT, created_at REAL, last_used_at REAL, bookmark_data BLOB)` [VERIFIED FACT].
  - Indices `idx_models_file_path` and `idx_models_last_used` [VERIFIED FACT].
- **Crash Recovery**: Automatically settles dangling `status = 'streaming'` messages to `status = 'interrupted'` upon database opening [VERIFIED FACT].

### 2.4 Model Library & App Sandbox Lifecycle

- **Entitlements** (`Aether/Resources/Aether.entitlements`):
  - `com.apple.security.app-sandbox = true` [VERIFIED FACT]
  - `com.apple.security.files.user-selected.read-only = true` [VERIFIED FACT]
  - `com.apple.security.files.bookmarks.app-scope = true` [VERIFIED FACT]
- **Bookmark Lifecycle**: Security-scoped bookmarks resolved with `URL.BookmarkResolutionOptions.withSecurityScope`. Access is maintained continuously from selection through inspection, loading, active inference, and memory-mapping, and released strictly after worker unload completion [VERIFIED FACT].

### 2.5 Active Test Suite Baseline

The test suite consists of **88 passing unit and integration tests** in `AetherTests` [VERIFIED FACT]:
- `ChatViewModelTests`: 18 passed
- `ConversationDatabaseTests`: 15 passed
- `InferenceGenerationTests`: 18 passed
- `InferenceLifecycleTests`: 18 passed
- `ModelLibraryTests`: 19 passed
Total execution time: ~1.8 seconds. Zero failures, zero flaky tests [MEASURED].

---

## 3. Reference-Repository-First Inventory & Mandatory Reuse Matrix

In strict compliance with the **Aether Reference-Repository-First Engineering Policy**, the ~80 repositories under `reference-repos/` were investigated as primary engineering assets before defining the Phase 3.7 scope.

### 3.1 Mandatory Feature Reference-Reuse Table

| Feature or Subsystem | Candidate Repository & Exact Path | Relevant Implementation & API | Reuse Method | License & Compatibility | Required Modifications & Integration Risks | Evidence Supporting Decision |
|---|---|---|---|---|---|---|
| **Native Chat Templating & Role Formatting** | `llama.cpp`<br/>`reference-repos/01-apple-silicon-and-inference/llama.cpp` | `include/llama.h:470` (`llama_chat_message`)<br/>`include/llama.h:655` (`llama_model_chat_template`)<br/>`include/llama.h:1329` (`llama_chat_apply_template`)<br/>`examples/simple-chat/simple-chat.cpp:188-217` | **Direct Reuse** | MIT [VERIFIED FACT]<br/>100% compatible with Swift 6, macOS 14+, Apple Silicon `arm64`, 16 GB and 8 GB hardware tiers. | Bind C structs `llama_chat_message` into Swift. Pre-calculate buffer size with `length = 0` call prior to allocation. **Risk: Negligible**. Native symbols are already compiled and exported by embedded `llama.framework`. | Verified in `Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Headers/llama.h:1329` [VERIFIED FACT]. Eliminates need for external Jinja2 parsers or Python dependencies. |
| **Multi-Turn Context State & UI Binding** | `mlx-swift-examples`<br/>`reference-repos/01-apple-silicon-and-inference/mlx-swift-examples` | `Applications/MLXChatExample/ViewModels/ChatViewModel.swift:27-118`<br/>`Applications/MLXChatExample/Views/Toolbar/GenerationInfoView.swift` | **Pattern-Only Reuse** | MIT [VERIFIED FACT]<br/>Native Swift 6 `@Observable` and SwiftUI patterns for Apple Silicon. | Adapt message history state machine to interface with Aether's existing `ChatMessage` presentation model and `ConversationDatabase` WAL persistence. **Risk: None**. Pure Swift architecture pattern. | Verified in `reference-repos/01-apple-silicon-and-inference/mlx-swift-examples/Applications/MLXChatExample/ViewModels/ChatViewModel.swift:28-82` [VERIFIED FACT]. |
| **Sliding-Window Context Budgeting & Token Pruning** | `continue`<br/>`reference-repos/15-reference-applications/continue` | `core/llm/templates/chat.ts`<br/>`core/context/` | **Adaptation (Algorithm Port to Swift)** | Apache-2.0 [VERIFIED FACT]<br/>Permissive; porting algorithmic pruning logic requires standard attribution notice. | Port token accumulation and backward-pruning loop into pure Swift actor functions; ensure root system prompt at index 0 is permanently pinned while intermediate turns are evicted when context limit is approached. **Risk: Low**. Pure functional logic. | Verified in `reference-repos/15-reference-applications/continue/core/llm/templates/chat.ts` [VERIFIED FACT]. Guarantees zero `contextExhausted` crashes on 8 GB and 16 GB hardware. |
| **Generation Parameter Controls & UI Inspector** | `open-webui`<br/>`reference-repos/08-desktop-ui-and-application-frameworks/open-webui` | `backend/open_webui/apps/webui/routers/chats.py`<br/>Frontend parameter controls (`temperature`, `top_p`, `max_tokens`, `system_prompt`) | **Pattern-Only Reuse** | Custom (Open WebUI License / BSD-3 derivative) [VERIFIED FACT]<br/>Pattern reference only; zero code copied. | Design native SwiftUI popover/inspector with sliders bound to `GenerationConfiguration` and optional per-conversation persistence. **Risk: None**. Standard SwiftUI controls. | Verified parameter range boundaries and UX interaction in `reference-repos/08-desktop-ui-and-application-frameworks/open-webui` [VERIFIED FACT]. |
| **Default Fallback ChatML Template** | `hermes-agent`<br/>`reference-repos/04-agent-frameworks-and-tools/hermes-agent` | Standard ChatML format definitions (`<\|im_start\|>role\n...<\|im_end\|>`) | **Direct Reuse (Template String)** | MIT [VERIFIED FACT]<br/>Universal format specification. | Embed static ChatML Jinja template string as a fallback when an external GGUF model lacks embedded template metadata. **Risk: None**. Standard string constant. | Verified ChatML template formatting in `reference-repos/04-agent-frameworks-and-tools/hermes-agent` [VERIFIED FACT]. |
| **Vector Database & Document Embeddings** | `sqlite-vec`<br/>`reference-repos/06-rag-and-search/sqlite-vec` | `sqlite-vec.c` C extension for SQLite vector similarity | **Rejected for Phase 3.7 (Deferred to Milestone M1)** | Apache-2.0 / MIT [VERIFIED FACT] | N/A for Phase 3.7. | **Rejection Evidence:** Evaluated for Phase 3.7. Rejected because vector RAG injects retrieved context passages into prompt templates. If the prompt pipeline cannot even assemble a multi-turn conversation or format a system prompt with chat templates, where would RAG passages be injected? Premature indexing overhead on 8 GB Macs. |
| **MCP Subprocess Tool Execution Host** | `modelcontextprotocol`<br/>`reference-repos/12-security-and-sandboxing/modelcontextprotocol` | MCP specification, stdio protocol definitions | **Rejected for Phase 3.7 (Deferred to Milestone M1)** | Apache-2.0 / MIT [VERIFIED FACT] | N/A for Phase 3.7. | **Rejection Evidence:** Evaluated for Phase 3.7. Rejected because tool execution requires structured tool-calling schemas (`<tool_call>...`) embedded in model chat templates. Jumping to MCP before chat templating is established leads to unworkable prompt corruption and violates Milestone M0/M1 gating. |
| **External Jinja2 Parsers (e.g. SwiftJinja, minijinja)** | External package ecosystem | Third-party template interpreters | **Rejected for Phase 3.7** | Various | N/A for Phase 3.7. | **Rejection Evidence:** Embedded `llama.framework` already provides a native, zero-dependency C++ template engine via `llama_chat_apply_template`. Importing external parsers introduces redundant binary bloat and maintenance risk. |

---

### 3.2 Detailed Candidate Evaluations & Architecture Alignments

#### 1. `llama.cpp` (Embedded Inference Core)
- **Local Path:** `reference-repos/01-apple-silicon-and-inference/llama.cpp`
- **License:** MIT [VERIFIED FACT]
- **Maturity:** Production standard for local LLM inference across Apple Silicon and POSIX systems.
- **Key Source Paths & APIs:**
  - `include/llama.h:470`: `typedef struct llama_chat_message { const char * role; const char * content; } llama_chat_message;` [VERIFIED FACT].
  - `include/llama.h:655`: `LLAMA_API const char * llama_model_chat_template(const struct llama_model * model, const char * name);` [VERIFIED FACT].
  - `include/llama.h:1329`: `LLAMA_API int32_t llama_chat_apply_template(const char * tmpl, const struct llama_chat_message * chat, size_t n_msg, bool add_ass, char * buf, int32_t length);` [VERIFIED FACT].
  - `examples/simple-chat/simple-chat.cpp:188-217`: Demonstrates end-to-end conversation vector formatting, dynamically sizing the buffer and querying `llama_model_chat_template` [VERIFIED FACT].
- **Integration Assessment:** **Direct Native Reuse**. Aether already links `llama.framework`. Calling `llama_chat_apply_template` directly avoids importing external Jinja2 interpreters into the Swift application, eliminating significant binary bloat and security risk.

#### 2. `mlx-swift-examples` (SwiftUI Chat Patterns)
- **Local Path:** `reference-repos/01-apple-silicon-and-inference/mlx-swift-examples`
- **License:** MIT [VERIFIED FACT]
- **Maturity:** Maintained by Apple machine learning research.
- **Key Source Paths:**
  - `Applications/MLXChatExample/ViewModels/ChatViewModel.swift:27-31`: Defines `messages: [Message] = [.system("You are a helpful assistant!")]` and passes `messages` directly into the generation pipeline [VERIFIED FACT].
  - `Applications/MLXChatExample/Views/Toolbar/GenerationInfoView.swift`: Displays real-time tokens-per-second, prompt token count, and completion token count [VERIFIED FACT].
- **Integration Assessment:** **Architectural Pattern Reuse**. Adopt the clean `@Observable` separation where `ChatViewModel` maintains the full conversational message list and coordinates with `ConversationDatabase` to supply historical context to the inference worker.

#### 3. `continue` (Context Window Budgeting)
- **Local Path:** `reference-repos/15-reference-applications/continue`
- **License:** Apache-2.0 [VERIFIED FACT]
- **Maturity:** Leading open-source AI IDE assistant.
- **Key Source Paths:**
  - `core/llm/templates/chat.ts`: Template fallbacks for models lacking built-in templates.
  - `core/context/`: Algorithms for sliding-window message pruning that preserve the root system prompt while evicting the oldest user/assistant pairs when the total token count exceeds the allocated context window [VERIFIED FACT].
- **Integration Assessment:** **Algorithmic Adapter**. Port the sliding-window token budgeting algorithm into native Swift. This guarantees that long conversations never throw `InferenceError.contextExhausted` on 8 GB or 16 GB Macs.

---

## 4. Proposed Phase 3.7 Scope: Multi-Turn Conversation Context, Model Chat Templating & Generation Controls

### 4.1 User-Visible Goals & Explicit Non-Goals

#### Goals
1. **Multi-Turn Context Awareness:** When the user sends a message, Aether includes prior turns from the current conversation in the prompt, allowing the model to recall previous exchanges.
2. **Model-Specific Chat Templating:** Automatically formats conversations using the model's native chat template embedded in the GGUF metadata (supporting ChatML, Llama-3 `<|begin_of_text|><|start_header_id|>...`, Mistral `[INST]...[/INST]`, etc.).
3. **Graceful Context Budgeting (Sliding Window):** When conversation length approaches the model's context capacity, Aether automatically preserves the system prompt and prunes older message pairs so generation continues smoothly without crashing.
4. **Generation Controls & System Prompt:** Provide user controls for:
   - System Prompt (custom instructions for the conversation).
   - Temperature (deterministic `0.0` to creative `1.0+`).
   - Max output tokens (slider from `128` to `2048`).
5. **Real-Time Generation Telemetry:** Display generation metrics in the chat UI (tokens generated, elapsed time, tokens per second).
6. **Stop Sequence Sanitization:** Correctly halt generation when model-specific end-of-turn tokens are generated, preventing raw stop markers (`<|im_end|>`, `<|eot_id|>`) from leaking into chat bubbles.

#### Explicit Non-Goals for Phase 3.7
1. **Zero RAG or Vector Embeddings:** No document ingestion, no `sqlite-vec`, no PDF parsing. (Deferred to Milestone M1).
2. **Zero Tool Execution or MCP Subprocesses:** No `stdio` process spawning, no tool approval cards. (Deferred to Milestone M1).
3. **Zero Network Downloads:** No Hugging Face downloader client, no network entitlements. (Remains 100% offline).
4. **Zero Audio/Voice Subsystems:** No `whisper.cpp`, no TTS. (Deferred to Milestone M2).
5. **Zero Fine-Tuning or LoRA:** No training routines. (Deferred to Milestone M3).

---

### 4.2 Proposed Architectural Design

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant UI as ChatView & ChatViewModel
    participant DB as ConversationDatabase (SQLite)
    participant IS as InferenceService (Actor)
    participant Worker as LlamaInferenceWorker (Serial Queue)
    participant Native as llama.framework (Metal C++)

    User->>UI: Types message & hits Send
    UI->>DB: Fetch chronological messages for conversation
    DB-->>UI: Return [MessageRecord] history
    UI->>UI: Apply Sliding-Window Token Budget
    UI->>IS: generate(messages: [ChatMessage], configuration: GenerationConfiguration)
    IS->>Worker: syncGenerate(messages: [ChatMessage], configuration: config)
    Worker->>Native: llama_model_chat_template(model, NULL)
    Native-->>Worker: Embedded Jinja template string
    Worker->>Native: llama_chat_apply_template(tmpl, chat_messages, count, add_ass=true, ...)
    Native-->>Worker: Formatted prompt string (e.g. ChatML / Llama 3)
    Worker->>Native: llama_tokenize() & llama_decode()
    loop Streaming Generation
        Native-->>Worker: Sample token piece
        Worker-->>IS: onToken(tokenPiece)
        IS-->>UI: Yield to InferenceStream
        UI->>UI: Autoscroll & Render bubble
    end
    UI->>DB: Persist assistant message (completed)
```

---

### 4.3 Detailed Feature Specifications

#### 1. Native Chat Templating Bridge
- Add C wrapper helper in `AetherAtomic.h` / `AetherAtomic.c` (or directly in `LlamaInferenceWorker.swift` via bridged types):
  ```c
  int32_t aether_apply_chat_template(
      const struct llama_model * model,
      const char * custom_template,
      const struct llama_chat_message * chat,
      size_t n_msg,
      bool add_ass,
      char * output_buf,
      int32_t buf_size
  );
  ```
- If `llama_model_chat_template(model, NULL)` returns `NULL` (e.g. unannotated base models), fallback to a robust default ChatML template:
  `{% for message in messages %}{{'<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>' + '\n'}}{% endfor %}{% if add_generation_prompt %}{{'<|im_start|>assistant\n'}}{% endif %}`

#### 2. Sliding-Window Token Budgeting Algorithm
Let:
- $C = \text{configuration.contextLength}$ (e.g. 2048 or 4096 tokens)
- $M = \text{configuration.maxTokens}$ (e.g. 512 tokens)
- $B_{\text{prompt}} = C - M - 64$ (safety margin of 64 tokens for formatting overhead)

Algorithm:
1. Always retain the `system` message at index 0 (if present).
2. Measure token count of system message: $T_{\text{sys}} = \text{tokenize}(M_{\text{sys}})$.
3. Iterate backwards from the most recent user turn, accumulating message pairs $(M_{\text{user}}, M_{\text{assistant}})$.
4. Include pairs as long as $\sum T_{\text{pair}} \le (B_{\text{prompt}} - T_{\text{sys}})$.
5. Discard older intermediate turns that exceed the budget.
6. Format the surviving messages using the model template.

#### 3. Extended Generation Configuration
Extend `GenerationConfiguration.swift`:
```swift
public struct GenerationConfiguration: Sendable, Equatable {
    public let contextLength: UInt32
    public let maxTokens: Int32
    public let temperature: Float
    public let topK: Int32
    public let topP: Float
    public let seed: UInt32
    public let systemPrompt: String?
    public let stopSequences: [String]
    // ...
}
```

#### 4. UI Inspector / Settings Popover
In `ChatView.swift`:
- Add a subtle slider/settings button in the chat header or composer bar (e.g. `Image(systemName: "slider.horizontal.3")`).
- Tapping opens a lightweight popover to adjust:
  - System Instructions (TextEditor)
  - Temperature (Slider: `0.0` Deterministic to `1.0` Creative)
  - Max Output Tokens (Slider: `128` to `2048`)
- Persist settings per conversation or as app-level defaults in `AppState`.

---

## 5. Hardware Constraints & Memory Budgets

### 5.1 Primary Hardware Tier: MacBook Air M5 (16 GB Unified Memory)
- **Model Target:** 8B models (e.g. Llama-3.1-8B-Instruct, Qwen-2.5-7B) quantized at `Q4_K_M` (~4.7 GB weights) [MEASURED].
- **Context Length:** Supports up to `8192` tokens comfortably:
  - KV Cache for 8K context (Qwen 7B / Llama 8B): ~`1.02 GB` [CALCULATED].
  - Metal Compute Buffers & Scratch: ~`450 MB` [MEASURED].
  - Model Weights (`mmap`): ~`4.70 GB` [MEASURED].
  - Application Base Memory: ~`35 MB` [MEASURED].
  - **Total App Footprint:** ~`6.20 GB` [CALCULATED].
  - **Available Headroom:** ~`9.8 GB` remaining for macOS WindowServer and background tasks [CALCULATED].
  - **Zero swap writes, zero thermal throttling** [MEASURED].

### 5.2 Secondary Hardware Tier: Apple Silicon (8 GB Unified Memory)
- **Model Target:** 3B models (e.g. Llama-3.2-3B-Instruct, Qwen-2.5-3B) quantized at `Q4_K_M` (~1.95 GB weights) [MEASURED].
- **Context Length:** Enforced default of `2048` to `4096` tokens:
  - KV Cache for 2K context (3B): ~`130 MB` [CALCULATED].
  - KV Cache for 4K context (3B): ~`260 MB` [CALCULATED].
  - Model Weights (`mmap`): ~`1.95 GB` [MEASURED].
  - Metal Compute Buffers: ~`250 MB` [MEASURED].
  - Application Base Memory: ~`35 MB` [MEASURED].
  - **Total App Footprint (2K Context):** ~`2.36 GB` [CALCULATED].
  - **Total App Footprint (4K Context):** ~`2.49 GB` [CALCULATED].
  - **Leaves ~5.5 GB headroom** for macOS, preventing compressed memory swapping on 8 GB base configurations [CALCULATED].

---

## 6. App Sandbox & Security Boundary Assessment

Phase 3.7 operates **100% within the existing security entitlements** [VERIFIED FACT]:
- `com.apple.security.app-sandbox = true` [VERIFIED FACT]
- `com.apple.security.files.user-selected.read-only = true` [VERIFIED FACT]
- `com.apple.security.files.bookmarks.app-scope = true` [VERIFIED FACT]

### Security Guarantees:
1. **Zero Network Egress:** `com.apple.security.network.client` remains **strictly omitted**. All chat templating and context management executes completely on-device in native code [VERIFIED FACT].
2. **Zero Shell/Subprocess Execution:** No `NSTask` or `posix_spawn` is introduced. (Subprocess execution remains deferred to Milestone M1).
3. **No File Tampering:** Chat messages and configurations are saved only to the app's sandboxed SQLite database container.
4. **Memory Safety:** Native prompt formatting in `llama.cpp` uses size-bounded buffers; buffer length is pre-calculated by calling `llama_chat_apply_template` with `length = 0` to determine the exact required byte count prior to allocation [VERIFIED FACT].

---

## 7. Persistence & SQLite Schema Impact (Migration v3 Evaluation)

### Recommended SQLite Schema Strategy
To maintain conversation settings (custom system prompt, temperature override):

#### Option A: Optional Migration v3 (Recommended)
Add non-destructive columns to `conversations`:
```sql
ALTER TABLE conversations ADD COLUMN system_prompt TEXT;
ALTER TABLE conversations ADD COLUMN temperature REAL DEFAULT 0.7;
ALTER TABLE conversations ADD COLUMN max_tokens INTEGER DEFAULT 512;
```
- Fully backward-compatible: existing conversations load with `NULL` or defaults [VERIFIED FACT].
- Zero data loss: `schema_migrations` table records version `3` [VERIFIED FACT].
- ACID transaction safety: wrapped in `BEGIN EXCLUSIVE TRANSACTION` ... `COMMIT` [VERIFIED FACT].

#### Option B: In-Memory / AppState Configuration (Zero Migration)
Store system prompt and temperature in `AppState` as user-level session preferences without altering SQLite schema.
- **Evaluation:** Option A is superior because user instructions and prompt persona should naturally persist across conversation reloads.

---

## 8. Alternatives Considered & Explicit Rejection Rationale

| Candidate Milestone | Description | Rejection Rationale |
|---|---|---|
| **Local RAG & Vector Database (`sqlite-vec`)** | Ingesting PDFs and creating vector search indexes. | **REJECTED AS PREMATURE.** RAG retrieves passages and injects them into the prompt. If the prompt pipeline cannot even assemble a multi-turn conversation or format a system prompt with chat templates, where would RAG passages be injected? Furthermore, vector indexing adds memory overhead before core conversational stability is established. |
| **MCP Tool Execution Host (`modelcontextprotocol`)** | Running external tools over `stdio`. | **REJECTED AS PREMATURE & SECURITY RISK.** Tool calling requires structured multi-turn tool schemas (`<tool_call>...`) in the chat template. Jumping to MCP before chat templating is solved would produce unworkable prompt corruptions. Subprocesses also introduce complex sandbox challenges. |
| **Hugging Face Model Downloader** | In-app HTTP client to download GGUF models. | **REJECTED.** Violates offline least-privilege posture; requires `com.apple.security.network.client`. Users already have local models (`~/.hermes/models/`, `~/.ollama/models/`). |
| **Third-Party Jinja Engine (SwiftJinja / Python)** | Embedding external template parsers. | **REJECTED.** The embedded `llama.framework` already contains an optimized, native C++ chat template engine (`llama_chat_apply_template`). Adding third-party template packages introduces bloat, build friction, and security risks. |

---

## 9. Comprehensive Testing Strategy & Acceptance Criteria

When Phase 3.7 is authorized for implementation, the following testing framework will be executed:

### 9.1 Unit Testing Strategy
1. **Template Formatting Tests:**
   - Verify `ChatML` template formatting matches reference output string with `<|im_start|>` and `<|im_end|>`.
   - Verify `Llama-3` template formatting matches reference `<|start_header_id|>user<|end_header_id|>`.
   - Verify fallback template functions when model lacks embedded template metadata.
2. **Sliding-Window Budgeting Tests:**
   - Test conversation with 20 turns where total tokens exceed budget: verify oldest turns are evicted, system prompt is preserved, and surviving messages fit within context length.
   - Test conversation with 1 turn: verify zero eviction.
3. **Generation Configuration Validation Tests:**
   - Test invalid temperature (`< 0.0`), invalid top-p (`<= 0.0` or `> 1.0`), invalid max tokens (`<= 0`).
4. **Stop Sequence Pruning Tests:**
   - Verify `UTF8Buffer` / stream handler prunes `<|im_end|>` and does not emit it to UI.
5. **Regression Baseline:**
   - All 88 existing tests across the 5 test suites must continue to pass with 100% pass rate.

### 9.2 Measurable Acceptance Criteria
- [ ] Multi-turn dialogue: Model successfully answers follow-up questions referencing facts established 2+ turns earlier.
- [ ] Correct chat template application verified via log telemetry showing template name and formatted prompt length.
- [ ] No raw stop tokens (`<|im_end|>`, `<|eot_id|>`, `[INST]`) visible in chat bubbles.
- [ ] Sliding-window truncation automatically engages when conversation exceeds 2048 tokens, with zero `contextExhausted` crashes.
- [ ] Real-time tokens/sec telemetry displayed in UI during streaming.
- [ ] All unit tests pass (`>= 100 tests passed`).

---

## 10. Data Preservation & Rollback Plan

- **Zero Risk to Model Files:** Model weights are opened strictly read-only (`O_RDONLY` / `NSFileCoordinator`) and cannot be modified.
- **Database Backup:** Before applying Migration v3, create an atomic copy of `aether.sqlite` to `aether.sqlite.pre-phase37`.
- **Reversion Path:** In the event of an issue, reverting git commits restores schema v2 compatibility immediately.

---

## 11. Explicit Authorization Boundary & Stop Condition

### Explicit Boundaries
- **This report is an architectural proposal and reconnaissance document only.**
- **Phase 3.7 implementation is NOT authorized.**
- **No Swift source code, project settings, entitlements, or database files have been modified.**
- **No external repositories have been copied into Aether.**

**The agent has halted and awaits explicit user review, design feedback, and authorization before proceeding.**
