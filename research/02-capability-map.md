# Aether: Comprehensive 21-Capability Map

**Document:** Capability Map & Technical Specifications  
**Status:** Validated Architecture Specification (Phase 2.1 — Awaiting Human Approval)  
**Target Hardware:**  
- **Primary Development & Validation Target:** Apple M5 MacBook Air with 16 GB Unified Memory (Provisional performance targets pending Phase 3 empirical validation)  
- **Secondary Compatibility Tier:** Apple Silicon Macs with 8 GB Unified Memory (M1–M4 Base Configurations — strictly resource-constrained tier)  
- **Other Supported Hardware Classes:** M1/M2 16 GB, M3/M4 16 GB, and Pro/Max/Ultra (32 GB – 128 GB Unified Memory). M1 through M5 represent distinct performance tiers.  

---

## 1. Capability Breakdown & Staged Milestone Matrix

To ensure that Aether ships as a rock-solid, focused desktop product rather than an over-engineered prototype, capabilities are strictly partitioned into release milestones. **Milestone 0 (Launch MVP)** contains only the minimal capabilities required to prove the core local AI value proposition.

| # | Capability Name | Primary Layer | Release Phase | Primary Recommended Technology | Launch Status |
|---|-----------------|---------------|---------------|--------------------------------|:---:|
| 1 | Local Model Discovery & Management | Model Lifecycle | **Milestone 0 (Core MVP)** | In-process GGUF header parser + Local Cache | **M0 Essential** |
| 2 | Model Downloads, Verification & Storage | Model Lifecycle | **Milestone 0 (Core MVP)** | Apple `URLSession` + SHA-256 + Atomic rename | **M0 Essential** |
| 3 | Inference Engines & Model Execution | Runtime Core | **Milestone 0 (Core MVP)** | Embedded `llama.cpp` Metal C FFI | **M0 Essential** |
| 4 | Model Routing & Provider Abstraction | Runtime Core | **Milestone 0 (Core MVP)** | Swift `InferenceEngineProtocol` Actor | **M0 Essential** |
| 5 | Chat, Streaming & Conversation History | Application | **Milestone 0 (Core MVP)** | SwiftUI streaming view + SQLite 3 WAL | **M0 Essential** |
| 6 | Agent Loops, Planning, Tools & Subagents | Intelligence | **Milestone 1 (Tools)** | Deterministic Swift Actor State Graph | *Deferred to M1* |
| 7 | Skills & Controlled Tool Extensions | Extensibility | **Milestone 1 (Tools)** | Model Context Protocol (MCP) over `stdio` | *Deferred to M1* |
| 8 | Long-Term Memory & Context Management | Memory | **Milestone 3 (Adapt)** | SQLite relational memory graph (`mem0` pattern) | *Deferred to M3* |
| 9 | Document Ingestion & Parsing | RAG & Knowledge | **Milestone 1 (RAG)** | Native Apple `PDFKit` (Text & Layout) | *Deferred to M1* |
| 10 | Embeddings, Reranking & Search | RAG & Knowledge | **Milestone 1 (RAG)** | `VectorStoreProtocol` (`sqlite-vec` / `LanceDB`) | *Deferred to M1* |
| 11 | Projects & Persistent Workspaces | Productivity | **Milestone 1 (RAG)** | SQLite project schema + Security-Scoped Bookmarks | *Deferred to M1* |
| 12 | Terminal & Developer Tools | Extensibility | **Milestone 1 (Tools)** | Sandboxed `Process` execution + Human Gate | *Deferred to M1* |
| 13 | Workflow Automation & Scheduling | Automation | **Milestone 4 (Future)** | Native macOS `NSBackgroundActivityScheduler` | *Deferred to M4* |
| 14 | Multimodal Input, Vision & Audio | Multimodal | **Milestone 2 (Voice)** | Embedded `whisper.cpp` + `silero-vad` + `AVSpeech` | *Deferred to M2* |
| 15 | Fine-Tuning & Model Adaptation | Intelligence | **Milestone 3 (Adapt)** | `mlx-swift` LoRA / QLoRA on Apple Metal | *Deferred to M3* |
| 16 | Local APIs & Integrations | Interop | **Milestone 1 (RAG)** | Localhost HTTP / Unix Domain Sockets | *Deferred to M1* |
| 17 | UI & Native macOS Integration | Desktop Shell | **Milestone 0 (Core MVP)** | Native SwiftUI + AppKit + MenuBarExtra | **M0 Essential** |
| 18 | Permissions, Sandboxing & Secrets | Security | **Milestone 0 (Core MVP)** | macOS App Sandbox + Keychain Services | **M0 Essential** |
| 19 | Logging, Observability & Evaluation | Reliability | **Milestone 0 (Core MVP)** | Apple Unified Logging (`OSLog`) | **M0 Essential** |
| 20 | Checkpoints, Recovery & Rollback | Reliability | **Milestone 0 (Core MVP)** | SQLite WAL transactional rollback | **M0 Essential** |
| 21 | Updates, Migration & Data Portability | Lifecycle | **Milestone 1 (RAG)** | PRAGMA user_version migrations + JSON Export | *Deferred to M1* |

---

## 2. Detailed Technical Specifications for All 21 Capabilities

```
================================================================================
CAPABILITY 01: Local Model Discovery and Management
================================================================================
```
- **Purpose & User-Facing Workflows:** Enables users to view installed models, browse verified open-weights models (Llama 3.2, Qwen 2.5, Phi 3.5, Mistral), inspect model parameter sizes, quantization levels (`Q4_K_M`, `Q5_K_M`, `Q8_0`), context window capabilities, and physical RAM footprint.
- **Functional Requirements & Acceptance Criteria:**
  - Automatic scan of local model directories (`~/Library/Application Support/Aether/models/`) on launch.
  - Display physical memory safety indicator based on current system RAM (Green: fits easily; Yellow: high memory pressure; Red: exceeds safe UMA limit).
  - Ability to rename, tag, inspect metadata (author, base model, license), and delete model files.
- **Relevant Repositories & Documentation:**
  - [`huggingface_hub`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/02-model-formats-and-model-hubs/huggingface_hub), [`llama.cpp` GGUF metadata reader](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/llama.cpp).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* In-process GGUF header parser in Swift/C reading GGUF metadata keys directly `[VERIFIED FACT]`.
  - *Alternative:* Querying an external Ollama daemon via `/api/tags` (rejected for core: introduces external process dependency).
- **Integration Points & Dependencies:** Storage Layer (Capability 2), Inference Engine (Capability 3), UI (Capability 17).
- **macOS / Apple Silicon Compatibility:** 100% native ARM64.
- **Memory & Resource Budget:**
  - *8 GB Compatibility Tier:* Limit display to models $\le 4\text{B}$ parameters by default; flag 8B models as requiring 16 GB RAM.
  - *16 GB Baseline (M1–M5):* Support 3B–9B models; flag 14B–32B models.
- **Privacy & Security Risks:** Model directory scanning must be restricted to designated sandbox containers to prevent scanning unauthorized user drives.
- **Licensing:** Fully permissive (Apache-2.0 / MIT).
- **Testing & Benchmarking:** Verify GGUF header parsing on 50+ corrupted/truncated files without crash.
- **Open Questions & Human Decision:** Should Aether bundle an offline curated list of recommended models, or fetch dynamically from Hugging Face API when online? *(Recommended: offline bundled list with optional refresh)*.
- **Delivery Milestone:** **Milestone 0 (Core MVP)**.

```
================================================================================
CAPABILITY 02: Model Downloads, Verification, Caching, and Storage
================================================================================
```
- **Purpose & User-Facing Workflows:** Reliable, resumeable download of multi-gigabyte GGUF model files from Hugging Face Hub with progress tracking, pause/resume, SHA-256 integrity checks, and disk space pre-allocation.
- **Functional Requirements & Acceptance Criteria:**
  - Pre-flight check verifying available free disk space $> \text{model size} \times 1.2$.
  - Resumable downloads via HTTP range requests using Apple `URLSessionDownloadTask`.
  - Background completion: downloads continue when app window is closed.
  - Cryptographic verification: compute SHA-256 hash against upstream checksum before marking model usable.
  - Atomic move from temporary download file to permanent models directory upon verification.
- **Relevant Repositories & Documentation:**
  - [`huggingface_hub`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/02-model-formats-and-model-hubs/huggingface_hub), [Apple URLSession Documentation](https://developer.apple.com/documentation/foundation/urlsession).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native Swift `URLSessionDownloadDelegate` with background configuration.
  - *Alternative:* Python `huggingface_hub.hf_hub_download` (rejected: requires Python runtime in core).
- **Integration Points & Dependencies:** Filesystem, macOS NotificationCenter, Keychain (optional Hugging Face token for gated models like Llama 3.1).
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:**
  - Streaming SHA-256 calculation chunked in 4 MB blocks: RAM usage $< 20\text{ MB}$ during hashing `[CALCULATED]`.
- **Privacy & Security Risks:** Prevent directory traversal attacks in download filenames; enforce HTTPS only; zero analytics sent to Hugging Face.
- **Licensing:** Standard Foundation framework (Apple proprietary SDK) + MIT/Apache-2.0.
- **Testing & Benchmarking:** Test resume behavior under interrupted network conditions and disk-full scenarios.
- **Open Questions & Human Decision:** Support private/gated model downloads requiring Hugging Face user tokens? *(Recommended: Yes, securely stored in macOS Keychain)*.
- **Delivery Milestone:** **Milestone 0 (Core MVP)**.

```
================================================================================
CAPABILITY 03: Inference Engines and Model Execution
================================================================================
```
- **Purpose & User-Facing Workflows:** Loads model weights into unified memory, evaluates user prompt tokens, and streams response tokens in real-time with sub-millisecond latency and immediate cancellation.
- **Functional Requirements & Acceptance Criteria:**
  - Physical memory budgeting: 100% of active weights allocated as resident physical RAM `[VERIFIED FACT]`.
  - Low cold-start load time ($< 400\text{ ms}$ for 3B, $< 750\text{ ms}$ for 8B models on NVMe SSD) `[ESTIMATED TARGET]`.
  - Configurable generation parameters: temperature, top-p, top-k, repetition penalty, stop tokens.
  - Interruptible token generation (cancel button aborts within 10 ms) `[VERIFIED FACT]`.
  - Automatic prompt evaluation caching (reusing common system prompt KV caches).
- **Relevant Repositories & Documentation:**
  - [`llama.cpp`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/llama.cpp), [`mlx`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/mlx), [`mlx-swift`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/mlx-swift), [`ggml`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/02-model-formats-and-model-hubs/ggml).
- **Candidate Technologies & Alternatives:**
  - *Primary Recommendation (M0):* `llama.cpp` embedded via C FFI with Metal Performance Shaders enabled.
  - *Secondary Recommendation (M3):* `mlx-swift` for experimental MLX architectures and on-device LoRA adaptation.
- **Integration Points & Dependencies:** Metal framework, Accelerate framework, Swift Concurrency (`AsyncThrowingStream`).
- **macOS / Apple Silicon Compatibility:** Fully optimized for Apple Silicon Metal 3 shaders and unified memory.
- **Physical Memory & Resource Budget:**
  - *8 GB Compatibility Tier:* Llama-3.2-3B Q4_K_M (1.95 GB weights) + 4K KV cache (0.26 GB) + Metal context (0.25 GB) = **~2.46 GB inference allocation**. Combined with macOS (3.2 GB) = **~5.7 GB total**. Leaves ~2.3 GB safe margin before disk swap.
  - *16 GB Baseline (M1–M5):* Llama-3.1-8B Q4_K_M (4.70 GB weights) + 8K KV cache (1.02 GB) + Metal context (0.45 GB) = **~6.17 GB inference allocation**. Combined with macOS (3.8 GB) = **~10.0 GB total**. Leaves ~6.0 GB safe headroom.
- **Privacy & Security Risks:** Buffer overruns in custom C/C++ kernels. Mitigate by building with stack canaries, address sanitizer in CI, and sandboxing.
- **Licensing:** MIT License (`llama.cpp`, `mlx-swift`).
- **Testing & Benchmarking:** Benchmark tokens/sec and TTFT across M1, M2, M3, M4, and projected M5 hardware.
- **Open Questions & Human Decision:** Run `llama.cpp` directly in-process or inside an isolated XPC service process? *(Recommended: In-process for M0 MVP simplicity, evaluate XPC service in M1 for crash isolation)*.
- **Delivery Milestone:** **Milestone 0 (Core MVP)**.

```
================================================================================
CAPABILITY 04: Model Routing and Provider Abstraction
================================================================================
```
- **Purpose & User-Facing Workflows:** Provides a unified interface allowing the user to seamlessly switch between local embedded models (GGUF via llama.cpp, MLX via mlx-swift), local background daemons (Ollama, LM Studio), and optional remote providers (OpenAI, Anthropic) using the exact same chat workflows.
- **Functional Requirements & Acceptance Criteria:**
  - Swift `InferenceEngineProtocol` protocol providing `generate(prompt:parameters:) -> AsyncThrowingStream<GenerationToken, Error>`.
  - Dynamic fallback: if a local model fails or runs out of VRAM, report clear diagnostics to the user without crashing.
  - Per-model configuration overrides (context window limit, default temperature, system prompt).
- **Relevant Repositories & Documentation:**
  - [`ollama`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/03-serving-and-runtime-comparison/ollama), [`continue`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/15-reference-applications/continue).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Custom Swift Actor implementing engine multiplexing.
- **Integration Points & Dependencies:** Core Engine, Keychain (API keys for optional cloud providers).
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Zero overhead ($< 1\text{ MB}$ RAM).
- **Privacy & Security Risks:** Accidental data leakage: remote provider calls must be disabled by default and require explicit per-request or per-project opt-in.
- **Licensing:** Permissive (MIT / Apache-2.0).
- **Testing & Benchmarking:** Mock network providers and test stream cancellation, timeouts, and reconnection logic.
- **Open Questions & Human Decision:** Confirm that external cloud providers are disabled by default with strict privacy warnings? *(Recommended: Yes)*.
- **Delivery Milestone:** **Milestone 0 (Core MVP)**.

```
================================================================================
CAPABILITY 05: Chat, Streaming, and Conversation History
================================================================================
```
- **Purpose & User-Facing Workflows:** Delivers a fluid, responsive chat UI featuring instant token-by-token rendering, markdown parsing, syntax-highlighted code blocks with one-click copy, conversation branching, message editing, and search across past chats.
- **Functional Requirements & Acceptance Criteria:**
  - Sub-16ms UI frame rate (60/120 Hz ProMotion) during active token generation `[ESTIMATED TARGET]`.
  - Immediate token stream cancellation via UI cancel button (`< 10 ms`).
  - Native SQLite 3 persistence in Write-Ahead Logging (WAL) mode.
  - Search conversation history by keyword via SQLite full-text search.
- **Relevant Repositories & Documentation:**
  - [`open-webui`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/08-desktop-ui-and-application-frameworks/open-webui), [`anything-llm`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/08-desktop-ui-and-application-frameworks/anything-llm), [`sqlite`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/07-data-and-storage/sqlite).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native SwiftUI views with backpressure-aware `AsyncStream` token binding.
- **Integration Points & Dependencies:** Inference Engine (Capability 3), SQLite Storage (Capability 20).
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Active chat UI consumes ~25–35 MB RAM `[ESTIMATED TARGET]`.
- **Privacy & Security Risks:** Conversations stored unencrypted if disk is unencrypted. Mitigate by documenting FileVault requirement; offer optional SQLCipher database encryption.
- **Licensing:** Native proprietary implementation + Public Domain SQLite.
- **Testing & Benchmarking:** Stress test with 10,000 messages in conversation history; verify instant scroll performance.
- **Open Questions & Human Decision:** Enable conversation branching (editing past messages) in M0? *(Recommended: Yes, basic tree schema in SQLite)*.
- **Delivery Milestone:** **Milestone 0 (Core MVP)**.

```
================================================================================
CAPABILITY 06: Agent Loops, Planning, Tools, and Subagents
================================================================================
```
- **Purpose & User-Facing Workflows:** Autonomous problem-solving where an agent plans multi-step tasks, invokes local tools, evaluates results, corrects errors, and summarizes findings for the user.
- **Functional Requirements & Acceptance Criteria:**
  - Deterministic Swift Actor state machine (Think -> Tool Call -> Approval Gate -> Tool Exec -> Evaluate).
  - Maximum 5 consecutive autonomous tool turns before requiring user re-engagement.
  - Atomic state checkpointing after every step, allowing user step rewind.
- **Relevant Repositories & Documentation:**
  - [`pydantic-ai`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/04-agent-frameworks-and-tools/pydantic-ai), [`langgraph`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/04-agent-frameworks-and-tools/langgraph), [`hermes-agent`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/04-agent-frameworks-and-tools/hermes-agent).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native Swift Actor state machine implementing graph transitions.
- **Integration Points & Dependencies:** Inference Engine (Capability 3), Tool Gateway (Capability 7), Storage Checkpoints (Capability 20).
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** State graph coordination overhead $< 5\text{ MB}$ RAM.
- **Privacy & Security Risks:** Autonomous infinite loops or destructive actions. Mitigated by circuit breakers and human approval gates.
- **Licensing:** Permissive (MIT / Apache-2.0 patterns).
- **Testing & Benchmarking:** Test recovery from malformed tool call arguments across small 3B/8B models.
- **Delivery Milestone:** **Milestone 1 (Extensible Tools & Developer Assistant)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 07: Skills and Controlled Tool Extensions (MCP)
================================================================================
```
- **Purpose & User-Facing Workflows:** Connects Aether to external tools, data sources, and APIs using the standardized Model Context Protocol (MCP).
- **Functional Requirements & Acceptance Criteria:**
  - Full MCP Host implementation over unidirectional `stdio` POSIX pipes.
  - Dynamic discovery of tools via `tools/list` and execution via `tools/call`.
  - Human-in-the-Loop Gateway intercepting every mutating or shell action.
- **Relevant Repositories & Documentation:**
  - [`modelcontextprotocol`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/12-security-and-sandboxing/modelcontextprotocol), [`fastmcp`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/12-security-and-sandboxing/fastmcp).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native Swift MCP client communicating with child processes over `stdio`.
- **Integration Points & Dependencies:** Security Gateway (Capability 18), Subprocess Supervisor.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** MCP host overhead $< 10\text{ MB}$; child processes budgeted independently.
- **Security Reality Check:** Subprocess isolation prevents memory corruption of the host app, but does *not* prevent side-effect damage if a tool has filesystem write or shell permissions. Enforce pre-execution argument validation and path traversal guards.
- **Licensing:** Apache-2.0 (`modelcontextprotocol`).
- **Testing & Benchmarking:** Test subprocess crash recovery when a tool server throws an unhandled exception or terminates unexpectedly.
- **Delivery Milestone:** **Milestone 1 (Extensible Tools & Developer Assistant)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 08: Long-Term Memory and Context Management
================================================================================
```
- **Purpose & User-Facing Workflows:** Retains persistent facts, preferences, and project context across sessions without manual prompt re-entry.
- **Functional Requirements & Acceptance Criteria:**
  - Automated extraction of user facts (e.g., "User prefers Swift 6 syntax") into relational SQLite tables.
  - Semantic retrieval of relevant memories based on user prompt similarity.
  - Transparent memory inspection UI allowing users to view, edit, or delete any stored fact.
- **Relevant Repositories & Documentation:**
  - [`mem0`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/05-memory-and-context/mem0), [`graphiti`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/05-memory-and-context/graphiti).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Local relational SQLite tables with vector embeddings (`mem0` pattern).
- **Integration Points & Dependencies:** SQLite Database (Capability 20), Vector Store (Capability 10).
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Negligible ($< 5\text{ MB}$ RAM).
- **Privacy & Security Risks:** Accidental retention of sensitive credentials in memory. Mitigate via secret scanner scrubbing facts prior to insertion.
- **Licensing:** Apache-2.0.
- **Delivery Milestone:** **Milestone 3 (Adaptation & Advanced RAG)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 09: Document Ingestion and Parsing
================================================================================
```
- **Purpose & User-Facing Workflows:** Ingests local documents (PDF, Markdown, TXT, CSV, source code) into text chunks for local search and question answering.
- **Functional Requirements & Acceptance Criteria:**
  - High-speed local PDF parsing extracting text, headers, and basic layout without external network services.
  - Content-aware recursive text chunking (500–1,000 tokens with 10% overlap).
  - Source citation tracking: answers link back to exact page numbers and snippet highlights.
- **Relevant Repositories & Documentation:**
  - [Apple PDFKit Documentation](https://developer.apple.com/documentation/pdfkit), [`docling`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/14-document-processing/docling), [`PyMuPDF`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/14-document-processing/PyMuPDF).
- **Candidate Technologies & Alternatives:**
  - *Recommended (M1):* Native Apple `PDFKit` for memory-safe, zero-license-risk text extraction.
  - *Secondary (M3):* Out-of-process `Docling` helper for complex table and mathematical formula extraction.
  - *Disqualified:* `PyMuPDF` (GPL-3.0 copyleft hazard prevents linking into core).
- **Integration Points & Dependencies:** Vector Store (Capability 10), Storage (Capability 20).
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** PDFKit text parsing consumes $< 50\text{ MB}$ RAM per document `[ESTIMATED]`.
- **Privacy & Security Risks:** Indirect prompt injection embedded inside untrusted PDF files. Mitigate by isolating retrieved text in strict `<retrieved_context>` XML wrappers.
- **Licensing:** Apple SDK (PDFKit) / MIT (`docling`).
- **Delivery Milestone:** **Milestone 1 (Local RAG)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 10: Embeddings, Reranking, and Vector Search
================================================================================
```
- **Purpose & User-Facing Workflows:** Generates high-density vector embeddings locally from text chunks, indexes them into a vector space, and performs hybrid search (semantic vector + BM25 keyword matching) to supply accurate context to models.
- **Functional Requirements & Acceptance Criteria:**
  - Local embedding execution using compact GGUF embedding models (e.g., `bge-small-en-v1.5`, 384-dim).
  - Sub-15ms nearest-neighbor vector search over 20,000 document chunks `[ESTIMATED]`.
  - Hybrid search: reciprocal rank fusion (RRF) combining SQLite FTS5 keyword search with vector distance.
- **Relevant Repositories & Documentation:**
  - [`sqlite-vec`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/06-rag-and-search/sqlite-vec), [`lancedb`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/06-rag-and-search/lancedb), [`usearch`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/06-rag-and-search/usearch).
- **Candidate Technologies & Alternatives:**
  - *Primary Recommendation:* `sqlite-vec` (pure C extension loaded into SQLite) for unified relational + vector storage.
  - *Architecture Requirement (Replaceable Interface):* All vector store calls MUST be abstracted behind a Swift `VectorStoreProtocol`.
  - *Verified State & Fallback Strategy:* `sqlite-vec` is currently version `0.1.10-alpha.4` with shadow tables and linear scanning `[VERIFIED FACT]`. If pre-1.0 stability issues, query planner bugs, or dataset scaling ceilings emerge, `LanceDB` (embedded Rust columnar format) or `USearch` (C++ header-only) serves as the drop-in fallback backend without altering application code.
- **Integration Points & Dependencies:** SQLite 3, `llama.cpp` embedding mode.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:**
  - Small embedding model (384-dim): ~100 MB RAM resident during indexing, unloaded when idle `[ESTIMATED]`.
  - 20,000 vectors at 384-dim FP32: ~30 MB disk storage.
- **Licensing:** `sqlite-vec` is dual-licensed Apache-2.0 / MIT `[VERIFIED FACT]`. `LanceDB` is Apache-2.0.
- **Testing & Benchmarking:** Ragas evaluation benchmark measuring Context Recall and Context Precision.
- **Delivery Milestone:** **Milestone 1 (Local RAG)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 11: Projects and Persistent Workspaces
================================================================================
```
- **Purpose & User-Facing Workflows:** Allows users to group conversations, documents, custom system instructions, and tool permissions into isolated workspaces (e.g., "Legal Case A", "Swift App Development", "Personal Taxes").
- **Functional Requirements & Acceptance Criteria:**
  - Strict isolation: documents indexed in Workspace A are never searched or exposed in Workspace B.
  - Custom system prompt and model selection per workspace.
  - macOS folder linking: attach an existing local directory using Security-Scoped Bookmarks, keeping documents in sync.
- **Relevant Repositories & Documentation:**
  - [`continue`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/15-reference-applications/continue), [Apple Security-Scoped Bookmarks](https://developer.apple.com/documentation/security/security-scoped_bookmarks).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native SQLite relational schema with workspace foreign keys.
- **Integration Points & Dependencies:** Storage Engine, File System Observers (`FSEvents`).
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Negligible ($< 1\text{ MB}$ RAM overhead).
- **Privacy & Security Risks:** File access must strictly adhere to macOS security-scoped bookmarks granted by user file dialogs.
- **Licensing:** Native proprietary implementation + MIT/Apache-2.0.
- **Delivery Milestone:** **Milestone 1 (Local RAG)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 12: Terminal and Developer Tools
================================================================================
```
- **Purpose & User-Facing Workflows:** Enables AI agents to inspect local Git repositories, run linters (Ruff), run unit tests, and execute safe shell commands on behalf of the user with explicit confirmation.
- **Functional Requirements & Acceptance Criteria:**
  - Integrated terminal execution panel displaying command, working directory, stdout, and stderr.
  - Strict approval gate: every non-read-only terminal command requires explicit user confirmation via an interactive modal.
  - Environment variable sanitization: strip sensitive API keys (`AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`) from the subshell environment.
- **Relevant Repositories & Documentation:**
  - [`astral-sh/uv`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/16-developer-tools-and-protocols/uv), [`astral-sh/ruff`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/16-developer-tools-and-protocols/ruff), [`gitleaks`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/16-developer-tools-and-protocols/gitleaks).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native Swift `Foundation.Process` with piped standard I/O and timeout supervision.
- **Integration Points & Dependencies:** macOS sandbox entitlements (temporary exception for user-approved commands), Tool Gateway.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Subprocess RAM determined by command executed; Aether coordination overhead $< 5\text{ MB}$.
- **Security Reality Check:** User confirmation modals suffer from "click-through fatigue." Aether enforces a blacklist of dangerous commands (`sudo`, `rm -rf`, curl piping), path traversal guards (`realpath` checks), and mandatory dry-run git checkpoints.
- **Licensing:** Permissive (MIT / Apache-2.0).
- **Delivery Milestone:** **Milestone 1 (Extensible Tools & Developer Assistant)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 13: Workflow Automation and Scheduling
================================================================================
```
- **Purpose & User-Facing Workflows:** Allows users to schedule recurring background tasks (e.g., "Every morning at 8 AM, summarize newly added PDF reports in folder X").
- **Functional Requirements & Acceptance Criteria:**
  - Cron-style and interval scheduling of agent workflows.
  - Power-aware execution: integrate with macOS power management (`NSBackgroundActivityScheduler`) to run only when connected to power or battery is $> 50\%$.
- **Relevant Repositories & Documentation:**
  - [`prefect`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/13-workflows-and-automation/prefect), [Apple NSBackgroundActivityScheduler](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native macOS `NSBackgroundActivityScheduler` with SQLite job queues.
- **Integration Points & Dependencies:** Agent Engine (Capability 6), macOS NotificationCenter.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Zero idle overhead; spins up model on schedule and unloads immediately upon completion.
- **Licensing:** Native proprietary implementation + Apache-2.0.
- **Delivery Milestone:** **Milestone 4 (Future Ecosystem)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 14: Multimodal Input, Vision, and Audio
================================================================================
```
- **Purpose & User-Facing Workflows:** Real-time offline voice dictation, text-to-speech reading of responses, and vision-based image/screenshot analysis.
- **Functional Requirements & Acceptance Criteria:**
  - Offline speech-to-text with $< 200\text{ ms}$ latency using Apple Neural Engine (ANE) acceleration.
  - Offline Voice Activity Detection (VAD) distinguishing human voice from background noise.
  - Multi-modal vision inspection: analyze user screenshots and diagrams locally.
- **Relevant Repositories & Documentation:**
  - [`whisper.cpp`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/whisper.cpp), [`silero-vad`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/09-audio-vision-and-multimodal/silero-vad), [`piper`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/09-audio-vision-and-multimodal/piper), [Apple AVSpeechSynthesizer](https://developer.apple.com/documentation/avfoundation/avspeechsynthesizer).
- **Candidate Technologies & Alternatives:**
  - *Recommended Audio STT:* `whisper.cpp` embedded via C FFI with Core ML ANE encoder.
  - *Recommended Voice Detection:* `silero-vad` C implementation.
  - *Recommended Audio TTS:* Apple built-in `AVSpeechSynthesizer` (zero RAM/disk overhead) as default; optional `Piper` ONNX voices for download.
- **Integration Points & Dependencies:** Core Audio, AVFoundation, Metal/CoreML.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Physical Memory & Resource Budget:**
  - Whisper `base.en`: ~140 MB physical RAM `[ESTIMATED]`.
  - Silero VAD: ~2 MB RAM `[ESTIMATED]`.
  - AVSpeechSynthesizer: ~5 MB RAM `[ESTIMATED]`.
  - Total voice stack physical RAM: $< 160\text{ MB}$. Coexists safely even on 8 GB Macs.
- **Privacy & Security Risks:** Microphone eavesdropping. Mitigated by explicit macOS microphone permission prompts and visual recording indicator.
- **Licensing:** Permissive MIT (`whisper.cpp`, `silero-vad`, `piper`).
- **Delivery Milestone:** **Milestone 2 (Voice & Multimodal)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 15: Fine-Tuning and Model Adaptation
================================================================================
```
- **Purpose & User-Facing Workflows:** Trains specialized LoRA adapters locally on the user's personal documents, coding style, or domain terminology using native Metal backpropagation.
- **Functional Requirements & Acceptance Criteria:**
  - On-device 4-bit LoRA fine-tuning utilizing Apple Silicon Metal compute.
  - User preference alignment (DPO) on local conversation exports.
  - Dynamic LoRA adapter hot-swapping during inference.
- **Relevant Repositories & Documentation:**
  - [`mlx`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/mlx), [`mlx-lm`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/mlx-lm), [`mlx-swift`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/mlx-swift), [`trl`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/10-fine-tuning-and-training/trl).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Apple `mlx-swift` / `mlx-lm` native Metal engine.
  - *Alternative:* PyTorch + PEFT (rejected: massive CUDA/Python bloat).
- **Integration Points & Dependencies:** Inference Engine (Capability 3), Storage (Capability 20).
- **macOS / Apple Silicon Compatibility:** Requires macOS 14+ on Apple Silicon with 16 GB+ Unified Memory.
- **Physical Memory & Resource Budget:**
  - *8 GB Mac:* **UNSUPPORTED.** Training an 8B LoRA adapter requires $> 12\text{ GB}$ physical RAM. Blocked in UI.
  - *16 GB Mac (M1–M5):* Supported for 3B/7B 4-bit LoRA training (peak allocation ~11–13 GB physical RAM).
- **Licensing:** MIT License (`mlx`, `mlx-lm`).
- **Delivery Milestone:** **Milestone 3 (Adaptation & Advanced RAG)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 16: Local APIs and Integrations
================================================================================
```
- **Purpose & User-Facing Workflows:** Exposes a local OpenAI-compatible HTTP REST API (`http://127.0.0.1:11435/v1`) or Unix domain socket, allowing external developer tools (Continue, Cursor, custom scripts) to route queries through Aether.
- **Functional Requirements & Acceptance Criteria:**
  - Implementation of `/v1/models`, `/v1/chat/completions` (with streaming SSE), and `/v1/embeddings`.
  - Strict loopback binding (`127.0.0.1` only); no external network interface exposure.
  - Optional API key authentication for local clients.
- **Relevant Repositories & Documentation:**
  - [`fastapi`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/16-developer-tools-and-protocols/fastapi), [`ollama`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/03-serving-and-runtime-comparison/ollama).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Lightweight Swift NIO or FlyingFox embedded HTTP server.
- **Integration Points & Dependencies:** Core Engine, Provider Abstraction.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Embedded server overhead $< 5\text{ MB}$ RAM.
- **Privacy & Security Risks:** Local port hijacking: bind strictly to loopback or Unix domain socket with permissions `0600`.
- **Licensing:** Permissive (MIT / Apache-2.0).
- **Delivery Milestone:** **Milestone 1 (Interop & Tools)** — *Explicitly deferred from M0*.

```
================================================================================
CAPABILITY 17: UI and Native macOS Integration
================================================================================
```
- **Purpose & User-Facing Workflows:** Delivers a refined native macOS interface adhering to Apple Human Interface Guidelines (HIG): MenuBarExtra companion, native keyboard shortcuts, dark/light mode, and ProMotion 120 Hz support.
- **Functional Requirements & Acceptance Criteria:**
  - Single-window native SwiftUI application with collapsible sidebar.
  - Menu bar quick companion (`MenuBarExtra`) for quick status and global prompt hotkey.
  - Native Drag-and-Drop file ingestion onto chat view.
- **Relevant Repositories & Documentation:**
  - Apple SwiftUI & AppKit Documentation, [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native SwiftUI + AppKit.
  - *Alternative:* Tauri 2.0 (viable fallback) or Electron (rejected: excessive memory).
- **Integration Points & Dependencies:** Core Coordinator, OS Notification Center.
- **macOS / Apple Silicon Compatibility:** macOS 14.0+ (Sonoma) and macOS 15.0+ (Sequoia).
- **Memory & Resource Budget:** Native application idle memory ~25–35 MB RAM `[ESTIMATED TARGET]`.
- **Licensing:** Native proprietary implementation.
- **Delivery Milestone:** **Milestone 0 (Core MVP)**.

```
================================================================================
CAPABILITY 18: Permissions, Sandboxing, and Secrets
================================================================================
```
- **Purpose & User-Facing Workflows:** Enforces macOS security compliance, isolates untrusted files, safeguards credentials in the hardware-backed Secure Enclave, and intercepts dangerous agent actions.
- **Functional Requirements & Acceptance Criteria:**
  - macOS App Sandbox enabled (`com.apple.security.app-sandbox`).
  - Security-Scoped Bookmarks for persistent user-delegated filesystem access.
  - Storage of user credentials and API tokens in macOS Keychain Services.
  - Interactive Human-in-the-Loop Gateway for mutating tool executions.
- **Relevant Repositories & Documentation:**
  - [Apple App Sandbox Guide](https://developer.apple.com/documentation/security/app_sandbox), [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain_services).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native macOS Security framework + LocalAuthentication (Touch ID).
- **Integration Points & Dependencies:** Tool Gateway, Filesystem, Keychain.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Negligible ($< 1\text{ MB}$ RAM).
- **Privacy & Security Risks:** Social engineering prompt injection tricking user into approving dangerous actions. Mitigate with structured visual diffs and command blacklists.
- **Licensing:** Native Apple Frameworks.
- **Delivery Milestone:** **Milestone 0 (Core MVP: Sandbox & Keychain) / Milestone 1 (MCP Gateway)**.

```
================================================================================
CAPABILITY 19: Logging, Observability, and Evaluation
================================================================================
```
- **Purpose & User-Facing Workflows:** Provides real-time generation metrics (tokens/sec, time-to-first-token, memory pressure), structured diagnostics via macOS Console, and automated evaluation of prompt quality.
- **Functional Requirements & Acceptance Criteria:**
  - Sub-second telemetry display in UI status bar (TPS, TTFT, model resident RAM).
  - High-performance, zero-disk-waste logging via Apple Unified Logging (`os_log` / `Logger`).
  - Integration with `promptfoo` automated test harness for prompt regression evaluation in CI.
- **Relevant Repositories & Documentation:**
  - [`swift-log`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/swift-log), [`promptfoo`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/11-evaluation-and-observability/promptfoo), [`ragas`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/11-evaluation-and-observability/ragas).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Apple `OSLog` with subsystem `com.aether.desktop`.
- **Integration Points & Dependencies:** Core Coordinator, System Console.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Negligible ($< 1\text{ MB}$ RAM).
- **Licensing:** Apple SDK + Apache-2.0 (`swift-log`) / MIT (`promptfoo`).
- **Delivery Milestone:** **Milestone 0 (Core MVP: OSLog) / Milestone 1 (Evaluation Suite)**.

```
================================================================================
CAPABILITY 20: Checkpoints, Recovery, and Rollback
================================================================================
```
- **Purpose & User-Facing Workflows:** Protects user data from crashes, power loss, or errant agent actions via atomic transaction commits and single-click state rewind.
- **Functional Requirements & Acceptance Criteria:**
  - SQLite 3 Write-Ahead Logging (WAL) mode guaranteeing ACID transaction safety.
  - Automatic crash recovery: uncommitted transactions roll back cleanly on next launch.
  - Step rewind: restore conversation or workspace to any prior agent checkpoint.
  - Single-click atomic database backup via SQLite `VACUUM INTO`.
- **Relevant Repositories & Documentation:**
  - [`sqlite`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/07-data-and-storage/sqlite), [`langgraph`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/04-agent-frameworks-and-tools/langgraph).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* In-process SQLite 3 C API with WAL mode.
- **Integration Points & Dependencies:** SQLite Storage Layer.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** SQLite shared memory buffer ~4–8 MB RAM `[ESTIMATED]`.
- **Licensing:** Public Domain (SQLite).
- **Delivery Milestone:** **Milestone 0 (Core MVP: SQLite WAL) / Milestone 1 (Agent Checkpoint Rewind)**.

```
================================================================================
CAPABILITY 21: Updates, Migration, and Data Portability
================================================================================
```
- **Purpose & User-Facing Workflows:** Ensures seamless schema updates across Aether releases, transparent database migrations, and 100% data portability (export all conversations and documents as JSON/Markdown zip).
- **Functional Requirements & Acceptance Criteria:**
  - Deterministic database migrations using SQLite `PRAGMA user_version`.
  - One-click export of all conversations and knowledge bases to standard JSON/ZIP archive.
  - Zero lock-in: user data is never stored in proprietary or encrypted binary blobs without user-held keys.
- **Relevant Repositories & Documentation:**
  - [`sqlite`](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/07-data-and-storage/sqlite), Sparkle 2 (macOS app updater).
- **Candidate Technologies & Alternatives:**
  - *Recommended:* Native Swift migration runner + Sparkle 2 for secure Ed25519-signed updates.
- **Integration Points & Dependencies:** Storage Layer, macOS User File Dialogs.
- **macOS / Apple Silicon Compatibility:** 100% native.
- **Memory & Resource Budget:** Migrations complete in $< 100\text{ ms}$ on launch.
- **Licensing:** MIT (Sparkle 2) + Public Domain (SQLite).
- **Delivery Milestone:** **Milestone 1 (Data Portability)** — *Explicitly deferred from M0*.
