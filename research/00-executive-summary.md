# Aether Phase 2: Executive Summary & Technical Thesis

**Date:** October 18, 2026  
**Status:** Validated Technical Discovery (Phase 2.2 Complete — Awaiting Human Approval Before Phase 3)  
**Target Hardware:**  
- **Primary Development & Validation Target:** Apple M5 MacBook Air with 16 GB Unified Memory (Performance projected / estimated pending empirical benchmark)  
- **Secondary Compatibility Tier:** Apple Silicon Macs with 8 GB Unified Memory (M1–M4 Base Configurations — strictly resource-constrained tier)  
- **Other Supported Hardware Classes:** M1/M2 16 GB, M3/M4 16 GB, and Pro/Max/Ultra (32 GB – 128 GB Unified Memory)  
**System Classification:** Local-First, Zero-Telemetry Native Desktop AI Platform  

---

## 1. Executive Vision & The Apple Silicon Reality

**Aether** is an offline-first, private personal AI platform engineered specifically to exploit the hardware characteristics of Apple Silicon Macs. Unlike cloud-wrapper applications or generic multi-platform AI clients, Aether's architecture is grounded in three verified physical realities:

1. **Apple Unified Memory Architecture (UMA):** `[VERIFIED FACT]` Apple Silicon shares a single high-bandwidth memory pool between the CPU, the Metal GPU, and the Apple Neural Engine (ANE). Memory bandwidth ranges across distinct hardware classes: ~68–100 GB/s on base M1–M2 chips, ~100–150 GB/s on base M3–M4 chips, 153 GB/s on the M5 MacBook Air (announced March 2026) `[OFFICIAL SPECIFICATION]`, and 200–800 GB/s on Pro/Max/Ultra workstation chips `[ESTIMATED based on memory bus widths]`. When software is written natively for this architecture, tensor buffers can be accessed by the GPU with zero PCI-e bus copying.
2. **Honest Physical Memory Accounting & The `mmap` Reality:** `[VERIFIED FACT]`
   Aether strictly distinguishes between:
   - **Model file size on disk:** Compressed or quantized weights stored on NVMe SSD.
   - **Virtual address space:** Virtual memory pointers reserved via `mmap`.
   - **Resident physical memory (RSS):** Actual physical RAM occupied by pages in active use.
   - **Runtime and Metal allocations:** Metal command buffers, scratch arenas, and compute pipeline state.
   - **KV-cache memory:** Dynamic attention cache memory scaling with model architecture, context length, and element precision.
   - **Application and operating-system memory:** Memory consumed by macOS (WindowServer, daemons) and the native host app.
   - **Memory pressure and swap activity:** System-level memory pressure transitions (`normal`, `warning`, `critical`) and anonymous page-outs to SSD swap.

   Memory-mapping (`mmap`) model files from an NVMe SSD allows fast virtual-memory address reservation without pre-allocating an intermediate user-space heap buffer. **However, `mmap` does not make model weights free in physical memory.** As tensor operations touch weights during inference, pages fault into resident physical RAM. While clean file-backed pages can be reclaimed by macOS under memory pressure without writing to swap, re-faulting evicted pages on subsequent tokens causes storage I/O latency spikes and throughput degradation. Therefore, memory budgets must realistically account for the active resident working set to prevent memory pressure thrashing.
3. **Desktop Ergonomics vs. Resource Bloat:** `[ESTIMATED]` Mainstream AI desktop applications (e.g., Electron-based wrappers) idle at 500 MB–1.2 GB of RAM before a single token is evaluated. On an 8 GB or 16 GB Mac, every megabyte consumed by the application shell is a megabyte stolen from the model weights and the attention KV cache. Aether prioritizes a native macOS presence (SwiftUI + AppKit) with an estimated idle footprint of ~25–35 MB RAM `[ESTIMATED TARGET]`.

---

## 2. Core Architectural Conclusions

Following an exhaustive audit of 80 verified open-source repositories and authoritative documentation across the inference, agent, storage, and Apple system ecosystems, the research establishes the following evidence-backed foundations:

```mermaid
graph TD
    UI[Native macOS SwiftUI Desktop Shell<br/>~25-35 MB Idle RAM [ESTIMATED TARGET]] --> Core[Aether Core Coordinator<br/>Swift 6 Actors / Concurrency]
    Core --> InfMux[Inference Dispatcher & Multiplexer]
    InfMux -->|Primary Universal GGUF Engine - M0| LlamaCPP[llama.cpp C++ Dynamic Library / Metal]
    InfMux -.->|Deferred Engine / Fine-Tuning - M3| MLXSwift[mlx-swift Framework / Metal]
    Core --> Storage[Storage Coordinator]
    Storage --> SQLite[(SQLite 3 WAL Mode - M0)]
    Storage -.->|Deferred Vector Layer - M1| VectorBridge[VectorStoreProtocol Abstraction]
    VectorBridge -.->|Deferred Default - M1| SQLiteVec[sqlite-vec v0.1.10-alpha.4 Extension]
    VectorBridge -.->|Deferred Fallback - M1| LanceDBFallback[LanceDB Embedded Rust / USearch]
    Core -.->|Deferred Agent Engine - M1| AgentEngine[Agent Orchestration & State Graph]
    AgentEngine -.->|Deferred Security Gateway - M1| ToolGateway[Human-in-the-Loop Security Gateway]
    ToolGateway -.->|Deferred Tool Protocol - M1| MCP[Model Context Protocol Host<br/>Subprocess stdio Isolation]
    MCP -.->|Deferred Local Tools - M1| LocalTools[Local File, Git, Dev, Terminal Tools]
```

### Key Technical Findings:

1. **Inference Strategy: Embedded `llama.cpp` for M0; `mlx-swift` Deferred to M3:** `[VERIFIED FACT]`
   - *`llama.cpp`* provides the most stable, memory-efficient, and universally compatible local runtime for GGUF-quantized models (`Q4_K_M`, `Q5_K_M`, `Q8_0`). It links directly into Swift via C FFI without needing a Python environment or background daemon, supports instant token cancellation via loop breaking `[VERIFIED FACT]`, and avoids dynamic shader compilation lag.
   - *`mlx-swift`* provides native Apple array computing with first-party Swift bindings and native gradient backpropagation, making it the premier engine for on-device LoRA fine-tuning in later milestones (M3).
   - **Recommendation:** Implement an `InferenceEngineProtocol` abstraction that defaults to an embedded `llama.cpp` C++ engine for M0 launch, with a secondary `mlx-swift` engine adapter introduced for fine-tuning in M3.
2. **Application Shell: Native SwiftUI over Electron:** `[ESTIMATED]`
   - Pure native SwiftUI + AppKit has an estimated idle footprint of ~25–35 MB of RAM `[ESTIMATED TARGET]`, integrates seamlessly with macOS App Sandbox, MenuBarExtra, Security-Scoped Bookmarks, and Keychain Services, and eliminates the battery drain of web runtimes.
3. **Storage: Unified SQLite 3 for M0 with a Replaceable Vector Store Interface Deferred to M1:** `[VERIFIED FACT]`
   - SQLite in WAL (Write-Ahead Logging) mode provides single-file ACID persistence for conversations, prompt templates, and audit logs.
   - While `sqlite-vec` provides attractive in-process C vector search, inspection reveals it is at version `0.1.10-alpha.4` with shadow-table linear scans `[VERIFIED FACT]`.
   - **Recommendation:** M0 implements only relational conversation and message persistence in SQLite. All vector operations are deferred to M1 and isolated behind a strict Swift `VectorStoreProtocol`.
4. **Tool Extensibility & Realistic Security (Deferred to M1):** `[VERIFIED FACT]`
   - Anthropic's Model Context Protocol (MCP) using JSON-RPC over `stdio` is the open industry standard for tool connectivity.
   - **Crucial Security Reality:** Subprocess separation prevents memory corruption of the host app, but does *not* prevent side-effect damage if a tool has filesystem write or shell permissions. User confirmation dialogs suffer from "click-through fatigue." Aether enforces a multi-layered defense: pre-execution argument validation, path traversal guards (`realpath` checks), git dry-run previews, and immutable audit logging. All MCP features are explicitly deferred from M0.
5. **Radical M0 MVP Scoping:** `[LOCKED SCOPE]`
   - To guarantee launch stability and rigorous performance validation, Milestone M0 is locked strictly to: Native macOS SwiftUI Desktop Shell, Embedded `llama.cpp` Engine (Metal), Local Model Discovery and Import, SQLite Conversation Persistence (WAL mode), Streaming Responses with Responsive Cancellation, Conversation History/Navigation, Error/Interruption Recovery, and a comprehensive Benchmark Protocol covering M5 16 GB and 8 GB systems.
   - Document RAG, vector storage, MCP tool execution, voice/audio, terminal execution, fine-tuning, cloud integrations, and sync are explicitly deferred.

---

## 3. Hardware Budget Realities: Primary M5 16 GB vs. 8 GB Compatibility Tier

The physical memory budget accounts for resident weights, KV cache, runtime buffers, and OS overhead based on explicit calculations and engineering projections:

| Component | 8 GB Compatibility Tier (M1–M4)<br/>*Model: 3B Q4_K_M (4K Context)* | Primary Target: M5 MacBook Air (16 GB)<br/>*Model: 8B Q4_K_M (8K Context)* | Status |
|---|---|---|---|
| **macOS Base + WindowServer** | 3.0 – 3.5 GB | 3.5 – 4.5 GB | `[ESTIMATED]` |
| **Aether Native App Runtime** | ~35 MB idle / ~80 MB active | ~40 MB idle / ~100 MB active | `[ESTIMATED TARGET]` |
| **Model Weights (Physical RAM)**| ~1.95 GB (Llama-3.2-3B Q4_K_M) | ~4.70 GB (Llama-3.1-8B Q4_K_M) | `[CALCULATED]` |
| **Metal Context & Scratch Arena**| ~250 MB | ~450 MB | `[ESTIMATED]` |
| **Attention KV Cache** | ~256 MB (4K context, FP16) | ~1,024 MB (1.0 GB, 8K context, FP16)| `[CALCULATED]` |
| **Vector Index / Embedding Buffer**| Deferred from M0 (0 MB) | Deferred from M0 (0 MB) | `[M0 SCOPE LOCK]` |
| **Total Physical RAM Projected** | **~5.5 – 6.1 GB** | **~9.7 – 10.8 GB** | `[CALCULATED]` |
| **Projected Headroom before Swap**| **~1.9 – 2.5 GB Margin** | **~5.2 – 6.3 GB Margin** | `[CALCULATED]` |
| **macOS Swap Disk Write Activity** | **0 bytes swap** | **0 bytes swap** | `[PROPOSED TARGET]` |

> [!IMPORTANT]
> **8 GB Hardware Constraint:** Running an 8B model on an 8 GB Mac requires ~4.7 GB (weights) + ~1.0 GB (KV cache) + ~0.45 GB (Metal arena) + ~3.2 GB (macOS) = **~9.35 GB**, forcing 1.5–2.5 GB of compressed SSD swap, destroying interactive performance. On 8 GB Macs, Aether enforces a **provisional model ceiling of 4B parameters and 4,096 tokens of context**, to be empirically verified in Phase 3.
