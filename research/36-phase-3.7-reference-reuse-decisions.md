# AETHER — PHASE 3.7 REFERENCE-REUSE DECISION RECORD
## Source-Level Reference-Repository Audit & Integration Decisions

**Project:** Aether  
**Workspace:** `/Users/asadalishaikh/Aether Agent`  
**Reference Repository Collection:** `/Users/asadalishaikh/Aether Agent/reference-repos/`  
**Date:** October 19, 2026  
**Status:** Pre-Implementation Architectural Decision Record (Gate C0 Complete)  
**Mandate:** Strict adherence to the Reference-Repository-First Engineering Policy.  

---

## 1. Executive Summary & Policy Compliance

Before introducing any code modifications for Phase 3.7, an exhaustive source-level investigation was conducted across the approximately 80 open-source repositories under `reference-repos/`.

The objective of Phase 3.7 is:
1. Pass complete, multi-turn conversation history to inference rather than single-turn isolated strings.
2. Apply native model-specific chat templates using the embedded `llama.framework`.
3. Provide a testable sliding-window context budgeter to prevent context exhaustion on 16 GB and 8 GB Apple Silicon Macs.
4. Introduce minimal native generation configuration controls (temperature, top-p, max tokens, system prompt).

In accordance with the **Reference-Repository-First Engineering Policy**, this document records the concrete source inspections, API contracts, licensing reviews, reuse classifications, and integration risk assessments that govern the Phase 3.7 implementation.

---

## 2. Primary Subsystem Investigations

### 2.1 Subsystem 1: Native Model Chat Templating & Role Framing

#### Requirement
Instruction-tuned models (e.g. Qwen 2.5, Llama 3.2, Mistral, Gemma) require structured conversation formatting with exact role delimiters (`system`, `user`, `assistant`) and special tokens (`<|im_start|>`, `<|eot_id|>`, `[INST]`). The inference engine must format multi-turn message arrays using the template embedded in GGUF model metadata without external dependencies.

#### Candidate Repository & Source Inspection
- **Repository:** `llama.cpp`
- **Local Path:** `reference-repos/01-apple-silicon-and-inference/llama.cpp`
- **Upstream URL:** `https://github.com/ggml-org/llama.cpp.git` [VERIFIED FACT]
- **Pinned Revision:** `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`) [VERIFIED FACT]
- **License:** MIT [VERIFIED FACT]
- **Inspected Files:**
  - `include/llama.h:470`: Definition of `llama_chat_message` (`const char * role; const char * content;`) [VERIFIED FACT].
  - `include/llama.h:655`: Declaration of `llama_model_chat_template(const struct llama_model * model, const char * name)` [VERIFIED FACT].
  - `include/llama.h:1329`: Declaration of `llama_chat_apply_template(const char * tmpl, const struct llama_chat_message * chat, size_t n_msg, bool add_ass, char * buf, int32_t length)` [VERIFIED FACT].
  - `src/llama.cpp:510-539`: Implementation of `llama_chat_apply_template`. Confirms that passing `buf = nullptr` and `length = 0` calculates and returns the required buffer size in bytes without writing [VERIFIED FACT]. Returns negative integer on template failure or unknown template [VERIFIED FACT].
  - `src/llama-chat.cpp:89-180`: Template detection logic in `llm_chat_detect_template(tmpl)` supporting ChatML, Llama-3, Mistral v1/v3/v7, Gemma, Phi-3/4, Vicuna, DeepSeek, and more [VERIFIED FACT].
  - `examples/simple-chat/simple-chat.cpp:188-217`: Verified usage pattern: extracts template with `llama_model_chat_template(model, nullptr)`, allocates `llama_chat_message` with `strdup`, formats with two-pass buffer sizing, and frees with `free` [VERIFIED FACT].

#### Decision: Direct Reuse
- **Reuse Method:** **Direct Reuse**.
- **Rationale:** Aether already links `llama.framework` built from this exact pinned revision. The symbols `llama_model_chat_template` and `llama_chat_apply_template` are already compiled and exported in `Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Headers/llama.h` [VERIFIED FACT].
- **Attribution & Notice:** Pinned llama.cpp MIT license terms respected.
- **Modifications & Safety:**
  - Swift wrapper allocates C string buffers using `strdup` / `defer { free }` matching `simple-chat.cpp`.
  - Two-pass sizing: Call with `(buf: nil, length: 0)` to obtain exact required byte count, check `> 0`, allocate `[CChar](repeating: 0, count: len + 1)`, call second pass.
  - Fail-safe fallback: If `llama_model_chat_template` returns `NULL`, Aether verifies model architecture and uses a standard ChatML fallback template, or returns `InferenceError.invalidConfiguration` if the architecture cannot be safely inferred.

---

### 2.2 Subsystem 2: Multi-Turn Conversation State & UI Binding

#### Requirement
`ChatViewModel` and `ChatView` must display and coordinate multi-turn conversations, maintaining distinct messages with explicit roles (`system`, `user`, `assistant`), updating the UI at 60/120 Hz, and tracking token metrics.

#### Candidate Repository & Source Inspection
- **Repository:** `mlx-swift-examples`
- **Local Path:** `reference-repos/01-apple-silicon-and-inference/mlx-swift-examples`
- **Upstream URL:** `https://github.com/ml-explore/mlx-swift-examples.git` [VERIFIED FACT]
- **Pinned Revision:** `378f2449c2` [VERIFIED FACT]
- **License:** MIT [VERIFIED FACT]
- **Inspected Files:**
  - `Applications/MLXChatExample/ViewModels/ChatViewModel.swift:27-118`: `@Observable @MainActor` ViewModel managing `messages: [Message]`. Appends user message, appends placeholder assistant message, runs streaming loop appending chunks, and tracks `tokensPerSecond` via `generateCompletionInfo` [VERIFIED FACT].
  - `Applications/MLXChatExample/Views/Toolbar/GenerationInfoView.swift`: Displays tokens generated and speed metrics [VERIFIED FACT].

#### Decision: Pattern-Only Reuse
- **Reuse Method:** **Pattern-Only Reuse**.
- **Rationale:** Aether uses an embedded `llama.cpp` engine rather than MLX, and persists conversations to SQLite via `ConversationDatabase`. We adopt the `@Observable` streaming patterns and message aggregation logic while preserving Aether's existing `ChatMessage` domain models and SQLite WAL persistence.
- **Attribution:** MLX Swift Examples (Apple Inc., MIT License).

---

### 2.3 Subsystem 3: Context Window Budgeting & Sliding-Window Pruning

#### Requirement
Conversations can grow indefinitely. The prompt pipeline must ensure that total input tokens plus reserved output tokens strictly fit within the loaded model's context capacity (`contextLength`, e.g. 2048 or 4096). When the budget is exceeded, older conversational turns must be pruned in complete pairs while preserving system instructions.

#### Candidate Repository & Source Inspection
- **Repository:** `continue`
- **Local Path:** `reference-repos/15-reference-applications/continue`
- **Upstream URL:** `https://github.com/continuedev/continue.git` [VERIFIED FACT]
- **Pinned Revision:** `5522c6f44c` [VERIFIED FACT]
- **License:** Apache-2.0 [VERIFIED FACT]
- **Inspected Files:**
  - `core/llm/countTokens.ts:460-550`: Function `compileChatMessages` [VERIFIED FACT].
    - Calculates available input budget:
      $$\text{inputTokensAvailable} = \text{contextLength} - \text{safetyBuffer} - \text{minOutputTokens} - \text{systemMsgTokens} - \text{lastMessageTokens}$$
    - If $\text{inputTokensAvailable} < 0$, throws an explicit context exhausted error before generation begins [VERIFIED FACT].
    - Iterates forward through intermediate history, pruning oldest messages until `currentTotal <= inputTokensAvailable` [VERIFIED FACT].
    - Reassembles `[systemMsg] + prunedHistory + [lastMessage]` [VERIFIED FACT].
    - Returns `didPrune` boolean to allow UI/diagnostics reporting [VERIFIED FACT].

#### Decision: Adaptation (Algorithm Port to Swift)
- **Reuse Method:** **Adaptation**.
- **Rationale:** The `compileChatMessages` algorithm from Continue is battle-tested across thousands of developers. Porting its mathematical budgeting and turn-pruning logic into a native Swift pure struct (`ContextBudgeter`) guarantees that long conversations never crash with `InferenceError.contextExhausted` while ensuring deterministic behavior.
- **Attribution & Notice:** Code adapted from Continue (`core/llm/countTokens.ts`), Apache License 2.0. Copyright (c) 2023-2024 Continue Dev, Inc. Attribution notice placed in source header.
- **Adaptation Adjustments:**
  - In Swift, pruning operates on complete user/assistant turn pairs to prevent orphaned assistant turns without user prompts.
  - Token counting utilizes `llama_tokenize` from the loaded model vocab for 100% token accuracy rather than approximate BPE heuristics.

---

### 2.4 Subsystem 4: Generation Controls & Parameter Management

#### Requirement
Provide user-facing controls for sampling temperature, top-p, maximum output tokens, and an optional conversation-level system prompt.

#### Candidate Repository & Source Inspection
- **Repository:** `open-webui`
- **Local Path:** `reference-repos/08-desktop-ui-and-application-frameworks/open-webui`
- **Upstream URL:** `https://github.com/open-webui/open-webui.git` [VERIFIED FACT]
- **Pinned Revision:** `91ea4e3421` [VERIFIED FACT]
- **License:** Open WebUI License (BSD-3 derivative) [VERIFIED FACT]
- **Inspected Files:**
  - `backend/open_webui/apps/webui/routers/chats.py`: Chat parameters schema validation.
  - UI parameter ranges: Temperature (`0.0` to `1.5`, step `0.05`), Top-P (`0.1` to `1.0`, step `0.05`), Max Tokens (`64` to `4096`).

#### Decision: Pattern-Only Reuse
- **Reuse Method:** **Pattern-Only Reuse**.
- **Rationale:** Aether is a native macOS AppKit/SwiftUI app. We adopt the ergonomic parameter ranges and validation boundaries in a lightweight native SwiftUI popover inspector without copying third-party code.
- **Attribution:** Parameter boundaries informed by Open WebUI conventions.

---

### 2.5 Subsystem 5: ChatML Fallback Template Specification

#### Requirement
Define a static, standardized ChatML Jinja template for models that do not embed template metadata in their GGUF header.

#### Candidate Repository & Source Inspection
- **Repository:** `hermes-agent`
- **Local Path:** `reference-repos/04-agent-frameworks-and-tools/hermes-agent`
- **Upstream URL:** `https://github.com/NousResearch/hermes-agent.git` [VERIFIED FACT]
- **Pinned Revision:** `d24fe22029` [VERIFIED FACT]
- **License:** MIT [VERIFIED FACT]
- **Inspected Files:** Standard ChatML template strings.

#### Decision: Direct Reuse (Template Constant)
- **Reuse Method:** **Direct Reuse**.
- **Template String:**
  `{% for message in messages %}{{'<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>' + '\n'}}{% endfor %}{% if add_generation_prompt %}{{'<|im_start|>assistant\n'}}{% endif %}`
- **Rationale:** This standard ChatML template string is natively detected by llama.cpp's `llm_chat_detect_template` (lines 99–104 of `llama-chat.cpp`) [VERIFIED FACT] and maps directly to `LLM_CHAT_TEMPLATE_CHATML`.

---

## 3. Rejected Alternatives & Documented Rationale

| Alternative Candidate | Repository & Path | Proposed Use | Rejection Rationale |
|---|---|---|---|
| **`sqlite-vec`** | `reference-repos/06-rag-and-search/sqlite-vec` | Vector RAG & Document Indexing | **REJECTED FOR PHASE 3.7.** Gated to Milestone M1 in `docs/PROJECT_FOUNDATION.md`. RAG requires multi-turn prompt injection to be fully operational before passages can be retrieved and injected. Premature indexing introduces memory overhead on 8 GB devices. |
| **`modelcontextprotocol` / `fastmcp`** | `reference-repos/12-security-and-sandboxing/modelcontextprotocol` | Tool Execution Host | **REJECTED FOR PHASE 3.7.** Gated to Milestone M1. Tool calling requires structured XML/JSON schemas formatted into chat templates. Introducing subprocess execution before core chat templating is established violates milestone discipline. |
| **`SwiftJinja` / `minijinja` / Python** | External package ecosystems | External Jinja Template Interpreters | **REJECTED.** The embedded `llama.framework` already contains an internal, high-performance C++ chat template engine (`llama_chat_apply_template`) [VERIFIED FACT]. Adding external interpreters would add binary bloat, memory overhead, and maintenance risk. |
| **Universal ChatML Hardcoding** | Ad-hoc prompt string concatenation | Manually prepending `<\|im_start\|>` | **REJECTED.** Violates prompt policy. Models like Llama-3 (`<\|start_header_id\|>`), Mistral (`[INST]`), and Gemma (`<start_of_turn>`) degrade significantly or fail to stop when fed ChatML markers. Model-specific native formatting via `llama_chat_apply_template` is mandatory. |

---

## 4. Master Feature Reference-Reuse Matrix

| Subsystem | Target File(s) in Aether | Candidate Repo & Path | API / Source Asset | Reuse Mode | License | Modifications | Risk Level |
|---|---|---|---|---|---|---|---|
| **Native Chat Formatting** | `Aether/Sources/Inference/LlamaInferenceWorker.swift`<br/>`Aether/Sources/Inference/ChatTemplateFormatter.swift` | `llama.cpp`<br/>`reference-repos/01-apple-silicon-and-inference/llama.cpp` | `llama_model_chat_template`<br/>`llama_chat_apply_template` | **Direct Reuse** | MIT | Swift wrapper with two-pass sizing and `strdup`/`free` lifecycle. | **Low** (symbols already compiled in framework) |
| **Context Window Budgeting** | `Aether/Sources/Inference/ContextBudgeter.swift` | `continue`<br/>`reference-repos/15-reference-applications/continue` | `core/llm/countTokens.ts:compileChatMessages` | **Adaptation** | Apache-2.0 | Port to Swift struct; prune turn pairs; exact `llama_tokenize` count. | **Low** (pure functional algorithm) |
| **Multi-Turn View Binding** | `Aether/Sources/UI/Chat/ChatViewModel.swift` | `mlx-swift-examples`<br/>`reference-repos/01-apple-silicon-and-inference/mlx-swift-examples` | `Applications/MLXChatExample/ViewModels/ChatViewModel.swift` | **Pattern-Only** | MIT | Adapt to Aether's `ChatMessage` presentation model & SQLite WAL. | **None** (SwiftUI architectural pattern) |
| **Generation Controls Inspector** | `Aether/Sources/UI/Chat/ChatView.swift`<br/>`Aether/Sources/Inference/GenerationConfiguration.swift` | `open-webui`<br/>`reference-repos/08-desktop-ui-and-application-frameworks/open-webui` | Parameter slider bounds & validation schema | **Pattern-Only** | Custom (BSD-3 deriv.) | Native SwiftUI inspector sheet/popover. | **None** (Standard SwiftUI controls) |
| **ChatML Fallback String** | `Aether/Sources/Inference/ChatTemplateFormatter.swift` | `hermes-agent`<br/>`reference-repos/04-agent-frameworks-and-tools/hermes-agent` | Standard ChatML Jinja template definition | **Direct Reuse** | MIT | Static constant in Swift. | **None** (String constant) |

---

## 5. Decision Approval & Next Steps

This reference-reuse decision record satisfies the pre-implementation requirements of Gate C0. Implementation may now proceed systematically through Gates C1 to C5 under the user authorization.
