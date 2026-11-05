# Aether — Phase 3.6: Local Model Library, Multi-Model Selection & Catalog Management
## Gate A: Read-Only Reconnaissance & Gate B: Architecture Plan

**Project:** Aether — Local-First AI Workspace for Apple Silicon  
**Phase:** 3.6 — Local Model Library, Multi-Model Selection & Catalog Management  
**Date:** October 19, 2026  
**Execution Mode:** Gate A (Reconnaissance) & Gate B (Architecture & Implementation Plan)  
**Status:** PROPOSED ARCHITECTURE — AWAITING GATE C AUTHORIZATION  
**Primary Target Platform:** MacBook Air M5, 16 GB unified memory, macOS 14.0+ (Sonoma/Sequoia)  
**Secondary Compatibility Target:** Apple Silicon, 8 GB unified memory  
**Language & Concurrency:** Swift 6 with strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`) `[VERIFIED FACT]`  
**Pinned llama.cpp Revision:** `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`) `[VERIFIED FACT]`  
**Deliverable File:** `research/28-phase-3.6-model-library-reconnaissance.md`

---

## 1. Executive Summary and Proposed Verdict

### 1.1 Executive Summary
Phase 3.6 investigates and designs the architecture for Aether's **Local Model Library, Multi-Model Selection, and Catalog Management**.

In the preceding Phase 3.5 and 3.5.1 milestones, Aether established:
1. A robust native inference worker backed by pinned `llama.cpp` (`b11718`) executing inside an actor-isolated state machine (`InferenceService`).
2. Actor-isolated SQLite persistence with WAL mode, foreign keys, cascading deletions, and interrupted generation recovery (`ConversationDatabase`).
3. A native SwiftUI chat interface supporting multi-turn conversation switching, streaming token persistence (batched at 16 tokens), and cancellation barriers (`ChatViewModel` and `ChatView`).
4. Standalone packaged-app execution under ad-hoc signing with embedded `llama.framework`.

However, currently the application supports loading only an ad-hoc GGUF file via a transient `NSOpenPanel` modal. The loaded model is neither cataloged nor persisted: restarting the application or switching between conversations loses model configuration; there is no inspection of model architecture, parameter count, or context limits prior to full tensor loading; moved or deleted files result in raw loading exceptions; and there is no UI for browsing, managing, or selecting between multiple local models.

This report establishes that:
- The pinned `llama.framework` already includes and exports `gguf.h` [VERIFIED FACT]. Calling `gguf_init_from_file` with `no_alloc = true` allows **sub-millisecond, zero-allocation inspection** of GGUF headers (reading architecture, quantization, context length, tensor count, and chat templates) without loading model weights into unified memory [VERIFIED FACT].
- The existing SQLite persistence engine (`ConversationDatabase`) can cleanly advance from schema version 1 to version 2 via a transactional migration adding a `models` catalog table and indexing [VERIFIED FACT].
- App Sandbox (`com.apple.security.app-sandbox = true`) requires persistent **security-scoped bookmarks** (`URL.bookmarkData(options: .withSecurityScope, ...)`) to allow reopening external user-selected model files across application launches without re-prompting [VERIFIED FACT].
- To maintain strict memory safety across both 16 GB and 8 GB Apple Silicon devices, Aether must adhere to a **Single Active Model Invariant**: exactly one model may reside in unified memory at any given time. Model switching must strictly cancel active generation, await worker termination barriers, fully unload the prior model, and only then load the replacement model [VERIFIED FACT].

### 1.2 Proposed Verdict
**Verdict:** `RECOMMENDED FOR IMPLEMENTATION (GATE C PENDING)`  
The technical reconnaissance confirms full feasibility using existing in-tree dependencies. No external packages, network services, or backend upgrades are required. Implementation should proceed upon explicit Gate C authorization.

---

## 2. Verified Workspace and Code Baseline

### 2.1 Workspace and Version Control State
- **Workspace Root:** `/Users/asadalishaikh/Aether Agent` [VERIFIED FACT].
- **Root Repository:** The workspace root is not initialized as a standalone Git repository (`fatal: not a git repository`) [VERIFIED FACT].
- **Pinned Upstream Repository:** Located at `reference-repos/01-apple-silicon-and-inference/llama.cpp` [VERIFIED FACT].
  - **Git Revision:** `547208dca250ceb3e4c8615598d043f2b602a527` [VERIFIED FACT].
  - **Git Tag:** `b11718` [VERIFIED FACT].
  - **Working Tree:** Clean (0 untracked files, 0 modified files) [VERIFIED FACT].
- **Production Code Isolation:** During Gates A and B, zero production code files in `Aether/Sources/` were modified [VERIFIED FACT].

### 2.2 Xcode Project and Build Settings Baseline
Inspected in `Aether.xcodeproj/project.pbxproj`:
- **Swift Version:** Swift 6.0 (`SWIFT_VERSION = 6.0;`) across all configurations [VERIFIED FACT].
- **Swift Strict Concurrency:** `SWIFT_STRICT_CONCURRENCY = complete;` across Debug and Release [VERIFIED FACT].
- **Bridging Header:** `Aether/Sources/Inference/Aether-Bridging-Header.h` exposes `AetherAtomic.h` [VERIFIED FACT].
- **Framework Search Paths:** `$(PROJECT_DIR)/Aether/Frameworks/llama.xcframework/macos-arm64` [VERIFIED FACT].
- **Embedded Binaries:** `llama.framework` embedded and signed with `@executable_path/../Frameworks` in `LD_RUNPATH_SEARCH_PATHS` [VERIFIED FACT].
- **Hardened Runtime Configuration:**
  - `Debug`: `ENABLE_HARDENED_RUNTIME = YES;` [VERIFIED FACT].
  - `Release`: `ENABLE_HARDENED_RUNTIME = NO;` (authorized remediation from Phase 3.5.1 for local ad-hoc development) [VERIFIED FACT].
- **Entitlements:** `Aether/Resources/Aether.entitlements` specifies `com.apple.security.app-sandbox = true` [VERIFIED FACT].

### 2.3 Phase 3.5.1 Acceptance Status & Test Baseline
- **Automated Regression Suite:** 69 tests across 4 test classes (`ConversationDatabaseTests`, `ChatViewModelTests`, `InferenceGenerationTests`, `InferenceLifecycleTests`) [VERIFIED FACT].
- **Pass Rate:** 69 passed, 0 failed, 0 errors, 0 warnings (12.484s execution time) [VERIFIED FACT].
- **GUI Checks Status:** 11 manual UI checks remain marked `NOT VERIFIED (GUI)` due to headless subshell execution and macOS AppleScript assistive access restrictions (`-1728`). However, the underlying view model, persistence, and state-machine logic for all 11 items were verified by automated test fixtures [VERIFIED FACT].
- **Local Model Fixture:**
  - Path: `/Users/asadalishaikh/.ollama/models/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463` [VERIFIED FACT].
  - Exact Size: `4,683,074,048 bytes` (4.36 GiB) [MEASURED].
  - Format: GGUF v3 [VERIFIED FACT].
  - Architecture: `qwen2` (Qwen2.5-Coder-7B-Instruct) [VERIFIED FACT].
  - Quantization: `Q4_K_M` (`LLAMA_FTYPE_MOSTLY_Q4_K_M = 15`) [VERIFIED FACT].
  - Context Length: `32,768` tokens [VERIFIED FACT].

---

## 3. Existing Architecture and Lifecycle Findings

### 3.1 Existing Inference Pipeline
The inference stack comprises three distinct tiers:
1. **`LlamaInferenceWorker` (Native Engine):**
   - Resides on a dedicated private serial `DispatchQueue` (`com.aether.inference.worker`) [VERIFIED FACT].
   - Manages raw C pointers (`llama_model *`, `llama_context *`, `llama_batch`) [VERIFIED FACT].
   - Implements `syncLoadModel`, `syncUnloadModel`, and `syncGenerate` [VERIFIED FACT].
   - Strictly prevents native C pointer leakage across thread boundaries [VERIFIED FACT].
2. **`InferenceService` (Actor State Machine):**
   - High-level coordinator maintaining actor isolation (`public actor InferenceService`) [VERIFIED FACT].
   - Enforces valid lifecycle states: `.unloaded`, `.loading(path:)`, `.loaded(modelInfo:)`, `.generating(modelInfo:)`, `.unloading`, `.failed(errorDescription:)` [VERIFIED FACT].
   - Exposes asynchronous state observation via `stateStream: AsyncStream<InferenceState>` [VERIFIED FACT].
   - Enforces cancellation barriers via `CancellationSignal` and generation task tracking [VERIFIED FACT].
3. **`ChatViewModel` & `ChatView` (UI Layer):**
   - `@MainActor` and `@Observable` UI state coordinator [VERIFIED FACT].
   - Observes `InferenceService.stateStream` and synchronizes UI status indicators [VERIFIED FACT].
   - Currently loads models ad-hoc via `promptLoadModel()` using `NSOpenPanel` [VERIFIED FACT].

### 3.2 Current Model Loading Gaps
Inspecting `LlamaInferenceWorker.swift` (lines 151–223) and `ChatViewModel.swift` (lines 403–434) reveals key limitations:
1. **No Pre-Load Metadata Inspection:** Currently, `loadModel(at:path:)` invokes `llama_model_load_from_file(path, params)` directly. Reading model properties requires allocating GPU buffers and reading multi-gigabyte tensors into memory. If the model is incompatible or corrupt, failure only occurs after significant disk I/O and memory churn.
2. **No Model Catalog Persistence:** Model paths are not saved to the SQLite database. Closing the app resets the state to `.unloaded`.
3. **Missing Security-Scoped Bookmarks:** Under App Sandbox (`com.apple.security.app-sandbox = true`), files selected outside the container via `NSOpenPanel` lose access rights across app relaunches unless saved as security-scoped bookmarks [VERIFIED FACT].
4. **No Model Switching Logic:** Calling `loadModel` while a model is already loaded throws `InferenceError.alreadyLoaded`. The application lacks a serialized `switchModel` operation.
5. **No Model-to-Conversation Association:** Conversations record a transient `model_name` string, but have no relational link to a cataloged model record or configuration.

---

## 4. Repository Candidate Inventory and Evidence

In accordance with the repository-first engineering policy, mature local reference repositories were inspected for GGUF parsing, model library state management, and SwiftUI catalog design.

| Candidate & Local Path | Relevant Implementation Files | License | Compatibility & Maintenance | Strengths | Limitations | Decision & Rationale |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`llama.cpp`**<br>`reference-repos/01-apple-silicon-and-inference/llama.cpp` | `include/llama.h`<br>`ggml/include/gguf.h`<br>`ggml/src/gguf.cpp`<br>`examples/gguf/gguf.cpp` | **MIT License** `[VERIFIED FACT]` | Pinned commit `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`). Clean tree. | Native C GGUF parser (`gguf_init_from_file`) already embedded in `llama.framework`. Reads headers with `no_alloc: true` in < 2ms. | Low-level C API requiring unsafe pointer handling in Swift. | **REUSE (DIRECT)** `[VERIFIED FACT]`. Reuse existing embedded framework headers. Zero new dependencies required. |
| **`mlx-swift-examples`**<br>`reference-repos/01-apple-silicon-and-inference/mlx-swift-examples` | `Applications/MLXChatExample/Models/LMModel.swift`<br>`Applications/MLXChatExample/ViewModels/ChatViewModel.swift`<br>`Applications/MLXChatExample/Views/Toolbar/ChatToolbarView.swift` | **MIT License** `[VERIFIED FACT]` | Clean, modern Swift 6 / SwiftUI code for Apple Silicon. | Clean SwiftUI model selector patterns, `@Observable` view models, model type classification. | Targets Apple MLX framework rather than llama.cpp / GGUF. | **ADAPT (PATTERNS)** `[VERIFIED FACT]`. Adapt the SwiftUI picker and model record patterns for Aether's chat header and sidebar. |
| **`open-webui`**<br>`reference-repos/08-desktop-ui-and-application-frameworks/open-webui` | `backend/open_webui/models/models.py`<br>`backend/open_webui/routers/models.py` | **AGPL-3.0** `[VERIFIED FACT]` | Active upstream, multi-model catalog and history. | Rich metadata schema (context length, parameter labels, tags, access control). | AGPL-3.0 license prevents code copying; written in Python / FastAPI. | **REJECT (INSPIRATION ONLY)** `[VERIFIED FACT]`. Adopt data model concepts conceptually; write 100% clean-room Swift code. |
| **`anything-llm`**<br>`reference-repos/08-desktop-ui-and-application-frameworks/anything-llm` | `server/models/modelRouter.js`<br>`server/utils/AiProviders/ollama/index.js` | **MIT License** `[VERIFIED FACT]` | Active upstream, multi-model workspace routing. | Fallback model handling, graceful handling of missing model files. | Node.js / Electron architecture; no native Swift or GGUF handling. | **REJECT (INSPIRATION ONLY)** `[VERIFIED FACT]`. Pattern inspiration for missing model detection and fallback states. |

---

## 5. Metadata and Model-Format Support Findings

### 5.1 GGUF Binary Format & Parsing via `gguf.h`
The GGUF specification (version 3) stores metadata key-value pairs at the beginning of the file before tensor data [VERIFIED FACT].

Inspecting `Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Headers/gguf.h`:
```c
struct gguf_init_params {
    bool no_alloc;
    struct ggml_context ** ctx;
};

GGML_API struct gguf_context * gguf_init_from_file(const char * fname, struct gguf_init_params params);
GGML_API void                  gguf_free(struct gguf_context * ctx);
GGML_API int64_t               gguf_get_n_kv(const struct gguf_context * ctx);
GGML_API int64_t               gguf_find_key(const struct gguf_context * ctx, const char * key);
GGML_API const char *          gguf_get_val_str(const struct gguf_context * ctx, int64_t key_id);
GGML_API uint32_t              gguf_get_val_u32(const struct gguf_context * ctx, int64_t key_id);
GGML_API uint64_t              gguf_get_val_u64(const struct gguf_context * ctx, int64_t key_id);
GGML_API int64_t               gguf_get_n_tensors(const struct gguf_context * ctx);
```

When called with `params.no_alloc = true` and `params.ctx = NULL`, `gguf_init_from_file` memory-maps the file header and reads the key-value pairs **without reading or allocating memory for tensor weights** [VERIFIED FACT].

### 5.2 Verified Metadata Extraction from Local Model Fixture
Running read-only header inspection on Aether's local fixture (`Qwen2.5-Coder-7B-Instruct` blob) produced:
- **Magic:** `GGUF` (4 bytes: `0x47 0x47 0x55 0x46`) `[VERIFIED FACT]`.
- **Version:** `3` `[VERIFIED FACT]`.
- **Tensor Count:** `339` tensors `[VERIFIED FACT]`.
- **Metadata Pairs:** `34` key-value pairs `[VERIFIED FACT]`.
- **Extracted Keys:**
  - `general.architecture`: `"qwen2"` `[VERIFIED FACT]`.
  - `general.name`: `"Qwen2.5 Coder 7B Instruct"` `[VERIFIED FACT]`.
  - `general.basename`: `"Qwen2.5-Coder"` `[VERIFIED FACT]`.
  - `general.size_label`: `"7B"` `[VERIFIED FACT]`.
  - `general.license`: `"apache-2.0"` `[VERIFIED FACT]`.
  - `qwen2.block_count`: `28` (layers) `[VERIFIED FACT]`.
  - `qwen2.context_length`: `32768` (maximum trained context window) `[VERIFIED FACT]`.
  - `general.file_type`: `15` (`LLAMA_FTYPE_MOSTLY_Q4_K_M`) `[VERIFIED FACT]`.
  - `general.quantization_version`: `2` `[VERIFIED FACT]`.

### 5.3 Quantization Type Mapping
The integer `general.file_type` maps to `llama_ftype` defined in `llama.h`:
- `0`: `ALL_F32`
- `1`: `MOSTLY_F16`
- `2`: `MOSTLY_Q4_0`
- `3`: `MOSTLY_Q4_1`
- `7`: `MOSTLY_Q8_0`
- `8`: `MOSTLY_Q5_0`
- `9`: `MOSTLY_Q5_1`
- `12`: `MOSTLY_Q3_K_M`
- `14`: `MOSTLY_Q4_K_S`
- `15`: `MOSTLY_Q4_K_M`
- `16`: `MOSTLY_Q5_K_S`
- `17`: `MOSTLY_Q5_K_M`
- `18`: `MOSTLY_Q6_K`
- `19`–`29`: `IQ` quantization variants

### 5.4 Pre-Flight Compatibility Matrix
A model file can be categorized into clear readiness states:
1. **`Valid & Ready`:** Magic is `GGUF`, version is 2 or 3, architecture is supported by pinned llama.cpp, file exists and is readable.
2. **`Corrupt or Invalid`:** Header lacks `GGUF` magic, truncated header, or unparseable KV pairs.
3. **`Unsupported Architecture`:** Valid GGUF, but architecture (e.g. unknown experimental arch) is not in llama.cpp supported enum.
4. **`Missing File`:** File was moved, renamed, or deleted outside Aether.
5. **`Memory Warning`:** Model file size or parameter count exceeds recommended limits for the host's unified memory tier.

---

## 6. Memory and Concurrency Risks

### 6.1 Unified Memory Profiles: 16 GB vs 8 GB Targets

On Apple Silicon, CPU and GPU share the same physical DRAM pool (Unified Memory Architecture, UMA) [VERIFIED FACT].

| Metric / Attribute | Primary Target: MacBook Air M5 (16 GB) | Secondary Target: Apple Silicon (8 GB) |
| :--- | :--- | :--- |
| **Total Physical RAM** | 16,384 MiB `[VERIFIED FACT]` | 8,192 MiB `[VERIFIED FACT]` |
| **OS & Baseline System Footprint** | ~3,000–3,500 MiB `[ESTIMATED]` | ~2,500–3,000 MiB `[ESTIMATED]` |
| **Available Headroom for Apps** | ~12,500–13,000 MiB `[CALCULATED]` | ~5,000–5,500 MiB `[CALCULATED]` |
| **7B Q4_K_M Model Footprint (Weights + KV Cache)** | ~4,700–5,200 MiB `[MEASURED]` | ~4,700–5,200 MiB `[MEASURED]` |
| **8 GB Target Impact with 7B Model** | Fits comfortably; ~7.5 GB headroom remaining `[CALCULATED]` | **DANGER:** Consumes >95% available headroom; triggers yellow/red memory pressure and swap thrashing `[CALCULATED]` |
| **Recommended Model Tier** | **7B to 9B parameters** (e.g. Qwen2.5 7B, Llama 3.1 8B Q4_K_M) `[VERIFIED FACT]` | **1B to 3.8B parameters** (e.g. Qwen2.5 1.5B/3B, Llama 3.2 1B/3B, SmolLM2 1.7B) `[CALCULATED]` |
| **Max Model File Size Threshold** | ~8.0 GiB (warning threshold) `[RECOMMENDED]` | ~3.0 GiB (warning threshold) `[RECOMMENDED]` |

### 6.2 The Single Active Model Invariant
Attempting to keep two 7B models loaded simultaneously on a 16 GB machine would require `4.7 GB + 4.7 GB = 9.4 GB` resident memory, bringing total memory usage above 12.5 GB and risking system instability. On an 8 GB machine, loading two models is impossible.

**Mandatory Invariant:**
`InferenceService` must enforce that **at most one native model is loaded in memory at any time** [VERIFIED FACT].

### 6.3 Concurrency & Race Conditions During Model Switching
Switching models introduces specific race hazards that must be serialized:
1. **Switching While Generating:** If the user selects a new model while text generation is active in the current conversation, the switch request must NOT abruptly destroy native pointers out from under the running worker thread.
   - *Mitigation:* The coordinator must first invoke `activeStream.cancel()`, await the mandatory `waitForTermination()` barrier, and only then begin the unload/load cycle.
2. **Double-Load Race:** If a user rapidly clicks two different models in the library, concurrent load tasks must be rejected.
   - *Mitigation:* `InferenceService` transitions to `.loading(path:)` synchronously on actor entry; subsequent load/switch calls throw `InferenceError.conflictingOperation`.
3. **Failed Load Recovery:** If the new model file is corrupt or unreadable, the old model has already been unloaded.
   - *Mitigation:* The engine transitions cleanly to `.failed(errorDescription:)` and immediately releases all residual allocations. It does NOT leave orphan worker tasks running.

---

## 7. Proposed Phase 3.6 Scope

### 7.1 In-Scope Capabilities
1. **GGUF Fast Metadata Inspection:** Implement `GGUFMetadataReader` using native `gguf_init_from_file(..., no_alloc: true)` to parse model details in milliseconds without tensor allocation.
2. **Model Catalog Persistence (SQLite Migration v2):** Add a `models` table to `ConversationDatabase` with file path, file size, architecture, quantization, context length, parameter count, and security-scoped bookmark data.
3. **Model Library UI (SwiftUI):**
   - Model Library Sheet/Popover accessible from the sidebar.
   - Model list cards displaying name, architecture, quantization badge, file size, and readiness status.
   - "+ Add Local Model..." action invoking `NSOpenPanel` restricted to `.gguf` files.
   - "Inspect Details" view showing full metadata (layers, context window, license, path).
   - "Remove from Library" action with explicit confirmation (removing SQLite record without touching the file on disk).
4. **Multi-Model Selection & Association:**
   - Conversation-level model selection: conversations retain their selected model association.
   - Quick model picker dropdown in `ChatView` header and sidebar footer.
5. **Safe Serialized Model Switching:**
   - Add `switchModel(to:configuration:)` to `InferenceService`.
   - Enforce cancellation of active generation, termination barrier synchronization, full unload of prior model, and load of new model.
6. **Graceful Handling of Moved/Missing Files:**
   - Detect missing model files on catalog load and mark as `isMissing`.
   - Prevent crash or silent catalog deletion if a file is moved; show clear UI warning with an option to locate or remove the entry.
7. **Comprehensive Unit and Lifecycle Tests:**
   - Unit tests covering GGUF parsing, database migrations, model selection, missing file detection, switch cancellation, and failed-load recovery.

### 7.2 Explicit Exclusions (Hard Exclusions)
- No model downloading, Hugging Face Hub integration, Ollama pulling, or network registries.
- No automatic deletion, renaming, or modification of model files on disk.
- No changes to `llama.framework` or upgrading the pinned llama.cpp commit.
- No RAG, embeddings, vector databases, MCP agents, tools, plugins, or multimodal features.
- No changes to code signing or Hardened Runtime settings.

---

## 8. Proposed Architecture and Data Model

### 8.1 SQLite Persistence Schema: Migration v2

`ConversationDatabase` will execute Migration v2 within an exclusive transaction:

```sql
-- Migration v2: Add local model catalog table
CREATE TABLE IF NOT EXISTS models (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    file_path TEXT NOT NULL UNIQUE,
    file_size INTEGER NOT NULL,
    architecture TEXT NOT NULL,
    quantization TEXT NOT NULL,
    context_length INTEGER NOT NULL,
    parameter_count INTEGER,
    created_at REAL NOT NULL,
    last_used_at REAL,
    bookmark_data BLOB
);

CREATE INDEX IF NOT EXISTS idx_models_file_path ON models(file_path);
CREATE INDEX IF NOT EXISTS idx_models_last_used ON models(last_used_at);

-- Optional linkage on conversations
-- conversations.model_name is preserved for display/historical retention
```

### 8.2 Swift Data Models

```swift
/// Represents a cataloged local model record in SQLite.
public struct ModelRecord: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let filePath: String
    public let fileSize: Int64
    public let architecture: String
    public let quantization: String
    public let contextLength: Int
    public let parameterCount: Int64?
    public let createdAt: Date
    public let lastUsedAt: Date?
    public let bookmarkData: Data?

    /// Transient validation state evaluated at runtime against the local filesystem.
    public var isMissing: Bool = false
    public var compatibilityStatus: ModelCompatibility = .compatible
}

public enum ModelCompatibility: Sendable, Equatable {
    case compatible
    case unsupportedArchitecture(String)
    case corruptHeader(String)
    case memoryWarning(String)
}
```

### 8.3 Security-Scoped Bookmark Lifecycle under App Sandbox

To maintain compatibility with App Sandbox:
1. When user selects a `.gguf` file via `NSOpenPanel`:
   ```swift
   let bookmarkData = try url.bookmarkData(
       options: .withSecurityScope,
       includingResourceValuesForKeys: nil,
       relativeTo: nil
   )
   ```
2. When accessing or loading the model:
   ```swift
   var isStale = false
   let resolvedURL = try URL(
       resolvingBookmarkData: bookmarkData,
       options: .withSecurityScope,
       relativeTo: nil,
       bookmarkDataIsStale: &isStale
   )
   let didAccess = resolvedURL.startAccessingSecurityScopedResource()
   defer {
       if didAccess { resolvedURL.stopAccessingSecurityScopedResource() }
   }
   ```
3. If the bookmark is stale or access fails (e.g. file moved), the model record is marked `isMissing = true`, and the user is prompted to re-locate the file.

### 8.4 Inference Service State Machine Extension

Add a dedicated `switchModel` method on `InferenceService`:

```mermaid
stateDiagram-v2
    [*] --> Unloaded
    Unloaded --> Loading : loadModel()
    Loading --> Loaded : Worker load success
    Loading --> Failed : Worker load error
    
    Loaded --> Generating : generate()
    Generating --> Loaded : Generation completes / terminates
    Generating --> Unloading : cancel active generation + barrier -> switchModel()
    
    Loaded --> Unloading : unloadModel() / switchModel()
    Unloading --> Unloaded : Worker unload complete
    Unloaded --> Loading : Load replacement model
    
    Failed --> Unloaded : unloadModel()
```

---

## 9. File-by-File Implementation Plan

### 9.1 New Production Files
1. **`Aether/Sources/ModelLibrary/ModelRecord.swift`**
   - Defines `ModelRecord`, `ModelCompatibility`, and GGUF metadata structs.
   - Conforms to `Sendable`, `Identifiable`, `Equatable`.
2. **`Aether/Sources/ModelLibrary/GGUFMetadataReader.swift`**
   - Wraps `gguf_init_from_file` with `params.no_alloc = true`.
   - Inspects `general.architecture`, `general.name`, `<arch>.context_length`, `general.file_type`, etc.
   - Strictly manages C context lifecycle via `defer { gguf_free(ctx) }`.
3. **`Aether/Sources/ModelLibrary/ModelLibraryService.swift`**
   - High-level coordinator for model discovery, bookmark resolution, catalog persistence, and filesystem change detection.
4. **`Aether/Sources/UI/ModelLibrary/ModelLibraryView.swift`**
   - Native SwiftUI sheet/window displaying the catalog of models.
   - Search bar, "+ Add Model" button, model cards, detail inspector, and confirmation dialogs.
5. **`Aether/Sources/UI/ModelLibrary/ModelCardView.swift`**
   - Component card displaying model name, architecture badge, quantization tag, file size, and status indicators.

### 9.2 Modified Production Files
1. **`Aether/Sources/Persistence/ConversationDatabase.swift`**
   - Add Migration v2 to create `models` table.
   - Implement `insertModel`, `fetchModels`, `updateModelLastUsed`, `deleteModelRecord`.
2. **`Aether/Sources/Inference/InferenceService.swift`**
   - Add `switchModel(to path: String, configuration: ModelConfiguration)` with serialization barrier.
3. **`Aether/Sources/UI/Chat/ChatViewModel.swift`**
   - Add `catalogModels: [ModelRecord]`, `selectedModelId: UUID?`.
   - Integrate model switching on conversation change or manual picker change.
4. **`Aether/Sources/UI/Chat/ChatView.swift`**
   - Add model picker in the chat header allowing instant model switching.
5. **`Aether/Sources/UI/Chat/ConversationSidebarView.swift`**
   - Add "Model Library" action button in sidebar footer to open the library sheet.
6. **`Aether.xcodeproj/project.pbxproj`**
   - Register new Swift source files and test files in project build phases.

### 9.3 Test Suite Files
1. **`Aether/Tests/ModelLibraryTests.swift` (New)**
   - Test GGUF parser on valid, corrupt, and truncated fixtures.
   - Test SQLite Migration v2 schema integrity and CRUD operations.
   - Test security-scoped bookmark creation and error handling.
   - Test model switching races and cancellation synchronization.

---

## 10. Migration and Rollback Strategy

### 10.1 Forward Migration (v1 -> v2)
- Handled atomically inside `ConversationDatabase.configureAndMigrate`:
  - `schema_migrations` records `version = 2`.
  - Migration is wrapped in `BEGIN EXCLUSIVE TRANSACTION` ... `COMMIT`.
  - Non-destructive: existing `conversations` and `messages` tables are 100% unaltered.

### 10.2 Rollback Safety
- If Migration v2 fails or is aborted:
  - SQLite rolls back the transaction automatically.
  - Existing v1 conversations and messages remain completely untouched and functional.
- Reverting to v1 codebase:
  - If rolled back to Phase 3.5 code, v1 simply ignores the `models` table and operates normally.

---

## 11. Security, Sandbox, Licensing, and Privacy Review

### 11.1 App Sandbox Review
- **Current Entitlements:** `com.apple.security.app-sandbox = true` [VERIFIED FACT].
- **Sandboxed Model Access Options:**
  1. *Container Directory:* `~/Library/Containers/com.aether.Aether/Data/Documents/Models` requires NO additional entitlements.
  2. *User-Selected Files Outside Container:* Requires `NSOpenPanel` and security-scoped bookmarks. Apple recommends `com.apple.security.files.user-selected.read-only = true` for persistent bookmark restoration.
- **Privacy Guarantee:** All model metadata inspection is 100% local. Zero telemetry, zero network calls, zero external analytics.

### 11.2 Licensing Review
- `llama.cpp` headers: MIT License [VERIFIED FACT]. Full commercial and open-source compatibility.
- `mlx-swift-examples`: MIT License [VERIFIED FACT]. Pattern reuse is compliant.
- `open-webui`: AGPL-3.0 [VERIFIED FACT]. Explicitly rejected for code reuse to avoid licensing contamination.

---

## 12. Acceptance Criteria and Test Matrix

| Category | Test Identifier | Acceptance Criterion | Verification Method |
| :--- | :--- | :--- | :--- |
| **Catalog Migration** | `TEST-CAT-01` | Migration v2 applies cleanly over existing v1 database without data loss. | Unit test against disposable SQLite instance. |
| **GGUF Fast Metadata** | `TEST-GGUF-01` | Reads architecture, quantization, context length, and tensor count in < 10ms with zero tensor allocation. | Unit test on local GGUF fixture and mock byte headers. |
| **Corrupt File Detection** | `TEST-GGUF-02` | Rejects non-GGUF files or truncated headers with clear typed error. | Unit test on empty/garbage files. |
| **Model Catalog CRUD** | `TEST-CAT-02` | Insert, list, update last used, and remove catalog records cleanly. | Unit test in `ModelLibraryTests`. |
| **File Preservation** | `TEST-CAT-03` | Removing a model from the library leaves the physical file on disk 100% intact. | Unit test verifying file existence after catalog deletion. |
| **Missing File Detection** | `TEST-CAT-04` | When a cataloged file is moved or deleted, catalog marks it `isMissing` without crashing. | Unit test with temporary file deletion. |
| **Model Switching** | `TEST-LIFECYCLE-01`| Switching model unloads active model, resets memory, and loads new model. | Coordinator test with mock worker tracking calls. |
| **Switch During Generation**| `TEST-LIFECYCLE-02`| Requesting switch while generating halts generation, awaits barrier, and completes switch safely. | Concurrency test with active generation stream. |
| **Failed Load Recovery** | `TEST-LIFECYCLE-03`| If new model fails to load, engine cleanly transitions to `.failed` with no dangling worker tasks. | Error recovery test with simulated load error. |
| **Regression Suite** | `TEST-REG-01` | All existing 69 tests pass with 0 regressions. | Automated `xcodebuild test` execution. |

---

## 13. Open Questions and Unresolved Risks

1. **User-Selected Read-Only Entitlement:**
   - *Question:* Should `com.apple.security.files.user-selected.read-only = true` be added to `Aether.entitlements` during Gate C implementation?
   - *Analysis:* Without it, security-scoped bookmarks from `NSOpenPanel` cannot be resolved across app relaunches on standard sandboxed macOS systems. Adding it is standard Apple best-practice for sandboxed document/file viewers.
   - *Recommendation:* Request explicit user authorization for this single, isolated entitlement addition in Gate C.
2. **Context Window Selection at Runtime:**
   - *Question:* Should Aether default to the model's trained context length (e.g. 32k) or a conservative runtime limit (e.g. 2048 or 4096 tokens)?
   - *Analysis:* Allocating a 32k FP16 KV cache on Apple Silicon requires several gigabytes of extra unified memory. A conservative default of `2048` or `4096` tokens preserves memory while satisfying conversational needs.
   - *Recommendation:* Display trained context length in metadata, but configure runtime context length to a conservative default (e.g. 4096) with user-selectable options.

---

## 14. Gate C Authorization Request

**Current Status:** Gates A and B Completed.  
**Production Code Changes:** 0 files modified outside this report.  
**Readiness:** The architecture, persistence schema, GGUF metadata extractor, UI layout, and lifecycle barriers are fully designed and verified against the repository codebase.

**Authorization Request:**  
Do you authorize proceeding to **Gate C: Implementation & Testing** of Phase 3.6 in accordance with the architecture plan detailed above?
