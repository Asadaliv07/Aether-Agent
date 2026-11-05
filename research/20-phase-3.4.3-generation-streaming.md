# Aether — Phase 3.4.3: Controlled Text Generation, Streaming & Cancellation Report

**Document ID:** `research/20-phase-3.4.3-generation-streaming.md`  
**Date:** 2026-10-18  
**Platform:** macOS 14.0+ (Apple Silicon)  
**Pinned upstream revision:** `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`)  
**Integrated framework:** `Aether/Frameworks/llama.xcframework`  
**Status:** Verification, Implementation, and Test Suite Complete

---

## 1. Files Created and Modified

### Created Files
1. [`Aether/Sources/Inference/AetherAtomic.h`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/AetherAtomic.h)
   - C11 `<stdatomic.h>` interface defining `AetherAtomicFlag` opaque struct, creation/destruction functions, atomic acquire/release setters and getters, and the C-compatible `aether_abort_callback` function pointer matching `ggml_abort_callback`.
2. [`Aether/Sources/Inference/AetherAtomic.c`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/AetherAtomic.c)
   - C11 implementation allocating `atomic_bool` on the heap and implementing `atomic_load_explicit` / `atomic_store_explicit` with `memory_order_acquire` / `memory_order_release`.
3. [`Aether/Sources/Inference/Aether-Bridging-Header.h`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/Aether-Bridging-Header.h)
   - Objective-C / C bridging header importing `AetherAtomic.h` for use within Swift code.
4. [`Aether/Sources/Inference/CancellationSignal.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/CancellationSignal.swift)
   - Swift `@unchecked Sendable` wrapper managing the lifecycle of `AetherAtomicFlag`. Manages heap allocation/deallocation and provides safe cross-thread cancellation signaling.
5. [`Aether/Sources/Inference/GenerationConfiguration.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/GenerationConfiguration.swift)
   - Strongly-typed, range-validated configuration struct defining `contextLength`, `maxTokens`, `temperature`, `topK`, `topP`, and `seed`.
6. [`Aether/Sources/Inference/GenerationEvent.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/GenerationEvent.swift)
   - Enum expressing lifecycle events: `.chunk(String)`, `.completed`, `.cancelled`, and `.failed(InferenceError)`.
7. [`Aether/Tests/InferenceGenerationTests.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Tests/InferenceGenerationTests.swift)
   - Automated test suite covering parameter validation, ordered chunk delivery, token limits, consumer early termination, cancellation recovery, conflict handling, and native worker error resilience.

### Modified Files
1. [`Aether/Sources/Inference/InferenceError.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceError.swift)
   - Added specific error cases: `.invalidPrompt`, `.invalidConfiguration`, `.contextInitializationFailed`, `.contextExhausted`, `.tokenizationFailed`, `.decodeFailed`, and `.cancelled`.
2. [`Aether/Sources/Inference/InferenceState.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceState.swift)
   - Added `.generating(modelInfo: ModelInfo)` state case with appropriate `Equatable` conformance and description.
3. [`Aether/Sources/Inference/InferenceWorkerProtocol.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceWorkerProtocol.swift)
   - Added `generate(prompt:configuration:cancellationSignal:onToken:) async throws` requirement.
4. [`Aether/Sources/Inference/LlamaInferenceWorker.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift)
   - Implemented context creation via `llama_init_from_model`, prompt tokenization via `llama_tokenize`, evaluation batching via `llama_batch_init` and `llama_decode`, deterministic sampler chain (`llama_sampler_chain_init`, `llama_sampler_init_greedy`, `llama_sampler_init_temp`), incremental decoding loop, multi-byte UTF-8 preservation buffering, `llama_set_abort_callback`, `llama_synchronize` synchronization, and safe cleanup via `llama_memory_clear`.
5. [`Aether/Sources/Inference/InferenceService.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift)
   - Implemented `generate(prompt:configuration:) -> InferenceStream`, `activeCancellationSignal` state tracking, `InferenceStream` sequence abstraction, and `StreamIteratorTracker` using `OSAllocatedUnfairLock` to ensure consumer early exit (`break`) triggers cooperative cancellation.
6. [`Aether/Tests/InferenceLifecycleTests.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Tests/InferenceLifecycleTests.swift)
   - Updated `MockInferenceWorker` to implement the new `InferenceWorkerProtocol.generate` method.
7. [`Aether.xcodeproj/project.pbxproj`](file:///Users/asadalishaikh/Aether%20Agent/Aether.xcodeproj/project.pbxproj)
   - Linked `AetherAtomic.h`, `AetherAtomic.c`, `Aether-Bridging-Header.h`, `CancellationSignal.swift`, `GenerationConfiguration.swift`, `GenerationEvent.swift`, and `InferenceGenerationTests.swift`. Configured `SWIFT_OBJC_BRIDGING_HEADER`.

---

## 2. Verified Native APIs Used

All APIs were verified directly against `Aether/Frameworks/llama.xcframework/macos-arm64/llama.framework/Headers/` and pinned upstream revision `547208dca250ceb3e4c8615598d043f2b602a527`:

| Category | Native Function / Type | Header Location | Verified Behavior & Notes |
|---|---|---|---|
| **Context** | `llama_context_default_params()` | `llama.h` | Returns default context parameters. `n_ctx` is explicitly assigned from `configuration.contextLength`. |
| **Context** | `llama_init_from_model(model, params)` | `llama.h` | Returns `OpaquePointer?` (`llama_context *`). Worker verifies non-null or throws `.contextInitializationFailed`. |
| **Context** | `llama_free(ctx)` | `llama.h` | Destroys native context. Safely invoked in `deinit`, during model unload, and on context recreation. |
| **KV Cache** | `llama_memory_clear(llama_get_memory(ctx), true)` | `llama.h` | Replaces deprecated `llama_kv_cache_clear`. Resets all sequence memory and cache for subsequent generations. |
| **Synchronization** | `llama_synchronize(ctx)` | `llama.h` | Flushes and waits for all active Metal command buffers to complete before memory cleanup or context reset. |
| **Tokenization** | `llama_model_get_vocab(model)` | `llama.h` | Retrieves the vocabulary pointer for tokenization and piece conversion. |
| **Tokenization** | `llama_tokenize(vocab, text, len, tokens, max, add_special, parse_special)` | `llama.h` | Two-pass tokenization: first call with `max = 0` calculates required count (returned as negative int). Second pass populates allocated `[llama_token]` buffer. Throws `.tokenizationFailed` if negative or zero. |
| **Batching** | `llama_batch_init(n_tokens, embd, n_seq_max)` | `llama.h` | Allocates batch struct. Prompt tokens evaluated in single initial batch; subsequent tokens evaluated 1 at a time. |
| **Batching** | `llama_batch_free(batch)` | `llama.h` | Destroys native batch allocation upon exit. |
| **Decoding** | `llama_decode(ctx, batch)` | `llama.h` | Decodes batch. Return code `0` indicates success; non-zero indicates failure or context limit reached (code `1`). |
| **Sampler** | `llama_sampler_chain_init(params)` | `llama.h` | Creates a sampler chain container. Owned and destroyed via `llama_sampler_free`. |
| **Sampler** | `llama_sampler_init_greedy()` | `llama.h` | Deterministic greedy sampling when `temperature <= 0`. |
| **Sampler** | `llama_sampler_init_temp(temp)` | `llama.h` | Temperature-based sampling when `temperature > 0`. |
| **Sampler** | `llama_sampler_init_top_k(k)` / `top_p(p, min_keep)` | `llama.h` | Added to chain when non-greedy sampling is configured. |
| **Sampler** | `llama_sampler_sample(chain, ctx, idx)` | `llama.h` | Samples the next token from logits at batch index `-1`. |
| **Sampler** | `llama_sampler_accept(chain, token)` | `llama.h` | Informs the sampler chain of accepted token for repetition tracking. |
| **Vocabulary** | `llama_vocab_is_eog(vocab, token)` | `llama.h` | Modern non-deprecated check for end-of-generation / EOS tokens. |
| **Vocabulary** | `llama_vocab_is_control(vocab, token)` | `llama.h` | Checks if a token is a control/special token to avoid streaming control bytes. |
| **Token-to-Piece**| `llama_token_to_piece(vocab, token, buf, len, lstrip, special)` | `llama.h` | Converts token ID to UTF-8 piece bytes into a temporary buffer. Sized using negative return contract. |
| **Abort Callback**| `llama_set_abort_callback(ctx, cb, data)` | `llama.h` | Registers `aether_abort_callback` and `AetherAtomicFlag *` context. Checked at native iteration boundaries. |

---

## 3. Context, Tokenization, Sampling, and Decoding Lifecycle

```
[Prompt String]
       │
       ▼
[Validate Configuration & Prompt]
       │
       ▼
[llama_tokenize (Calculate size -> Allocate buffer -> Tokenize)]
       │
       ▼
[Context Capacity Check: promptTokens.count + maxTokens <= n_ctx]
       │
       ▼
[Create Context (llama_init_from_model) / Reset Existing (llama_memory_clear)]
       │
       ▼
[Set Abort Callback (llama_set_abort_callback)]
       │
       ▼
[Initialize Sampler Chain (Greedy or Temp/Top-K/Top-P)]
       │
       ▼
[Populate Prompt Batch (llama_batch_init) -> llama_decode(prompt)]
       │
       ┌───────────────────────────────┐
       ▼                               │
[Sample Next Token (llama_sampler_sample)]
       │
       ▼
[EOG Check (llama_vocab_is_eog)?] ──Yes──► [Break Loop]
       │ No
       ▼
[Multi-Byte UTF-8 Buffer & Stream Piece]
       │
       ▼
[Max Tokens Reached?] ──Yes──────────────► [Break Loop]
       │ No
       ▼
[Cancellation Signaled?] ──Yes───────────► [Break Loop & Throw .cancelled]
       │ No
       ▼
[Decode Single Token Batch (llama_decode)]
       │
       └───────────────────────────────┘
                               │
                               ▼
            [llama_synchronize(ctx) (flush Metal buffers)]
                               │
                               ▼
            [Free Sampler Chain & Batch Allocation]
                               │
                               ▼
            [llama_memory_clear(ctx) (Clean state for next turn)]
```

### Prompt Tokenization
- Two-pass tokenization prevents buffer truncation. First invocation passes `0` length; native code returns the required negative count. An exact buffer is allocated and populated on the second call.
- Validates prompt length against context capacity before issuing native compute calls.

### Sampler Configuration
- Default configuration uses `temperature: 0.0`, resulting in a deterministic greedy sampler (`llama_sampler_init_greedy`).
- When `temperature > 0.0`, the sampler chain is configured with `top_k`, `top_p`, and `temp`.
- Sampler chain is freed at the end of generation via `llama_sampler_free(samplerChain)`.

### Multi-byte UTF-8 Handling
- Token pieces in BPE and SPM vocabularies may slice multibyte UTF-8 codepoints across token boundaries (e.g. emoji or non-Latin characters).
- `LlamaInferenceWorker` maintains a persistent `temporaryInvalidCChars: [CChar]` buffer across the generation loop. If `String(validatingUTF8:)` fails on a piece, bytes are preserved and combined with the subsequent token until a valid sequence is formed. Any trailing valid bytes are flushed at stream completion.

---

## 4. Streaming Contract and Termination Behavior

### Stream Abstraction: `InferenceStream`
- Generation is exposed via `InferenceService.generate(prompt:configuration:) -> InferenceStream`.
- `InferenceStream` conforms to `AsyncSequence` and delivers incremental `String` chunks.
- Internally wraps an `AsyncThrowingStream<String, Error>` and attaches an `activeCancellationSignal`.

### Termination & Consumer Scenarios
1. **Normal Completion:**
   - Worker detects `llama_vocab_is_eog(token)` or reaches `configuration.maxTokens`.
   - Flushes remaining UTF-8 piece buffer.
   - Restores service state to `.loaded(modelInfo)`.
   - Closes continuation with `.finish()`.
2. **Consumer Early Termination (`break` / return / error in consumer):**
   - Tracked via `StreamIteratorTracker` using `OSAllocatedUnfairLock`.
   - When the consumer's `for try await` loop breaks, the iterator deallocates immediately.
   - `tracker.deinit` signals `signal.cancel()`.
   - The worker observes cancellation at the next token boundary or abort callback, halts decoding, calls `llama_synchronize(ctx)`, clears memory, and throws `InferenceError.cancelled`.
   - Service state cleanly restores to `.loaded(modelInfo)`.
3. **Consumer Task Cancellation:**
   - When the consumer `Task` is cancelled, `InferenceStream.AsyncIterator.next()` detects `Task.isCancelled`, triggers `signal.cancel()`, and throws `CancellationError`.
4. **Second Generation Arrives While Active:**
   - Guarded by `InferenceService` actor state machine. Throws `InferenceError.conflictingOperation("A generation operation is already in progress.")`.
5. **Model Unload During Generation:**
   - `InferenceService.unloadModel()` checks state. Throws `InferenceError.conflictingOperation("Cannot unload a model while text generation is in progress.")`.
6. **App Shutdown:**
   - `InferenceService.shutdown()` cancels `activeCancellationSignal`, waits for worker completion, unloads the model, and shuts down backend subsystems.

---

## 5. Cancellation Implementation and Backend Limitations

### Atomic Signal Architecture
- Swift actors cannot guarantee synchronous preemption of synchronous native loops.
- `AetherAtomicFlag` is implemented in C11 (`<stdatomic.h>`) as an opaque heap-allocated `atomic_bool`.
- Cross-thread reads and writes use `atomic_load_explicit(&flag->value, memory_order_acquire)` and `atomic_store_explicit(&flag->value, val, memory_order_release)`.
- Swift manages the pointer safely using `CancellationSignal`, an `@unchecked Sendable` final class with heap cleanup in `deinit`.

### Abort Callback Behavior
- `aether_abort_callback(void * data)` matches `ggml_abort_callback(void * data) -> bool`.
- Registered with the native context via `llama_set_abort_callback(ctx, aether_abort_callback, rawFlag)`.
- Upstream `llama.cpp` calls this callback periodically during graph computation.

### Metal Backend Limitations (Apple Silicon)
- **Non-Preemptive Command Buffers:** While CPU inference checks the abort callback between graph nodes, Metal encodes and submits GPU command buffers to Apple Silicon unified memory.
- An in-flight Metal command buffer cannot be forcefully interrupted mid-dispatch by an abort callback without destabilizing the GPU device context.
- Cancellation waits for the currently submitted command buffer to finish execution before returning.
- `llama_synchronize(ctx)` is explicitly invoked during cleanup to ensure all outstanding Metal operations have retired before context state or memory is altered.

---

## 6. Resource Cleanup and Recovery Guarantees

1. **Sole Ownership:**
   - `LlamaInferenceWorker` exclusively owns `llama_context *`, `llama_batch`, and `llama_sampler *`.
   - No native pointers ever escape worker isolation.
2. **Post-Cancellation State Recovery:**
   - When cancelled, the generation loop exits cleanly.
   - Calls `llama_synchronize(ctx)`.
   - Calls `llama_memory_clear(llama_get_memory(ctx), true)` to clear KV cache sequence allocations.
   - Frees batch and sampler chain allocations.
   - Leaves the context initialized and ready for immediate reuse in subsequent generation requests without requiring a model reload.
3. **Destruction Order:**
   - `llama_sampler_free(sampler)` -> `llama_batch_free(batch)` -> `llama_free(context)` -> `llama_model_free(model)` -> `llama_backend_free()`.
   - Strictly conforms to upstream memory hierarchy.

---

## 7. Tests Executed and Actual Outcomes

### Test Execution Command
```bash
xcodebuild test -project Aether.xcodeproj -scheme Aether -destination "platform=macOS"
```

### Results Summary
- **Total Test Cases Executed:** 20
- **Passed:** 20
- **Failed:** 0
- **Total Time:** 0.541s

### Test Suite Breakdown

#### `InferenceGenerationTests` (9 Tests — All Passed)
1. `testEmptyPromptThrowsInvalidPrompt`: Passed (0.001s)
   - Validates that empty string prompts are rejected prior to native worker invocation.
2. `testWhitespaceOnlyPromptThrowsInvalidPrompt`: Passed (0.001s)
   - Validates that whitespace-only prompts are rejected with `.invalidPrompt`.
3. `testInvalidConfigurationsThrow`: Passed (0.001s)
   - Validates rejection of `contextLength <= 0`, `maxTokens <= 0`, negative `topK`, and invalid `topP` ranges.
4. `testGenerateWhenNotLoadedThrows`: Passed (0.001s)
   - Validates that attempting to generate text before a model is loaded throws `.notLoaded`.
5. `testSuccessfulGenerationStreamingInOrder`: Passed (0.012s)
   - Validates incremental delivery of chunks in exact chronological order and verifies service state transitions from `.loaded` to `.generating` to `.loaded`.
6. `testMaxTokensEnforcement`: Passed (0.001s)
   - Verifies that token emission stops precisely at `maxTokens` regardless of available sequence length.
7. `testConsumerEarlyTerminationTriggersCancellation`: Passed (0.071s)
   - Tests breaking from consumer loop after 2 tokens. Validates iterator deallocation, atomic signal firing, clean worker exit, and service recovery to `.loaded`.
8. `testSubsequentGenerationAfterCancellationSucceeds`: Passed (0.052s)
   - Confirms that cancellation leaves the worker in a clean state and that a subsequent generation succeeds without model reload.
9. `testConcurrentGenerationRejected`: Passed (0.001s)
   - Validates that issuing a second `generate` while one is active throws `InferenceError.conflictingOperation`.

#### `InferenceLifecycleTests` (11 Tests — All Passed)
1. `testInitialStateIsUnloaded`: Passed (0.001s)
2. `testSuccessfulLoadAndStateTransition`: Passed (0.001s)
3. `testLoadWhenAlreadyLoadedThrows`: Passed (0.003s)
4. `testUnloadWhenUnloadedIsSafeNoOp`: Passed (0.001s)
5. `testRepeatedUnloadCallsAreSafe`: Passed (0.001s)
6. `testEmptyAndWhitespaceModelPaths`: Passed (0.055s)
7. `testNonExistentModelPath`: Passed (0.001s)
8. `testDirectoryAsModelPath`: Passed (0.001s)
9. `testStateStreamReceivesTransitions`: Passed (0.001s)
10. `testFailedLoadLeavesStateFailedAndConsistent`: Passed (0.003s)
11. `testNativeWorkerWithInvalidFormatFailsSafely`: Passed (0.056s)
   - Native integration test using real embedded Metal runtime; verifies that an invalid binary file is safely rejected with `llama_model_load` error without crashing or leaking memory.

---

## 8. Debug Build Result and Warnings

### Build Execution Command
```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -configuration Debug build
```

### Result
`** BUILD SUCCEEDED **`

### Compiler Diagnostics & Warnings
- **Warnings:** 0
- **Errors:** 0
- Swift 6 strict concurrency checks: All types across `InferenceService`, `CancellationSignal`, `InferenceStream`, and `GenerationConfiguration` comply with `@Sendable` and actor isolation constraints.
- Code signing: Completed locally with entitlements.

---

## 9. Local Model Availability and Real-Model Testing Classification

- **Workspace Inspection:** A search for `.gguf` files across the workspace returned only vocabulary-only test fixtures in `reference-repos/.../models/ggml-vocab-*.gguf` (these contain no model weights and cannot execute inference).
- **Model Download Status:** Consistent with project scope and strict instructions, no external model weights were downloaded or bundled.
- **Classification of Testing:**
  - **Unit Tests:** Deterministic mock worker verifying streaming, ordering, configuration validation, consumer termination, cancellation recovery, and concurrency conflict handling. (Verified: PASS)
  - **Native Integration Tests:** `LlamaInferenceWorker` compiled and exercised against the real `llama.xcframework` binary, initializing the Apple M5 Metal device and embedded Metal shaders. (Verified: PASS)
  - **Real-Model Inference:** Marked as **PENDING** until a valid local GGUF model file is provided by the user.

---

## 10. Remaining Risks and Deferred Work

1. **Metal Cancellation Latency:**
   - As documented, cancellation cannot interrupt an in-flight Metal command buffer. On long sequence prompts or large prompt batches, cancellation latency will be bounded by the execution duration of a single command buffer dispatch.
2. **Context Shift / KV Eviction:**
   - In this minimal increment, `n_ctx` exhaustion results in `.contextExhausted` error. Advanced context shift, rolling buffer windows, or sequence defragmentation are deferred to future increments.
3. **Model Download & UI Integration:**
   - User-facing chat interface, persistent conversation history, model importing, and Hugging Face / GGUF download pipelines remain strictly out of scope and deferred.

---

## 11. Upstream Repository Cleanliness

The pinned upstream repository at `reference-repos/01-apple-silicon-and-inference/llama.cpp` was verified:

```bash
$ git -C reference-repos/01-apple-silicon-and-inference/llama.cpp status
On branch master
Your branch is up to date with 'origin/master'.
nothing to commit, working tree clean

$ git -C reference-repos/01-apple-silicon-and-inference/llama.cpp rev-parse HEAD
547208dca250ceb3e4c8615598d043f2b602a527
```

No files in the reference repository were created, edited, staged, or modified.
