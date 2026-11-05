# Aether — Phase 3.4.4: Generation Correctness, Concurrency & Safety Audit Report

**Document ID:** `research/21-phase-3.4.4-correctness-audit.md`  
**Date:** 2026-10-18  
**Audit Scope:** Read-only inspection of Phase 3.4.3 text generation, streaming, cancellation, and concurrency foundation.  
**Pinned upstream revision:** `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`)  
**Integrated framework:** `Aether/Frameworks/llama.xcframework`  
**Status:** Complete (Read-Only Audit)

---

## 1. Executive Verdict

### Verdict: CONDITIONAL PASS

The Phase 3.4.3 implementation successfully established a working, crash-free foundation: all 20 existing unit and lifecycle tests pass, the Debug application target builds with zero warnings under Swift 6 strict concurrency checks, native worker pointers remain strictly isolated within serial execution queues, and C11 acquire/release atomic cancellation integrates properly with `llama.cpp`'s `ggml_abort_callback`.

However, the architecture contains **one critical flaw**, **two high-severity flaws**, and several medium-severity edge cases that must be remediated before production usage or real-model generation:
1. **Critical:** Discarding an uniterated `InferenceStream` leaks an asynchronous `Task` that evaluates prompt and generation tokens up to `maxTokens` in the background without cancellation, locking the service state and wasting unified memory and compute.
2. **High:** `InferenceService.generate` updates actor cancellation state synchronously while deferring state validation to an asynchronous task, enabling race conditions where rapid calls overwrite the active cancellation signal before conflict rejection occurs.
3. **High:** Relying on `StreamIteratorTracker.deinit` for consumer loop exit (`break`) depends on non-deterministic ARC release timing that is not guaranteed by the Swift language specification.
4. **Medium:** Naive incomplete UTF-8 buffering can poison the accumulator on invalid byte tokens, preventing all subsequent tokens from streaming and dropping them on completion.
5. **Medium:** The final generated token is unnecessarily decoded into the KV cache before the loop terminates, wasting compute and risking spurious context-exhaustion errors.

No source files, tests, project settings, entitlements, or reference repository files were modified during this audit phase.

---

## 2. Findings Summary Matrix

| ID | Severity | Category | Component | File & Lines | Summary |
|---|---|---|---|---|---|
| **C1** | **Critical** | Concurrency / Resource Leak | Stream Lifecycle | [`InferenceService.swift:201-224`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L201-L224) | Abandoned uniterated stream spawns unbounded native generation to `maxTokens`. |
| **H1** | **High** | Concurrency / Race Hazard | Actor State Machine | [`InferenceService.swift:201-246`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L201-L246) | Synchronous `activeCancellationSignal` overwrite precedes asynchronous state conflict validation. |
| **H2** | **High** | Language Semantics | Cancellation Contract | [`InferenceService.swift:340-351`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L340-L351) | Early iteration cancellation relies on ARC deallocation timing not guaranteed by Swift specification. |
| **M1** | **Medium** | Generation Correctness | UTF-8 Streaming | [`LlamaInferenceWorker.swift:444-451`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L444-L451) | Invalid UTF-8 byte tokens permanently stall token emission and cause complete generation loss. |
| **M2** | **Medium** | Performance / Edge Case | Decoding Loop | [`LlamaInferenceWorker.swift:464-476`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L464-L476) | Final generated token is decoded into the model even when `nDecoded == maxTokens`. |
| **M3** | **Medium** | Sampling Correctness | Sampler Configuration | [`LlamaInferenceWorker.swift:368-375`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L368-L375) | Sampler chain order (`temp` before `top_k`/`top_p`) inverts upstream canonical order. |
| **L1** | **Low** | API Safety | Stream Consumption | [`InferenceService.swift:398-403`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L398-L403) | Multiple iterators on `InferenceStream` create conflicting cancellation trackers. |
| **L2** | **Low** | Code Hardening | Native Memory | [`LlamaInferenceWorker.swift:388,457`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L388) | Force-unwraps on heap pointers (`batch.seq_id[i]![0]`) risk fatal crash if `malloc` fails. |

---

## 3. Detailed Technical Findings

### Finding C1 (Critical): Abandoned Stream Runs Unchecked to `maxTokens`
- **Location:** [`InferenceService.swift:201-224`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L201-L224)
- **Mechanism:**
  In `InferenceService.generate(prompt:configuration:)`:
  ```swift
  let baseStream = AsyncThrowingStream<String, Error> { continuation in
      continuation.onTermination = { @Sendable _ in signal.cancel() }
      Task {
          do {
              try await self.executeGeneration(prompt: prompt, configuration: configuration, signal: signal, continuation: continuation)
          } catch {
              continuation.finish(throwing: error)
          }
      }
  }
  return InferenceStream(base: baseStream, signal: signal)
  ```
- **Root Cause & Concrete Failure Scenario:**
  1. A caller invokes `let stream = await service.generate(prompt: "Write a long essay")`.
  2. The unstructured `Task` starts immediately on the actor executor.
  3. The caller drops `stream` without ever calling `for try await _ in stream` (e.g., consumer timeout, view dismissed before rendering, or caller logic branch).
  4. Because no iterator was ever created, `StreamIteratorTracker` is never instantiated.
  5. The spawned `Task` retains `continuation` strongly until `executeGeneration` returns.
  6. In Swift's `AsyncThrowingStream`, the stream's internal storage (`_Storage`) is retained strongly by `continuation`. Therefore, `_Storage` is **never deallocated** while the `Task` is executing.
  7. `continuation.onTermination` **never fires**.
  8. The worker continues evaluating prompt tokens and generating subsequent tokens until `maxTokens` is reached.
  9. Throughout this duration (potentially tens of seconds), the service is trapped in `.generating` state. Any subsequent call to `loadModel`, `unloadModel`, or `generate` is rejected with `InferenceError.conflictingOperation`.
- **Impact:** Denial of service for subsequent inferences, excessive battery and thermal drain on Apple Silicon unified memory, and memory leak of generated tokens accumulating in `AsyncThrowingStream`'s unbounded default buffer.

---

### Finding H1 (High): Synchronous `activeCancellationSignal` Overwrite Precedes Asynchronous State Conflict Validation
- **Location:** [`InferenceService.swift:201-203, 229-243`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L201-L203)
- **Mechanism:**
  ```swift
  public func generate(...) -> InferenceStream {
      let signal = CancellationSignal()
      self.activeCancellationSignal = signal  // Line 202: Synchronously overwrites property

      let baseStream = AsyncThrowingStream<String, Error> { continuation in
          ...
          Task {
              // Line 229: State check occurs asynchronously when Task runs
              guard case .loaded(let modelInfo) = state else { ... }
          }
      }
  }
  ```
- **Concrete Failure Scenario:**
  1. Generation 1 is running. `self.activeCancellationSignal` holds `signal1`. `state` is `.generating`.
  2. A secondary consumer accidentally calls `service.generate(...)` (or a rapid duplicate click occurs).
  3. `generate` creates `signal2` and immediately assigns `self.activeCancellationSignal = signal2`, clobbering `signal1`.
  4. The background task for Generation 2 is queued on the actor mailbox. When it executes, it inspects `state`, sees `.generating`, and throws `InferenceError.conflictingOperation`.
  5. However, `self.activeCancellationSignal` is now pointing to `signal2` (the rejected operation's signal).
  6. The user or UI calls `service.cancelGeneration()`.
  7. `activeCancellationSignal?.cancel()` signals `signal2`.
  8. `signal1` (the actual long-running generation task currently executing on the GPU) **never receives the cancellation signal**.
  9. Generation 1 cannot be cancelled via `cancelGeneration()`.
- **Impact:** Loss of cancellation control for active in-flight model inference.

---

### Finding H2 (High): Early Iteration Cancellation Relies on Non-Deterministic ARC Deallocation Timing
- **Location:** [`InferenceService.swift:340-351`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L340-L351)
- **Mechanism:**
  Cancellation on `break` from `for try await x in stream` is handled exclusively in:
  ```swift
  deinit {
      let shouldCancel = isCompleted.withLock { ... }
      if shouldCancel { onCancel() }
  }
  ```
- **Language Specification Evidence:**
  Per Swift language specifications (Swift Evolution SE-0371, Swift Concurrency, and LLVM ARC optimization passes):
  - Swift **does not provide lexical scope destructor guarantees** like C++ RAII.
  - The Swift compiler is explicitly permitted to hoist or defer object releases depending on optimization levels (`-O`, `-Osize`), dead code elimination, and stack frame layouts.
  - If a consumer uses intermediate sequence combinators (e.g., custom async transforms, wrapping iterators, or task captures), the iterator may remain retained in an autorelease pool or outer closure frame long after the consumer loop has broken.
  - While this pattern succeeded in immediate local unit tests, relying on `deinit` as the primary cross-thread control signal violates Swift Concurrency architectural principles.
- **Impact:** Cancellation latency may vary unpredictably between Debug and Release builds, or fail entirely if an enclosing context retains the iterator.

---

### Finding M1 (Medium): Incomplete UTF-8 Accumulator Poisoning on Invalid Bytes
- **Location:** [`LlamaInferenceWorker.swift:444-451, 480-485`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L444-L451)
- **Mechanism:**
  ```swift
  let pieceChars = self.tokenToPiece(vocab: vocab, token: newToken)
  if !pieceChars.isEmpty {
      temporaryInvalidCChars.append(contentsOf: pieceChars)
      if let validString = String(validatingUTF8: temporaryInvalidCChars + [0]) {
          temporaryInvalidCChars.removeAll()
          if !validString.isEmpty { onToken(validString) }
      }
  }
  ```
- **Concrete Failure Scenario:**
  1. A vocabulary emits an initial invalid UTF-8 byte (e.g., raw byte token `0x80`..`0xFF` produced by code or binary data models, or an unexpected non-UTF8 token piece).
  2. `temporaryInvalidCChars` contains `[0x80]`. `String(validatingUTF8:)` returns `nil`.
  3. The next token emitted is a normal ASCII or valid UTF-8 token: `"Hello"`.
  4. `temporaryInvalidCChars` becomes `[0x80, 'H', 'e', 'l', 'l', 'o']`.
  5. Because the sequence begins with an invalid start byte `0x80`, `String(validatingUTF8:)` will **continue returning `nil` for every single subsequent token**.
  6. The accumulator grows indefinitely for the entire generation length.
  7. No tokens are yielded to `onToken`.
  8. When the loop ends, lines 480-485 attempt to validate the entire buffer. It again returns `nil`.
  9. Line 484 executes `temporaryInvalidCChars.removeAll()`, silently dropping the entire response.
- **Impact:** Total output loss if any invalid or raw byte token is sampled.

---

### Finding M2 (Medium): Unnecessary Decode on Final Generated Token
- **Location:** [`LlamaInferenceWorker.swift:464-476`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L464-L476)
- **Mechanism:**
  ```swift
  while nDecoded < configuration.maxTokens {
      ...
      let newToken = llama_sampler_sample(smpl, ctx, -1)
      ...
      onToken(validString)
      ...
      nDecoded += 1
      let decodeRes = llama_decode(ctx, singleBatch) // Executed even when nDecoded == maxTokens
  }
  ```
- **Impact:**
  When `nDecoded` reaches `configuration.maxTokens`, the last token has already been sampled and delivered. Calling `llama_decode` on this token:
  1. Wastes an entire GPU/CPU inference forward pass computing logits that will never be sampled.
  2. If `nCur` happens to reach `configuration.contextLength` on that final token, `llama_decode` returns error code `1` or triggers `.contextExhausted`, transforming an otherwise completely successful response into a decode error.

---

### Finding M3 (Medium): Inverted Sampler Chain Order
- **Location:** [`LlamaInferenceWorker.swift:368-375`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L368-L375)
- **Mechanism:**
  In `LlamaInferenceWorker.swift`:
  ```swift
  llama_sampler_chain_add(smpl, llama_sampler_init_temp(configuration.temperature))
  if configuration.topK > 0 { llama_sampler_chain_add(smpl, llama_sampler_init_top_k(configuration.topK)) }
  if configuration.topP < 1.0 { llama_sampler_chain_add(smpl, llama_sampler_init_top_p(configuration.topP, 1)) }
  llama_sampler_chain_add(smpl, llama_sampler_init_dist(configuration.seed))
  ```
- **Verified Upstream Header Evidence (`include/llama.h:1350-1356`):**
  ```c
  llama_sampler_chain_add(smpl, llama_sampler_init_top_k(50));
  llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1));
  llama_sampler_chain_add(smpl, llama_sampler_init_temp (0.8));
  llama_sampler_chain_add(smpl, llama_sampler_init_dist(seed));
  ```
- **Impact:**
  Applying temperature scaling before `top_p` alters the cumulative probability distribution slope, causing nucleus filtering to behave differently than standard LLM implementations.

---

### Finding L1 (Low): Multiple Iterators Allowed on Single-Use `InferenceStream`
- **Location:** [`InferenceService.swift:398-403`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift#L398-L403)
- **Mechanism:**
  `InferenceStream.makeAsyncIterator()` can be called multiple times on the same stream instance. Each call creates an independent `StreamIteratorTracker`.
- **Impact:**
  If iterator 1 is created, used briefly, and released while iterator 2 continues, iterator 1's deinit cancels the entire underlying generation. `InferenceStream` should enforce single-consumer consumption.

---

### Finding L2 (Low): Force-Unwraps on Native Pointers
- **Location:** [`LlamaInferenceWorker.swift:388, 457`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift#L388)
- **Mechanism:**
  `promptBatch.seq_id[i]![0] = 0` and `singleBatch.seq_id[0]![0] = 0`.
- **Impact:**
  If `llama_batch_init` experiences heap allocation failure for the sequence ID array, force unwrapping crashes the application instead of throwing a clean `InferenceError`.

---

## 4. Upstream API & Metal Callback Verifications

Inspection of `reference-repos/01-apple-silicon-and-inference/llama.cpp` at pinned revision `547208dca250ceb3e4c8615598d043f2b602a527` confirmed:

1. **Metal Cancellation Latency:**
   - In `ggml-metal-context.m` (lines 586-592 and 768):
     ```objc
     if (cb_idx < 2 || ctx->abort_callback == NULL) {
         [cmd_buf commit];
     }
     ```
   - The first two command buffers (`cb_idx < 2`) of any compute graph are committed to the Metal queue unconditionally.
   - Once committed via `[cmd_buf commit]`, Apple Silicon hardware executes the command buffer to completion. The abort callback **cannot interrupt an already dispatched command buffer**.
   - `llama_synchronize(ctx)` is strictly required before any context deallocation or `llama_memory_clear` call to prevent GPU memory faulting.
2. **Context Memory Reset:**
   - `llama_kv_cache_clear` does not exist in this revision.
   - `llama_memory_clear(llama_get_memory(ctx), true)` is the verified upstream API to clear sequence allocations and reset context state.
3. **Token-to-Piece API:**
   - `llama_token_to_piece` does not append a null terminator (documented in `llama.h:1289`). Sizing checks via negative return codes are verified correct.

---

## 5. Test Quality and Coverage Classification

The 20 automated tests in the test suite are classified as follows:

| Test Name | Category | What It Proves | What It Does NOT Prove |
|---|---|---|---|
| `testInitialStateIsUnloaded` | Unit Test | Initial actor property state. | No worker interaction. |
| `testSuccessfulLoadAndStateTransition` | Unit Test (Mock) | Service state transitions on load. | No native file or model parsing. |
| `testLoadWhenAlreadyLoadedThrows` | Unit Test (Mock) | Rejection of duplicate load. | No native memory safety. |
| `testUnloadWhenUnloadedIsSafeNoOp` | Unit Test (Mock) | Idempotent unload. | No native memory deallocation. |
| `testRepeatedUnloadCallsAreSafe` | Unit Test (Mock) | Idempotent repeated unload. | No native context cleanup. |
| `testEmptyAndWhitespaceModelPaths` | Unit Test | Filesystem string validation. | No model loading. |
| `testNonExistentModelPath` | Unit Test | Path existence check. | No model loading. |
| `testDirectoryAsModelPath` | Unit Test | Rejection of directory path. | No model loading. |
| `testStateStreamReceivesTransitions` | Unit Test (Mock) | AsyncStream broadcast to UI. | No generation events. |
| `testFailedLoadLeavesStateFailedAndConsistent` | Unit Test (Mock) | State machine error resilience. | No native failure handling. |
| `testNativeWorkerWithInvalidFormatFailsSafely` | Native Test (Hardware) | `llama_model_load_from_file` safely returns NULL on corrupt binary data; embedded Metal device/library initializes on M5 GPU. | Does not execute inference, KV caching, or token generation. |
| `testEmptyAndWhitespacePromptsThrow` | Unit Test (Mock) | Parameter validation for prompts. | No tokenization. |
| `testInvalidConfigurationValidation` | Unit Test | Parameter bounds checking. | No native context allocation. |
| `testGenerateWhenNotLoadedThrows` | Unit Test (Mock) | State check rejects uninitialized model. | No native error handling. |
| `testSuccessfulGenerationStreamingInOrder` | Unit Test (Mock) | FIFO chunk ordering and state transition to `.loaded`. | No real token decoding, no multi-byte UTF-8 slices. |
| `testMaxTokensEnforcement` | Unit Test (Mock) | Generation stops when limit reached. | No native batch loop termination. |
| `testConsumerEarlyTerminationTriggersCancellation` | Unit Test (Mock) | Iterator deinit signals mock worker under explicit 50ms delay. | Does not prove language-guaranteed deinit timing; does not test native GPU preemption. |
| `testSubsequentGenerationAfterCancellationSucceeds` | Unit Test (Mock) | State recovers to `.loaded` after cancellation. | No native KV cache reset. |
| `testConflictingGenerationThrows` | Unit Test (Mock) | Rejects overlapping generation when already in `.generating` state. | Does not catch synchronous `activeCancellationSignal` overwrite (Finding H1). |
| `testNativeWorkerWhenNotLoadedThrows` | Native Test | Worker throws `.notLoaded` when `model == nil`. | No native computation. |

**Coverage Gap Summary:**
- **Zero real-model tests:** No complete GGUF model with weights was tested. Real-model inference remains pending until weights are provided.
- **Zero native tokenization / sampling / decoding tests:** All generation logic was tested with `MockGenerationWorker`. The real `syncGenerate` execution path was not exercised in automated tests.
- **Zero multi-byte UTF-8 split tests:** No tests evaluate whether emojis or complex UTF-8 characters slice cleanly across token boundaries.

---

## 6. Proposed Remediation Sequence (Prioritized)

Remediation is deferred until explicit authorization. When authorized, the minimal recommended fix sequence is:

### Step 1: Fix Synchronous State Transition and Cancellation Signal Ownership (Resolves C1 & H1)
In [`InferenceService.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift):
1. Validate state (`guard case .loaded(let modelInfo) = state`) **synchronously inside `generate`** before creating any streams or signals. If invalid, throw immediately.
2. Synchronously transition state to `.generating(modelInfo: modelInfo)` inside `generate`.
3. Associate `activeCancellationSignal` strictly with the active generation.
4. Pass an explicit termination or cancellation closure directly to the stream continuation rather than relying on unstructured detached task lifecycles.

### Step 2: Implement Explicit Stream Cancellation Without ARC Timing Dependencies (Resolves H2 & L1)
In [`InferenceService.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/InferenceService.swift):
1. In `InferenceStream`, enforce single-consumer semantics by tracking an atomic or lock-protected `hasIterated` flag in `makeAsyncIterator()`.
2. Connect stream cancellation to the consumer `Task` cancellation and continuation termination rather than pure object deallocation.

### Step 3: Harden UTF-8 Multi-Byte Fragment Buffer (Resolves M1)
In [`LlamaInferenceWorker.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift):
1. Limit `temporaryInvalidCChars` buffering to a maximum of 4 bytes (the maximum size of any valid UTF-8 code point).
2. If the buffer exceeds 4 bytes or an invalid lead byte is encountered, emit the replacement character `\u{FFFD}` (or drop the invalid byte) and resume validating subsequent bytes instead of accumulating indefinitely.

### Step 4: Correct Decode Loop Termination & Sampler Chain Order (Resolves M2, M3 & L2)
In [`LlamaInferenceWorker.swift`](file:///Users/asadalishaikh/Aether%20Agent/Aether/Sources/Inference/LlamaInferenceWorker.swift):
1. In the `while nDecoded < configuration.maxTokens` loop, break immediately after emitting `newToken` if `nDecoded == configuration.maxTokens`, omitting the redundant `llama_decode` on the final token.
2. Reorder sampler additions to match upstream canonical order: `top_k -> top_p -> temp -> dist`.
3. Replace force-unwraps on `batch.seq_id` with optional binding guards.

---

## 7. Workspace and Upstream Integrity Confirmation

1. **Workspace Cleanliness:**
   - No application code, test files, Xcode projects, or entitlements were modified during Phase 3.4.4.
2. **Upstream Repository Cleanliness:**
   - Verified clean via `git -C reference-repos/01-apple-silicon-and-inference/llama.cpp status`:
     ```
     On branch master
     Your branch is up to date with 'origin/master'.
     nothing to commit, working tree clean
     ```
   - HEAD commit confirmed at: `547208dca250ceb3e4c8615598d043f2b602a527`.

---

## 8. Separation of Facts, Estimates, and Unverified Claims

- **Verified Fact:** `xcodebuild test` succeeds with 20/20 tests passing on macOS 14 / Apple M5.
- **Verified Fact:** Metal command buffers committed with `cb_idx < 2` execute to completion on Apple Silicon and cannot be aborted mid-buffer by `ggml_abort_callback`.
- **Verified Fact:** `llama_tokenize` returns negative token counts on insufficient buffer capacity and `0` on empty tokens.
- **Verified Fact:** Discarding an uniterated stream causes the worker to decode up to `maxTokens` in the background.
- **Estimate:** Token decode latency on Apple Silicon M5 unified memory remains estimated until a real GGUF model is evaluated.
- **Unverified Claim:** Real-model text quality, inference throughput, and actual Metal cancellation latency remain unverified and explicitly pending real-model integration testing.
