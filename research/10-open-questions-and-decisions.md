# Aether Architecture Governance: Key Decisions & Open Questions

**Date:** October 18, 2026  
**Status:** Validated Governance Review (Phase 2.1 — Awaiting Human Approval)  
**Objective:** Present the pivotal architectural decisions and technical dilemmas that require explicit human approval before any implementation code, scaffolding, or build configuration is generated.

---

## Decision 1: Desktop Application Framework — Native SwiftUI vs. Tauri 2.0

### Context & Dilemma:
The choice of desktop shell determines Aether's idle memory footprint, binary size, native macOS integration, and UI development velocity. Electron has been definitively disqualified due to its 500–1200 MB idle memory overhead `[ESTIMATED]`. The choice is between **Pure Native SwiftUI + AppKit** and **Tauri 2.0 (Rust + WebKit)**.

### Option Comparison:
- **Option A: Pure Native SwiftUI + AppKit (Recommended)**
  - *Pros:* Idle RAM is ~25–35 MB `[ESTIMATED TARGET]`. Direct access to Apple Silicon hardware APIs: Security-Scoped Bookmarks, MenuBarExtra, Keychain Services, Touch ID, and `OSLog`. Flawless macOS user experience and zero web rendering overhead.
  - *Cons:* UI components must be written in Swift; web-based React/Svelte components cannot be reused.
- **Option B: Tauri 2.0 (Rust Core + macOS WebKit)**
  - *Pros:* Idle RAM is ~45–70 MB `[ESTIMATED]`. Allows writing the chat interface in modern web frameworks (React, Svelte, TailwindCSS).
  - *Cons:* Bridging native macOS security-scoped bookmarks and App Sandbox entitlements through Rust FFI into WebKit adds non-trivial complexity. WebKit process introduces additional battery drain compared to native AppKit rendering.

> [!TIP]
> **Research Recommendation: Select Option A (Native SwiftUI + AppKit).**  
> On an 8 GB Mac, saving an additional 30–50 MB and avoiding the WebKit process maximizes memory headroom for the LLM weights and KV cache, while providing a stunning, truly native Apple experience.

**Decision Required:** Approve Native SwiftUI as the primary UI shell, or authorize Tauri 2.0 if web UI component reuse is a hard requirement.

---

## Decision 2: Local Inference Runtime — Embedded llama.cpp vs. Ollama Daemon

### Context & Dilemma:
Aether must run open-weights GGUF models locally on Apple Silicon. The choice is between embedding `llama.cpp` directly in the Aether binary via C FFI, or delegating inference to an external `ollama` daemon over localhost HTTP.

### Option Comparison:
- **Option A: In-Process Embedded `llama.cpp` (Metal C++) (Recommended)**
  - *Pros:* Zero external processes or background daemons `[VERIFIED FACT]`. Cold-start model loads in 300–450 ms `[ESTIMATED TARGET]`. Direct control over Metal memory buffers; immediate token streaming cancellation (<5 ms); absolute zero network socket overhead. Drag-and-drop single `.app` bundle installation.
  - *Cons:* Upstream `llama.cpp` C API changes require maintaining a stable internal wrapper layer.
- **Option B: External Ollama Daemon Integration**
  - *Pros:* Outsources model management and downloads to the popular Ollama CLI. Compatible with existing user Ollama installations.
  - *Cons:* Forces the user to run a separate Go daemon consuming 80–150 MB idle RAM `[ESTIMATED]`. Network socket (port 11434) introduces latency, connection drops, and potential port collisions. Aether cannot directly govern Metal buffer lifetimes during OS memory pressure warnings.

> [!TIP]
> **Research Recommendation: Select Option A (In-Process Embedded `llama.cpp`).**  
> Embed `llama.cpp` directly into `Aether.app` for the primary zero-configuration experience. Provide an optional "External Ollama Provider" toggle in settings for power users who already have an Ollama daemon running.

**Decision Required:** Approve embedded `llama.cpp` as the default engine for M0.

---

## Decision 3: Dual-Engine Sequencing — Introduction of Apple MLX

### Context & Dilemma:
Apple's `mlx` / `mlx-swift` is the premier native framework for Apple Silicon, offering first-class Swift APIs and on-device LoRA adapter fine-tuning. However, GGUF (`llama.cpp`) remains the universal ecosystem standard for quantized inference.

### Option Comparison:
- **Option A: Staged Dual-Engine Strategy (Recommended)**
  - Launch Milestone M0 exclusively with embedded `llama.cpp` to ensure universal GGUF compatibility and maximum stability on 8 GB Macs. Introduce `mlx-swift` in Milestone M3 as a specialized secondary engine for on-device 4-bit LoRA fine-tuning and experimental Apple research models.
- **Option B: Simultaneous Dual-Engine at Launch (M0)**
  - Implement both `llama.cpp` and `mlx-swift` in the initial M0 release.
  - *Risk:* Dramatically increases M0 development scope, binary size, and test matrix before the core product is validated.

> [!TIP]
> **Research Recommendation: Select Option A (Staged Dual-Engine).**  
> Pin M0 strictly to `llama.cpp` behind a clean `InferenceEngineProtocol` abstraction. Add `mlx-swift` in M3 once basic chat, UI, and tool loops are rock-solid.

**Decision Required:** Approve deferring `mlx-swift` integration to Milestone M3.

---

## Decision 4: Vector Storage Architecture & sqlite-vec Fallback

### Context & Dilemma:
Aether requires semantic search for local document RAG. Source inspection revealed that `sqlite-vec` is currently at version `0.1.10-alpha.4` with shadow table linear scans `[VERIFIED FACT]`. The choice is how to structure vector persistence safely.

### Option Comparison:
- **Option A: Abstract `VectorStoreProtocol` with `sqlite-vec` Primary and `LanceDB` Fallback (Recommended)**
  - *Pros:* Preserves single-file SQLite elegance for personal knowledge bases (<20,000 vectors). Isolates all vector operations behind a strict Swift protocol. If `sqlite-vec` encounters pre-1.0 stability issues or query planner bugs, `LanceDB` (embedded Rust columnar format) or `USearch` (C++ header-only) serves as a drop-in fallback without altering application RAG logic `[VERIFIED FACT]`.
  - *Cons:* Requires maintaining a protocol abstraction interface.
- **Option B: Commit Exclusively to `LanceDB` from Day One**
  - *Pros:* Proven production stability for millions of vectors; disk-native columnar format.
  - *Cons:* Splits persistence between SQLite (conversations) and Lance directory (vectors); increases binary size with Rust dependencies.

> [!TIP]
> **Research Recommendation: Select Option A (`VectorStoreProtocol` with `sqlite-vec` default and `LanceDB` fallback).**

**Decision Required:** Approve the `VectorStoreProtocol` abstraction with `sqlite-vec` default and `LanceDB` fallback.

---

## Decision 5: Radical Milestone M0 MVP Scope Approval

### Context & Dilemma:
Should Milestone M0 include document ingestion, vector RAG, and agent tool execution, or should M0 be strictly scoped to the Minimal Viable Core?

### Option Comparison:
- **Option A: Radical M0 Minimal Viable Core (Recommended)**
  - *Included in M0 (Minimal Local-First Chat App):* Native macOS SwiftUI shell with AppKit where justified, single embedded `llama.cpp` Metal engine, local model discovery and management (import/download, integrity checks, disk space checks), SQLite 3 WAL conversation persistence, streaming responses with responsive cancellation, conversation history and navigation, error/recovery states, privacy-first defaults (zero telemetry, no account, no cloud), basic accessibility/keyboard support, and benchmark protocol covering M5 16 GB and 8 GB systems.
  - *Explicitly Deferred from M0:* Vector search / RAG, MCP tool execution, autonomous agent loops, terminal tools, fine-tuning, voice/audio, multimodal workflows, device sync, cloud integrations, and plugin marketplaces.
  - *Pros:* Eliminates vector database indexing risks and subprocess tool security bugs from the initial release. Guarantees that the core conversational engine is rock-solid and verified within 8 GB RAM limits before expanding complexity.
- **Option B: Broad Launch MVP (Including RAG and Tools in M0)**
  - *Pros:* Delivers more features immediately.
  - *Cons:* High probability of launch instability, complex debugging surface, and higher memory pressure on 8 GB Macs.

> [!TIP]
> **Research Recommendation: Select Option A (Radical M0 Minimal Viable Core).**

**Decision Required:** Confirm the radical M0 MVP scope, explicitly deferring RAG and MCP tools to Milestone M1.

---

## Decision 6: Aether Platform Licensing Model

### Context & Dilemma:
Aether's licensing strategy dictates commercial protections and open-source community alignment. The technical dependency audit confirmed that all core embedded components (`llama.cpp`, `sqlite-vec`, `whisper.cpp`, `swift-collections`) are MIT, Apache-2.0, or Public Domain `[VERIFIED FACT]`.

### Option Comparison:
- **Option A: Permissive Open-Core (Apache-2.0 Core + Proprietary Modules) (Recommended)**
  - Core engine, desktop shell, and MCP host released under Apache-2.0. Specialized enterprise sync, custom model adapters, or advanced team collaboration features licensed commercially.
- **Option B: Pure Permissive Open Source (MIT or Apache-2.0)**
  - 100% of the platform released under MIT or Apache-2.0.
- **Option C: Proprietary Commercial Desktop Application**
  - Closed-source commercial binary bundling permissive open-source libraries with standard MIT/Apache attribution notices.

**Decision Required:** Select preferred top-level licensing model for Aether.

---

## Decision 7: Minimum Supported macOS Version & Hardware Baseline

### Context & Dilemma:
Balancing support for older M1 machines against modern macOS developer APIs.

### Option Comparison:
- **Option A: macOS 14.0 Sonoma Baseline with M1–M5 Target Matrix (Recommended)**
  - *Pros:* Supports all M1, M2, M3, M4, and M5 Macs dating back to late 2020. Stable Metal 3 shader runtime, Swift 5.9+ modern concurrency, and mature AppKit/SwiftUI APIs. Covers ~85%+ of active Apple Silicon users.
  - *Hardware Envelope:*
    - **Primary Development & Validation Target:** Apple M5 MacBook Air with 16 GB Unified Memory (Provisional performance targets pending Phase 3 empirical validation).
    - **Secondary Compatibility Tier:** Apple Silicon Macs with 8 GB Unified Memory (M1–M4 Base Configurations — strictly resource-constrained tier with 4B model ceiling and 4K context cap).
    - **Other Supported Hardware Classes:** M1/M2 16 GB, M3/M4 16 GB, and Pro/Max/Ultra (32 GB – 128 GB Unified Memory). M1–M5 are distinct hardware classes.
- **Option B: macOS 15.0 Sequoia Baseline**
  - *Pros:* Unlocks latest Swift 6 language features and Apple Intelligence coexistence hooks.
  - *Cons:* Excludes users on macOS 14 Sonoma who have delayed major OS upgrades.

> [!TIP]
> **Research Recommendation: Set macOS 14.0 Sonoma as the minimum deployment target**, while adopting Swift 6 complete concurrency checking in Xcode 16.

**Decision Required:** Confirm macOS 14.0 Sonoma as the minimum operating system baseline.
