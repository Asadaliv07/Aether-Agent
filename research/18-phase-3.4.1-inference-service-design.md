# Phase 3.4.1: Inference Service Architecture & API Audit

## 1. Executive Recommendation

This report establishes the architectural and technical specification for Aether's native local inference engine, built upon the integrated `llama.xcframework` (upstream revision `547208dca250ceb3e4c8615598d043f2b602a527` / `b11718`).

### Core Architectural Decision: The Split Coordinator-Worker Architecture
We explicitly **reject** a monolithic `actor InferenceService` design where long-running synchronous C/Metal inference loops execute directly inside the actor's execution context. In Swift concurrency, executing synchronous blocking C calls (`llama_decode`) inside an actor monopolizes that actor's single-threaded mailbox; any subsequent actor message (such as an incoming `cancel()` request) is enqueued and blocked from execution until the active generation loop returns or yields. Furthermore, running long-running C/C++ loops on the cooperative thread pool violates Swift concurrency forward-progress guidelines and risks pool thread starvation.

We recommend a **Split Coordinator-Worker Architecture**:
1. **`InferenceService` (Swift Actor / Main-Thread Coordinator):** Exposes clean `async`/`await` APIs to SwiftUI (`loadModel`, `unloadModel`, `generate(prompt:) -> AsyncThrowingStream<GenerationEvent, Error>`, `cancel()`). It manages high-level lifecycle, validates state transitions, issues security-scoped bookmark resolutions, and coordinates requests.
2. **`InferenceWorker` (Dedicated Background Serial Execution Context):** Operates on a dedicated private `DispatchQueue` (`com.aether.inference.worker`, QoS `.userInitiated`). It exclusively owns the raw C pointers (`struct llama_model *`, `struct llama_context *`, `struct llama_batch`, `struct llama_sampler *`), ensuring thread safety without locking overhead or mailbox starvation.
3. **`AetherCancellationSignal` (Detached C11 Atomic Interoperability Handle):** A thread-safe, heap-allocated atomic boolean flag that can be signalled immediately and synchronously by the consumer or coordinator without waiting for any actor mailbox or queue. The raw pointer is passed to `llama.cpp`'s `ggml_abort_callback`, providing immediate abort observation across thread boundaries on macOS 14.0.

---

## 2. Verified API Findings with Source Paths

Every finding below has been directly verified against the integrated header [Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h) and the checked-out reference repository [reference-repos/01-apple-silicon-and-inference/llama.cpp](file:///Users/asadalishaikh/Aether%20Agent/reference-repos/01-apple-silicon-and-inference/llama.cpp) at commit `547208dca250ceb3e4c8615598d043f2b602a527`.

### 2.1 Backend Initialization and Cleanup `[VERIFIED FACT]`
- **Functions:**
  - `LLAMA_API void llama_backend_init(void);` ([llama.h:541](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L541))
  - `LLAMA_API void llama_backend_free(void);` ([llama.h:544](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L544))
- **Semantics:** Initializes ggml backends (including registering the Metal backend device and loading runtime Metal kernels). Must be initialized once per process lifetime or managed at the engine lifecycle boundary. `llama_backend_free()` destroys registered backends and threadpools.
- **Thread Safety:** Backend initialization modifies global registry structures; it should be called serially during engine startup, not concurrently from multiple threads.

### 2.2 Model Loading & Progress Callback `[VERIFIED FACT]`
- **Modern Non-Deprecated Functions:**
  - `LLAMA_API struct llama_model_params llama_model_default_params(void);` ([llama.h:357](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L357))
  - `LLAMA_API struct llama_model * llama_model_load_from_file(const char * path_model, struct llama_model_params params);` ([llama.h:523](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L523))
  - `LLAMA_API void llama_model_free(struct llama_model * model);` ([llama.h:553](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L553))
- **Deprecations:** `llama_load_model_from_file` and `llama_free_model` are marked `DEPRECATED` in favor of `llama_model_load_from_file` and `llama_model_free` ([llama.h:517, 550](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L517)).
- **Progress Callback:**
  - Signature: `typedef bool (*llama_progress_callback)(float progress, void * user_data);` ([llama.h:317](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L317))
  - Fields in `llama_model_params`: `params.progress_callback` and `params.progress_callback_user_data` ([llama.h:342-345](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L342-L345)).
  - Progress value: Float between `0.0` and `1.0`.
  - Abort capability: If callback returns `true`, loading continues; if `false`, model loading immediately aborts and `llama_model_load_from_file` returns `NULL`.
- **GPU Offloading Parameters:**
  - `int32_t n_gpu_layers`: Number of layers to store in VRAM. Setting to `-1` offloads all layers to Metal GPU.

### 2.3 Context Creation & Parameters `[VERIFIED FACT]`
- **Modern Non-Deprecated Functions:**
  - `LLAMA_API struct llama_context_params llama_context_default_params(void);` ([llama.h:423](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L423))
  - `LLAMA_API struct llama_context * llama_init_from_model(struct llama_model * model, struct llama_context_params params);` ([llama.h:555](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L555))
  - `LLAMA_API void llama_free(struct llama_context * ctx);` ([llama.h:562](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L562))
- **Deprecations:** `llama_new_context_with_model` is marked `DEPRECATED` in favor of `llama_init_from_model` ([llama.h:556](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L556)).
- **Key Parameters:**
  - `n_ctx`: Context window token size (e.g. 2048, 4096). If 0, uses model training default.
  - `n_batch`: Maximum logical batch size submitted to `llama_decode` (default: 2048; recommended for app: 512).
  - `n_ubatch`: Physical micro-batch size for Metal/CPU execution (default: 512).
  - `n_threads`: CPU worker threads for generation (recommended: Apple Silicon performance cores count, e.g. 4 on M-series base chips).
  - `n_threads_batch`: CPU worker threads for prompt batch processing.
  - `type_k`, `type_v`: Data types for KV cache (default `GGML_TYPE_F16`).
  - `abort_callback`, `abort_callback_data`: Pointer and callback called during execution.
- **Actual vs Requested Values:**
  - Upstream documentation explicitly warns: "After creating a `llama_context`, it is recommended to query the actual values using `llama_n_ctx(ctx)`, `llama_n_batch(ctx)` as requested values may differ" ([llama.h:577-581](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L577-L581)).

### 2.4 Critical Destruction Order `[VERIFIED FACT]`
In `src/llama-context.cpp:575-580`, the destructor `llama_context::~llama_context()` explicitly synchronizes the GPU and accesses `model.hparams.no_alloc`:
```cpp
llama_context::~llama_context() {
    synchronize();
    if (!model.hparams.no_alloc && !opt_ctx) { ... }
    ggml_opt_free(opt_ctx);
}
```
If a consumer frees the model (`llama_model_free`) before freeing the context (`llama_free`), `~llama_context()` accesses deallocated memory (`use-after-free`).
**Mandatory Destruction Order:**
1. `llama_sampler_free(sampler)`
2. `llama_batch_free(batch)`
3. `llama_free(context)`
4. `llama_model_free(model)`
5. `llama_backend_free()`

### 2.5 Tokenization and Vocab API `[VERIFIED FACT]`
- **Vocab Access:**
  - `LLAMA_API const struct llama_vocab * llama_model_get_vocab(const struct llama_model * model);` ([llama.h:596](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L596))
- **Tokenize:**
  - `LLAMA_API int32_t llama_tokenize(const struct llama_vocab * vocab, const char * text, int32_t text_len, llama_token * tokens, int32_t n_tokens_max, bool add_special, bool parse_special);` ([llama.h:1278-1285](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L1278-L1285))
  - Returns: Number of tokens on success. If output buffer is too small, returns the negative of required capacity (`-n_tokens`).
- **Token to Piece (Detokenize piece):**
  - `LLAMA_API int32_t llama_token_to_piece(const struct llama_vocab * vocab, llama_token token, char * buf, int32_t length, int32_t lstrip, bool special);` ([llama.h:1292-1298](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L1292-L1298))
  - Does NOT null-terminate the buffer. If buffer is insufficient, returns negative required length.
- **End of Generation Detection:**
  - `LLAMA_API bool llama_vocab_is_eog(const struct llama_vocab * vocab, llama_token token);` ([llama.h:1211](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L1211))
  - `llama_token_is_eog` is marked `DEPRECATED`. `llama_vocab_is_eog` correctly accounts for EOS (End of Sentence), EOT (End of Turn), and model-specific stop tokens.

### 2.6 Batch Allocation and Decode Semantics `[VERIFIED FACT]`
- **Batch Functions:**
  - `LLAMA_API struct llama_batch llama_batch_init(int32_t n_tokens, int32_t embd, int32_t n_seq_max);` ([llama.h:976](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L976))
  - `LLAMA_API void llama_batch_free(struct llama_batch batch);` ([llama.h:982](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L982))
- **Decode Execution:**
  - `LLAMA_API int32_t llama_decode(struct llama_context * ctx, struct llama_batch batch);` ([llama.h:1006](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L1006))
  - Verified Return Codes:
    - `0`: Success.
    - `1`: KV cache full (`could not find a KV slot for the batch`).
    - `2`: Aborted (`GGML_STATUS_ABORTED` via `abort_callback`).
    - `-1`: Invalid input batch (`n_tokens == 0` or dimension mismatch).
    - `-2`: Memory allocation or buffer preparation failure.
    - `-3`: General computation failure (`GGML_STATUS_FAILED`).

### 2.7 Sampler Chain API `[VERIFIED FACT]`
In revision `b11718`, sampling uses the modern chain architecture:
- `llama_sampler_chain_init(llama_sampler_chain_default_params())`
- `llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))`
- `llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))`
- `llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))`
- `llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))`
- `LLAMA_API llama_token llama_sampler_sample(struct llama_sampler * smpl, struct llama_context * ctx, int32_t idx);` ([llama.h:1646](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L1646))
- `LLAMA_API void llama_sampler_free(struct llama_sampler * smpl);` ([llama.h:1448](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L1448))
- Ownership rule: `llama_sampler_chain_add` transfers ownership of individual sampler objects to the chain; calling `llama_sampler_free` on the chain frees all children.

### 2.8 KV-Cache Memory Management `[VERIFIED FACT]`
In revision `b11718`, KV cache operations are grouped under `llama_memory_t`:
- `LLAMA_API llama_memory_t llama_get_memory(const struct llama_context * ctx);` ([llama.h:593](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L593))
- `LLAMA_API void llama_memory_clear(llama_memory_t mem, bool data);` ([llama.h:755](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L755))
- `LLAMA_API bool llama_memory_seq_rm(llama_memory_t mem, llama_seq_id seq_id, llama_pos p0, llama_pos p1);` ([llama.h:764](file:///Users/asadalishaikh/Aether%20Agent/Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Versions/Current/Headers/llama.h#L764))
- Automatic Cleanup on Error/Abort: In `src/llama-context.cpp:2020-2025`, when `decode` fails or is aborted, it automatically invokes `memory->seq_rm(s, pos_min[s], -1)` to prevent corrupt partial ubatches from polluting the active sequence state.

---

## 3. Concurrency Architecture & Cancellation Design

```
+---------------------------------------------------------------------------------------+
|                                    UI Layer (SwiftUI)                                 |
+---------------------------------------------------------------------------------------+
        |                                                                 ^
        | 1. generate(prompt:) -> Stream                                  | 5. Stream Events
        v                                                                 |    (Tokens/Stats)
+-------------------------------------------------------------+           |
|            InferenceService (Actor / Coordinator)           |-----------+
+-------------------------------------------------------------+
   | (allocates signal)                          |
   |                                             | 2. enqueue task
   v                                             v
+-----------------------+              +--------------------------------------------------+
| AetherCancellation-   |              |             InferenceWorker                      |
| Signal                |              | (Dedicated Serial DispatchQueue:                 |
| (C11 Atomic Flag)     |              |  com.aether.inference.worker)                   |
+-----------------------+              +--------------------------------------------------+
   ^              ^                       | owns raw C pointers (model, ctx, batch)
   |              |                       | executes synchronous loops
   | cancel()     | abort_callback(ptr)   v
   | (instant)    +------------------- +--------------------------------------------------+
   |                                   | llama.cpp Native Engine                          |
   +-----------------------------------| - ggml-cpu node checks                           |
   (Consumer / UI / onTermination)     | - ggml-metal command buffer boundaries           |
                                       +--------------------------------------------------+
```

### 3.1 The Mailbox Starvation Hazard & Resolution
If `InferenceService` were a standard Swift `actor` whose methods run the C loop:
```swift
// REJECTED PATTERN
actor BadInferenceService {
    func generate(prompt: String) {
        while !done {
            llama_decode(ctx, batch) // BLOCKING SYNCHRONOUS C CALL
            // Actor mailbox is completely frozen here!
        }
    }
    func cancel() { // CANNOT BE PROCESSED UNTIL WHILE LOOP FINISHES!
        isCancelled = true
    }
}
```
In this rejected pattern, `cancel()` cannot execute because the single thread assigned to the actor is blocked executing `llama_decode()`.

**The Approved Architecture:**
1. **Coordinator Actor (`InferenceService`):**
   - Coordinates state (`idle`, `loading`, `ready`, `generating`, `error`).
   - Rejects overlapping generation requests (`case generationInProgress`).
   - Creates a dedicated `AetherCancellationSignal` instance for each generation run.
   - Dispatches the generation execution to the private worker queue.
   - Returns an `AsyncThrowingStream` whose `onTermination` handler triggers `signal.cancel()` directly.
2. **Dedicated Worker Queue (`InferenceWorker`):**
   - Serial `DispatchQueue(label: "com.aether.inference.worker", qos: .userInitiated)`.
   - Never blocks Swift's shared cooperative thread pool.
   - Pointers (`llama_context *`, etc.) are owned exclusively within this queue, avoiding multi-threaded data races.
3. **Detached Atomic Cancellation Handle (`AetherCancellationSignal`):**
   - Holds a heap-allocated C11 atomic flag.
   - When the user cancels via UI, or the stream consumer cancels the task, `signal.cancel()` is called synchronously from ANY thread.
   - Setting the atomic flag is an instant, wait-free memory write (`memory_order_release`).
   - Does not touch the actor mailbox or wait for queue processing.

### 3.2 Honest Cancellation: CPU vs. Metal Semantics `[VERIFIED FACT]`
The checked-out source reveals fundamentally different cancellation semantics depending on the execution backend:

#### CPU Execution (`ggml-cpu.c:3150`)
```c
if (state->ith == 0 && cplan->abort_callback && cplan->abort_callback(cplan->abort_callback_data)) {
    atomic_store_explicit(&tp->abort, node_n + 1, memory_order_relaxed);
    tp->ec = GGML_STATUS_ABORTED;
}
```
- **Granularity:** Per computation graph node (`ggml_compute_forward`).
- **Latency:** Microseconds to low milliseconds during prompt processing and decode. CPU worker threads exit promptly upon checking the abort flag.

#### Metal GPU Execution (`ggml-metal-context.m:586, 644`)
```objc
if (cb_idx < 2 || ctx->abort_callback == NULL) {
    [cmd_buf enqueue];
}
...
if (ctx->abort_callback && ctx->abort_callback(ctx->abort_callback_data)) {
    GGML_LOG_INFO("%s: command buffer %d aborted", __func__, i);
    return GGML_STATUS_ABORTED;
}
[next_buffer commit];
```
- **Granularity:** Per command buffer commit. The first two command buffers in a graph evaluation are *always* enqueued.
- **In-Flight Shaders:** Once a Metal command buffer is committed to the GPU hardware command queue (`[next_buffer commit]`), it runs to hardware completion. Metal does *not* provide an interrupt mechanism to abort in-flight compute kernels without terminating the Metal device.
- **Latency:** Cancellation takes effect between command buffer boundaries or at the token boundary.

#### Mandatory Teardown Synchronization
If cancellation occurs during or immediately after a Metal dispatch:
1. `llama_decode()` returns `2` (`GGML_STATUS_ABORTED`).
2. The host must call `llama_synchronize(ctx)` (which calls `[cmd_buf_last waitUntilCompleted]`) before releasing any buffers, resetting the KV cache, or freeing memory.
3. Attempting to immediately destroy the context or clear GPU buffers while command buffers are in flight triggers a Metal command buffer failure or kernel panic (`use-after-free`).

### 3.3 The C11 Atomic Interoperability Shim for macOS 14.0
Because Aether targets macOS 14.0, the Swift 6 `Synchronization.Atomic` type (requiring macOS 15.0+) cannot be used. We specify a minimal C11 shim:

**Header: `Aether/Bridging/aether_atomic.h` (Design only, implementation in Phase 3.4.2):**
```c
#ifndef AETHER_ATOMIC_H
#define AETHER_ATOMIC_H

#include <stdatomic.h>
#include <stdbool.h>

typedef struct aether_atomic_flag {
    atomic_bool value;
} aether_atomic_flag_t;

static inline void aether_atomic_flag_init(aether_atomic_flag_t * flag, bool initial) {
    atomic_init(&flag->value, initial);
}

static inline void aether_atomic_flag_set(aether_atomic_flag_t * flag, bool val) {
    atomic_store_explicit(&flag->value, val, memory_order_release);
}

static inline bool aether_atomic_flag_get(const aether_atomic_flag_t * flag) {
    return atomic_load_explicit(&flag->value, memory_order_acquire);
}

static inline bool aether_abort_callback(void * data) {
    if (!data) return false;
    return aether_atomic_flag_get((const aether_atomic_flag_t *)data);
}

#endif // AETHER_ATOMIC_H
```
- **Ownership & Lifetime:** An `aether_atomic_flag_t` is allocated on the heap inside a Swift `final class CancellationSignal` deallocated only when the generation task completes its teardown. The pointer passed to `llama_set_abort_callback` remains valid for the exact duration of the generation run.

---

## 4. Swift Interface & Typed Error Specifications

### 4.1 Typed Errors (`InferenceError`)
```swift
public enum InferenceError: LocalizedError, Sendable {
    case modelNotFound(URL)
    case securityScopedAccessDenied(URL)
    case modelLoadFailed(reason: String)
    case contextInitializationFailed(reason: String)
    case contextExhausted(promptTokens: Int, maxContext: Int)
    case tokenizationFailed(reason: String)
    case decodeFailed(code: Int32, description: String)
    case cancelled
    case generationInProgress
    case modelNotLoaded
    case memoryPressureCritical
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let url):
            return "Model file does not exist at path: \(url.path)"
        case .securityScopedAccessDenied(let url):
            return "Failed to acquire security-scoped access for: \(url.path)"
        case .modelLoadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .contextInitializationFailed(let reason):
            return "Failed to allocate inference context: \(reason)"
        case .contextExhausted(let promptTokens, let maxContext):
            return "Prompt exceeds context window (\(promptTokens) tokens > \(maxContext) max context)"
        case .tokenizationFailed(let reason):
            return "Tokenization error: \(reason)"
        case .decodeFailed(let code, let description):
            return "Inference evaluation failed (code \(code)): \(description)"
        case .cancelled:
            return "Generation was cancelled"
        case .generationInProgress:
            return "Another generation request is currently active"
        case .modelNotLoaded:
            return "No model is loaded into memory"
        case .memoryPressureCritical:
            return "Operation aborted due to critical system memory pressure"
        case .internalError(let msg):
            return "Internal inference error: \(msg)"
        }
    }
}
```

### 4.2 Configuration & Parameter Models
```swift
public struct ModelConfiguration: Sendable {
    public let contextLength: UInt32      // e.g. 2048, 4096 (0 = model default)
    public let batchSize: UInt32          // e.g. 512
    public let gpuLayers: Int32           // -1 = all layers to Metal
    public let threadCount: Int32         // e.g. 4 for M5 base cores

    public static let conservative = ModelConfiguration(
        contextLength: 2048,
        batchSize: 512,
        gpuLayers: -1,
        threadCount: 4
    )
}

public struct GenerationParameters: Sendable {
    public let maxTokens: Int
    public let temperature: Float
    public let topK: Int32
    public let topP: Float
    public let seed: UInt32

    public static let standard = GenerationParameters(
        maxTokens: 512,
        temperature: 0.7,
        topK: 40,
        topP: 0.95,
        seed: 42
    )
}

public enum GenerationEvent: Sendable {
    case token(String)
    case completed(stats: GenerationStats)
}

public struct GenerationStats: Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let promptEvalTimeMs: Double
    public let tokenGenTimeMs: Double
    public let tokensPerSecond: Double
}
```

### 4.3 Public Service Protocol
```swift
public protocol InferenceServiceProtocol: Sendable {
    var state: InferenceServiceState { get async }
    
    func loadModel(from url: URL, configuration: ModelConfiguration, progress: (@Sendable (Float) -> Void)?) async throws
    func unloadModel() async throws
    func generate(prompt: String, parameters: GenerationParameters) -> AsyncThrowingStream<GenerationEvent, Error>
    func cancel() async
}

public enum InferenceServiceState: Sendable, Equatable {
    case uninitialized
    case loading(progress: Float)
    case ready(modelName: String, contextLength: UInt32)
    case generating(promptTokens: Int, tokensGenerated: Int)
    case cancelling
    case error(String)
}
```

---

## 5. Memory & Hardware Policy

### 5.1 Target Hardware Analysis
- **Primary Deployment Target:** Apple M5 MacBook Air with 16 GB Unified Memory.
- **Constrained Target:** Base Apple Silicon with 8 GB Unified Memory (M1/M2/M3 8 GB).

### 5.2 Unified Memory Budget & System Demands `[ESTIMATED]`
On macOS 14 / 15:
- macOS kernel, WindowServer, AppKit/SwiftUI runtime, and background system daemons require `2.5 GB – 3.2 GB` of memory baseline `[ESTIMATED]`.
- Available headroom for user applications:
  - **16 GB Mac:** `~12.5 GB` safe application allocation headroom `[CALCULATED]`.
  - **8 GB Mac:** `~4.5 GB – 4.8 GB` safe application allocation headroom `[CALCULATED]`.

### 5.3 Mathematical Memory Footprint Calculations `[CALCULATED]`

#### Model Weights
- **3B Parameter Model (e.g. Llama 3.2 3B) in Q4_K_M (~4.5 bpw):** `~2.05 GB` `[CALCULATED]`
- **3B Parameter Model in Q8_0 (~8.5 bpw):** `~3.35 GB` `[CALCULATED]`
- **8B Parameter Model (e.g. Llama 3.1 8B) in Q4_K_M (~4.5 bpw):** `~4.92 GB` `[CALCULATED]`
- **8B Parameter Model in Q8_0 (~8.5 bpw):** `~8.45 GB` `[CALCULATED]`

#### KV-Cache Formula `[VERIFIED FACT]`
$$\text{KV Size (bytes)} = 2 \times n_{\text{layers}} \times n_{\text{kv\_heads}} \times d_{\text{head}} \times n_{\text{ctx}} \times \text{bytes\_per\_element}$$

For an **8B GQA Model** ($n_{\text{layers}}=32, n_{\text{kv\_heads}}=8, d_{\text{head}}=128 \implies 65,536 \text{ elements/token}$):
- **f16 (2 bytes/elem):** $131,072 \text{ bytes/token} = 128 \text{ KB/token}$.
  - At $n_{\text{ctx}} = 2048$: $256 \text{ MB}$ `[CALCULATED]`.
  - At $n_{\text{ctx}} = 4096$: $512 \text{ MB}$ `[CALCULATED]`.
  - At $n_{\text{ctx}} = 8192$: $1,024 \text{ MB} (1.0 \text{ GB})$ `[CALCULATED]`.
- **q8_0 (1 byte/elem):**
  - At $n_{\text{ctx}} = 4096$: $256 \text{ MB}$ `[CALCULATED]`.

For a **3B GQA Model** ($n_{\text{layers}}=28, n_{\text{kv\_heads}}=8, d_{\text{head}}=128 \implies 57,344 \text{ elements/token}$):
- **f16:** $114,688 \text{ bytes/token} = 112 \text{ KB/token}$.
  - At $n_{\text{ctx}} = 2048$: $224 \text{ MB}$ `[CALCULATED]`.
  - At $n_{\text{ctx}} = 4096$: $448 \text{ MB}$ `[CALCULATED]`.

#### Graph Allocations & Metal Command Buffers `[ESTIMATED]`
- Activation tensors, logits buffer (`n_vocab * sizeof(float)` $\approx 128,256 \times 4 \approx 513 \text{ KB}$), Metal scratch memory: `~250 MB – 400 MB` `[ESTIMATED]`.

### 5.4 Tier Compatibility Matrix

| Hardware Tier | Model Class | Quantization | Context ($n_{\text{ctx}}$) | Total Memory Required | Safe Headroom Status | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **8 GB Apple Silicon** | **3B** | **Q4_K_M** | **2048** | **~2.6 GB** | Safe (4.8 GB avail) | **RECOMMENDED TIER BASELINE** |
| 8 GB Apple Silicon | 3B | Q4_K_M | 4096 | ~2.9 GB | Moderate | Supported |
| 8 GB Apple Silicon | 8B | Q4_K_M | 2048 | ~5.6 GB | Exceeds 4.8 GB budget | **REJECTED (Severe Swap / Jetsam)** |
| **16 GB M5 Mac** | **8B** | **Q4_K_M** | **4096** | **~5.9 GB** | Safe (12.5 GB avail) | **RECOMMENDED PRIMARY TIER** |
| 16 GB M5 Mac | 8B | Q4_K_M | 8192 | ~6.4 GB | Safe | Supported |
| 16 GB M5 Mac | 8B | Q8_0 | 4096 | ~9.4 GB | Moderate | Supported for advanced users |

> [!WARNING]
> CPU fallback does NOT solve memory pressure on Apple Silicon unified memory! The CPU and GPU share the exact same physical DRAM. Offloading layers from Metal to CPU saves zero RAM and results in a severe performance penalty.

### 5.5 Runtime macOS Memory Pressure Handling
On macOS 14.0+, the engine monitors system memory pressure using Grand Central Dispatch:
```swift
let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: workerQueue)
source.setEventHandler { [weak self] in
    let event = source.data
    if event.contains(.critical) {
        self?.handleCriticalMemoryPressure()
    } else if event.contains(.warning) {
        self?.handleMemoryPressureWarning()
    }
}
source.resume()
```
- **Policy on `.warning`:** Throttle active context window expansion; prevent speculative context allocation.
- **Policy on `.critical`:** If idle, immediately unload model and free context (`llama_free`, `llama_model_free`); if generating, trigger `cancel()` and return `.memoryPressureCritical`.

---

## 6. Model Storage & App Sandbox Compliance

### 6.1 Containerized Storage (`Application Support`)
Under the active App Sandbox (`com.apple.security.app-sandbox = true`):
- **Path:** `~/Library/Containers/com.aether.Aether/Data/Library/Application Support/com.aether.Aether/Models/`
- Direct POSIX file reads via `llama_model_load_from_file` succeed without extra permissions because this directory is inside the application's assigned sandbox container.

### 6.2 External User-Selected Model Access (`NSOpenPanel`)
Under the configured user-selected file entitlement (`com.apple.security.files.user-selected.read-write = true`):
1. **Acquiring Access:**
   When the user selects a `.gguf` file outside the sandbox (e.g. `~/Downloads` or external SSD):
   ```swift
   guard url.startAccessingSecurityScopedResource() else {
       throw InferenceError.securityScopedAccessDenied(url)
   }
   defer { url.stopAccessingSecurityScopedResource() }
   ```
2. **Persistent Access via Security-Scoped Bookmarks:**
   To reload user-selected models across application relaunches without re-prompting:
   ```swift
   let bookmarkData = try url.bookmarkData(
       options: .withSecurityScope,
       includingResourceValuesForKeys: nil,
       relativeTo: nil
   )
   UserDefaults.standard.set(bookmarkData, forKey: "saved_model_bookmark")
   ```
   On subsequent launches, resolve the bookmark with `.withSecurityScope` before invoking `llama_model_load_from_file`.

---

## 7. Testing Strategy & Validation Matrix

Implementation of tests is deferred to Phase 3.4.2; the test matrix below defines the required test coverage:

| Category | Test Case | Target API / Mechanism | Verification Method |
| :--- | :--- | :--- | :--- |
| **Unit** | Atomic Flag Concurrency | `aether_atomic_flag` | Multi-threaded race test (100 parallel readers/writers) |
| **Unit** | State Machine Invariants | `InferenceServiceState` | Verify invalid transitions (e.g. generate while loading) throw typed errors |
| **Unit** | Error Code Mapping | `InferenceError` | Map C return codes `1, 2, -1, -2, -3` to Swift enum cases |
| **Unit** | UTF-8 Streaming Chunking | Multi-byte UTF-8 accumulator | Feed split emoji bytes across token boundaries; verify valid character emission |
| **Integration** | Model Load & Unload | `llama_model_load_from_file` | Verify memory allocation and zero leaks across 10 repeated cycles |
| **Integration** | Destruction Order | `llama_free` before `llama_model_free` | Verify AddressSanitizer (ASan) reports zero heap-use-after-free |
| **Integration** | Prompt Tokenization | `llama_tokenize` | Tokenize known prompt; assert token count and BOS/EOS handling |
| **Integration** | Token Streaming | `AsyncThrowingStream` | Collect streamed tokens; assert identical concatenated output |
| **Integration** | Immediate Cancellation | `signal.cancel()` before decode | Ensure decode loop never starts; stream throws `.cancelled` |
| **Integration** | Mid-Generation Cancellation | `abort_callback` during decode | Verify `llama_decode` returns `2`; KV cache cleaned; GPU synchronized |
| **Integration** | Context Exhaustion | Submit prompt > $n_{\text{ctx}}$ | Assert `InferenceError.contextExhausted` without process crash |
| **Lifecycle** | Sudden App Termination | Terminate during generation | Verify `llama_synchronize` is invoked; no GPU hang or kernel fault |

---

## 8. Risks, Unresolved Questions & Rejected Alternatives

### 8.1 Rejected Alternatives
1. **Monolithic `actor InferenceService`:** Rejected due to actor mailbox blocking during long synchronous C calls, preventing responsive cancellation and starving the Swift cooperative thread pool.
2. **Swift 6 `Synchronization.Atomic`:** Rejected because it requires macOS 15.0+, violating Aether's macOS 14.0 deployment baseline.
3. **Swift `Task.yield()` Inside C Callback:** Rejected because `ggml_abort_callback` is an `@convention(c)` synchronous C function that cannot invoke async Swift tasks or bridge to Swift concurrency runtimes.
4. **Immediate GPU Kill / Context Deallocation:** Rejected because Metal command buffers committed to the GPU hardware queue cannot be force-killed; freeing memory while buffers are in-flight causes kernel panics or GPU page faults.

### 8.2 Managed Risks & Safeguards
- **Risk:** Multi-byte UTF-8 characters split across token boundaries produce invalid unicode in SwiftUI text rendering.
  - **Safeguard:** Implement a byte-buffer accumulator in the worker that buffers incomplete UTF-8 byte sequences until a valid Unicode scalar is formed before emitting to `AsyncThrowingStream`.
- **Risk:** Memory spike on 8 GB Macs causes sudden Jetsam OOM kill.
  - **Safeguard:** Hard cap $n_{\text{ctx}} = 2048$ on 8 GB Macs; reject models $> 3.5\text{ GB}$ on the 8 GB tier; monitor GCD memory pressure sources.

---

## 9. Proposed Implementation Sequence for Phase 3.4.2

1. **Step 1: C11 Atomic Shim Integration**
   - Add `Aether/Bridging/aether_atomic.h` to the Xcode project.
   - Verify C11 memory ordering and Swift bridging header accessibility.
2. **Step 2: Core Domain Models & Errors**
   - Implement `InferenceError.swift`, `ModelConfiguration.swift`, and `GenerationParameters.swift` in `Aether/Sources/Inference/Models/`.
3. **Step 3: Low-Level Engine Wrapper (`LlamaEngine`)**
   - Implement the dedicated serial worker queue wrapper owning raw `llama.h` pointers.
   - Implement strictly ordered destruction (`llama_sampler_free` $\rightarrow$ `llama_batch_free` $\rightarrow$ `llama_free` $\rightarrow$ `llama_model_free`).
   - Implement tokenization, decode loop, UTF-8 streaming accumulator, and abort callback bridging.
4. **Step 4: High-Level `InferenceService` Coordinator**
   - Implement the public `InferenceService` actor conforming to `InferenceServiceProtocol`.
   - Wire `AsyncThrowingStream` with `onTermination` cancellation dispatch.
5. **Step 5: Compilation & Headless Lifecycle Validation**
   - Verify `xcodebuild -scheme Aether -configuration Debug build`.
   - Run unit tests covering lifecycle, atomic flag contention, and state transitions.
