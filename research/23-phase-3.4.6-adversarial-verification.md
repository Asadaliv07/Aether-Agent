# AETHER — PHASE 3.4.6 REPORT
## Adversarial Correctness, Concurrency & Lifecycle Verification Audit

**Date:** October 19, 2026  
**Status:** Complete  
**Execution Verdict:** FAIL  
**Project:** Aether  
**Previous Phase:** 3.4.5 — Critical Correctness & Concurrency Remediation (`research/22-phase-3.4.5-correctness-remediation.md`)  
**Pinned upstream revision:** `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`)  
**Target Environment:** macOS 14.0+, Apple Silicon (arm64, M5 MacBook Air 16GB)  
**Strict Concurrency:** Swift 6 (`SWIFT_STRICT_CONCURRENCY = complete`)

---

## 1. EXECUTIVE VERDICT

### **VERDICT: FAIL**

While Phase 3.4.5 introduced vital architectural advancements—notably converting `InferenceStream` to an owned `Sendable final class`, adding `EarlyExitTracker`, introducing `UTF8Buffer`, enforcing pre-decode token limits, and fixing sampler chain ordering—an independent adversarial audit of the concrete implementation reveals **two confirmed High-severity defects** and **one Medium-severity concurrency gap** that invalidate the prior unconditional `PASS` verdict:

1. **Defect ADV-01 (Severity: HIGH) — Unguarded Actor State Mutation in `executeGeneration` Catch Block:**  
   In `InferenceService.swift:342-344`, if generation encounters an error other than `.cancelled`, `self.state = .failed(errorDescription:)` is assigned **without verifying** `self.activeGenerationId == generationId`. If generation 1 is cancelled or terminated, state is returned to `.loaded` and generation 2 is accepted; if generation 1's worker subsequently aborts with an error (e.g., decode failure or context error), generation 1's error handler clobbers `InferenceService.state` to `.failed`, corrupting active generation 2. `[VERIFIED FACT]`
2. **Defect ADV-02 (Severity: HIGH) — Premature `.loaded` State Restoration During In-Flight Worker Execution:**  
   In `InferenceService.swift:265-271` & `290-299`, stream termination synchronously sets `CancellationSignal` and launches a detached `Task` calling `handleStreamTermination`, which immediately clears `activeGenerationId` and resets `state = .loaded` **without awaiting the completion of the background generation task or the worker queue execution**. External callers observing `.loaded` can immediately dispatch `unloadModel()` or another `generate()`, creating an illegal overlap with active native inference or GPU compute. `[VERIFIED FACT]`
3. **Defect ADV-03 (Severity: MEDIUM) — Unbounded Cancellation Latency in `AsyncIterator.next()`:**  
   In `InferenceService.swift:495-515`, `AsyncIterator.next()` awaits `baseIterator.next()` without wrapping the call in `withTaskCancellationHandler`. If consumer task cancellation occurs while suspended awaiting a slow prompt evaluation or stalled worker decode, cancellation is not propagated to `CancellationSignal` until `baseIterator.next()` returns an element or finishes. `[VERIFIED FACT]`

Because these defects directly compromise generation ownership invariants, actor state consistency, and native worker concurrency boundaries, Phase 3.4.6 renders an adversarial verdict of **FAIL**. Production UI and high-level agent integrations cannot safely proceed until these defects are remediated in a dedicated follow-up phase.

---

## 2. ADVERSARIAL FINDINGS TABLE

| Finding ID | Severity | Status | Exact Source File & Line(s) | Architectural / User-Visible Impact | Recommended Remediation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **ADV-01** | **HIGH** | Confirmed Defect | `Aether/Sources/Inference/InferenceService.swift:342-344` | Stale generation error overwrites state of an active subsequent generation, leaving service in `.failed` while actively generating. | Guard line 343 with `if self.activeGenerationId == generationId { self.state = .failed(...) }`. |
| **ADV-02** | **HIGH** | Confirmed Defect | `Aether/Sources/Inference/InferenceService.swift:265-271`, `290-299` | Service advertises `.loaded` state to consumers while worker thread or Metal GPU is actively computing in-flight tokens. Subsequent operations interleave unsafely. | Refactor stream termination to signal cancellation immediately but defer state transition to `.loaded` until `generationTask` or `worker.generate()` has exited. |
| **ADV-03** | **MEDIUM** | Confirmed Defect | `Aether/Sources/Inference/InferenceService.swift:495-515` | Consumer task cancellation fails to signal worker until after `baseIterator.next()` unblocks. If decode hangs, cancellation never fires. | Wrap `baseIterator.next()` in `withTaskCancellationHandler`, immediately calling `stream?.cancel()` upon task cancellation. |
| **ADV-04** | **LOW** | Verified Constraint | `Aether/Sources/Inference/LlamaInferenceWorker.swift:493-518` | `tokenToPiece` allocates small 8-byte buffer, and re-allocates if negative count returned. Safe but incurs minor heap overhead per token. | Retain small stack/inline buffer or enlarge default probe buffer to 16/32 bytes. |
| **ADV-05** | **INFORMATIONAL** | Verified Native Fact | `reference-repos/.../ggml-metal-context.m:586, 644, 768` | Pinned llama.cpp Metal backend executes command buffers asynchronously without polling `abort_callback`. Cancellation is cooperative at host token loop boundaries. | Document architectural guarantee: Metal kernel dispatches complete in-flight; cancellation latency is bounded by single-token decode time. |
| **ADV-06** | **INFORMATIONAL** | Partially Verified | `Aether/Tests/InferenceGenerationTests.swift:5-100` | 20 of 21 generation tests exercise `MockGenerationWorker`, which mocks token delays and cancellation but does not exercise native C memory or Metal kernels. | Add integration test against real native GGUF model once model assets are authorized. |

---

## 3. AUDIT A — STREAM OWNERSHIP AND ABANDONMENT

### 3.1 Design Inspection: `InferenceStream`
In Phase 3.4.5, `InferenceStream` was refactored from a struct to a `Sendable final class`:
```swift
public final class InferenceStream: AsyncSequence, Sendable {
    private let base: AsyncThrowingStream<String, Error>
    private let signal: CancellationSignal?
    private let generationTask: Task<Void, Never>?
    private let onCancel: (@Sendable () -> Void)?
    ...
```
`InferenceStream` retains:
1. `generationTask: Task<Void, Never>?`: The task executing `executeGeneration`.
2. `signal: CancellationSignal?`: The atomic cancellation signal wrapper.
3. `onCancel: (@Sendable () -> Void)?`: Closure triggering cancellation and actor cleanup.

### 3.2 Reference Cycle Analysis
We traced all capture lists in `InferenceService.generate()`:
1. `generationTask` captures:
   ```swift
   let generationTask = Task { [weak self] in ... }
   ```
   Captures `weak self` (where `self` is `InferenceService`). Does NOT capture `InferenceStream`.
2. `onTermination` captures:
   ```swift
   let onTermination: @Sendable () -> Void = { [weak self] in
       signal.cancel()
       generationTask.cancel()
       Task { [weak self] in
           await self?.handleStreamTermination(generationId: generationId, modelInfo: modelInfo)
       }
   }
   ```
   Captures `weak self`, `signal`, `generationTask`, `generationId`, `modelInfo`. Does NOT capture `InferenceStream`.
3. `InferenceStream` retains `generationTask`, `signal`, `onCancel`.
4. `InferenceStream.AsyncIterator` retains `InferenceStream` and `EarlyExitTracker` (which retains `InferenceStream`).

**Conclusion on Cycles:** There is **no strong reference cycle** between `InferenceService`, `generationTask`, and `InferenceStream`. `[VERIFIED FACT]`

### 3.3 Can `InferenceStream.deinit` Run When Abandoned?
- When a caller calls `let stream = service.generate(...)` and drops `stream` without iterating or saving it:
  1. No external reference to `InferenceStream` exists.
  2. The iterator was never created.
  3. `generationTask` does not retain `InferenceStream`.
  4. Therefore, `InferenceStream.deinit` runs promptly under Swift ARC. `[VERIFIED FACT]`
  5. `InferenceStream.deinit` calls `cancel()`, which sets `isTerminated = true`, invokes `signal?.cancel()`, `generationTask?.cancel()`, and `onCancel?()`.
  6. The background worker halts at the next cancellation check point.
- **Verification:** Tested by `testStreamRequestedAndAbandonedWithoutIterationHaultsAndRecovers` in `InferenceGenerationTests.swift:387-419`, which passes deterministically. `[MEASURED]`

### 3.4 Defect ADV-02: Premature `.loaded` State Restoration
While `InferenceStream.deinit` executes cancellation, the state restoration mechanism contains a race condition:
```swift
// InferenceService.swift:265-271
let onTermination: @Sendable () -> Void = { [weak self] in
    signal.cancel()
    generationTask.cancel()
    Task { [weak self] in
        await self?.handleStreamTermination(generationId: generationId, modelInfo: modelInfo)
    }
}
```
And inside `handleStreamTermination`:
```swift
// InferenceService.swift:290-299
private func handleStreamTermination(generationId: UUID, modelInfo: ModelInfo) {
    guard self.activeGenerationId == generationId else { return }
    self.activeGenerationId = nil
    self.activeCancellationSignal = nil
    if case .generating = state {
        self.state = .loaded(modelInfo: modelInfo)
    }
}
```
**The Flaw:**
- `onTermination` spawns a detached `Task` that calls `handleStreamTermination` immediately.
- Neither `generationTask` nor `worker.generate()` is awaited.
- When `handleStreamTermination` runs on the actor:
  - `self.activeGenerationId` is set to `nil`.
  - `self.state` transitions from `.generating` to `.loaded`.
- At this exact moment, `worker.generate` is **still executing** on `com.aether.inference.worker` queue or waiting for `llama_synchronize(ctx)`.
- If a consumer immediately issues `service.unloadModel()`:
  - `service.unloadModel()` checks `state`. Since `state == .loaded`, it permits the unload!
  - `service.unloadModel()` sets `state = .unloading` and enqueues `syncUnloadModel` on the worker queue.
  - While `syncGenerate` is unwinding and synchronizing, `syncUnloadModel` is queued right behind it or races with state assertions.
- More critically: if another `service.generate()` is called immediately:
  - `state == .loaded`, so generation 2 is accepted (`activeGenerationId = id2`).
  - Worker queue now has generation 2's `syncGenerate` queued behind generation 1's unfinished `syncGenerate`.
- **Verdict on Guarantee:** The claim that `.loaded` guarantees worker quiescence is **UNTRUE** under stream cancellation. State restoration is premature. `[VERIFIED FACT]`

---

## 4. AUDIT B — ASYNCSEQUENCE AND EARLY-EXIT DETECTION

### 4.1 `EarlyExitTracker` Inspection
`EarlyExitTracker` is implemented as:
```swift
// InferenceService.swift:439-457
private final class EarlyExitTracker: @unchecked Sendable {
    private let stream: InferenceStream
    private let completed = OSAllocatedUnfairLock(initialState: false)

    init(stream: InferenceStream) {
        self.stream = stream
    }

    func markCompleted() {
        completed.withLock { $0 = true }
    }

    deinit {
        let wasCompleted = completed.withLock { $0 }
        if !wasCompleted {
            stream.cancel()
        }
    }
}
```
And embedded in `InferenceStream.AsyncIterator`:
```swift
public struct AsyncIterator: AsyncIteratorProtocol {
    private var baseIterator: AsyncThrowingStream<String, Error>.AsyncIterator?
    private let stream: InferenceStream?
    private let tracker: EarlyExitTracker?
    ...
```

### 4.2 Early-Exit Analysis
1. **Normal Loop Exit:**
   - Loop runs until `next()` returns `nil`.
   - In `next()`, line 505: `tracker?.markCompleted()` and `stream?.markCompleted()`.
   - When the iterator goes out of scope, `EarlyExitTracker.deinit` sees `completed == true` and takes no action.
2. **Loop Break (Early Exit):**
   - Consumer executes `break` or `return` inside `for try await chunk in stream`.
   - The loop terminates. The compiler drops the local `iterator` struct.
   - Dropping `iterator` releases `tracker`.
   - `EarlyExitTracker.deinit` runs, sees `wasCompleted == false`, and calls `stream.cancel()`.
   - This sets `CancellationSignal` and terminates the generation task.
3. **Stream Held Across Outer Scope:**
   - Even if the caller retains `stream` in an outer variable (`let stream = ...`), the `iterator` created by the `for-in` loop is destroyed when the loop finishes.
   - Thus, `EarlyExitTracker.deinit` fires regardless of whether `stream` is held! `[VERIFIED FACT]`
   - Verified by test `testConsumerEarlyTerminationTriggersCancellation` in `InferenceGenerationTests.swift:237-266`.

### 4.3 Defect ADV-03: Suspension Cancellation Gap
In `AsyncIterator.next()`:
```swift
// InferenceService.swift:484-488
if Task.isCancelled {
    tracker?.markCompleted()
    stream?.cancel()
    throw CancellationError()
}

guard var baseIterator else { return nil }

do {
    // SUSPENSION POINT
    if let item = try await baseIterator.next() {
        self.baseIterator = baseIterator
        return item
    } else { ... }
```
**The Flaw:**
- When the consumer task is cancelled while suspended at line 495 (`try await baseIterator.next()`), Swift's `AsyncThrowingStream.Iterator.next()` does **not** abort natively unless cancellation is handled.
- Because `baseIterator.next()` is not wrapped in `withTaskCancellationHandler(operation:onCancel:)`, the `CancellationSignal` is NOT asserted when the consumer task is cancelled.
- The consumer task remains suspended until the underlying generation task produces a token or finishes.
- Only *after* `baseIterator.next()` resumes does `next()` proceed.
- If prompt tokenization or decoding hangs, consumer task cancellation will **never take effect**! `[VERIFIED FACT]`

---

## 5. AUDIT C — ACTOR STATE AND GENERATION OWNERSHIP

### 5.1 Synchronous Reservation
In `InferenceService.generate()` (lines 204-242):
- State validation:
  ```swift
  guard case .loaded(let modelInfo) = state else { ... return InferenceStream.preFailed(...) }
  ```
- Prompt validation:
  ```swift
  guard !trimmedPrompt.isEmpty else { ... return InferenceStream.preFailed(...) }
  ```
- Configuration validation:
  ```swift
  do { try configuration.validate() } catch { return InferenceStream.preFailed(...) }
  ```
- Reservation:
  ```swift
  let generationId = UUID()
  let signal = CancellationSignal()
  self.activeGenerationId = generationId
  self.activeCancellationSignal = signal
  self.state = .generating(modelInfo: modelInfo)
  ```
All validations and mutations occur **synchronously on the actor before any suspension points or background tasks**.
This eliminates the race condition where concurrent `generate()` calls could interleave before checking state. `[VERIFIED FACT]`

### 5.2 Defect ADV-01: Unguarded State Mutation in `executeGeneration` Catch Block
Inspect `executeGeneration` lines 309-347:
```swift
private func executeGeneration(
    generationId: UUID,
    modelInfo: ModelInfo,
    prompt: String,
    configuration: GenerationConfiguration,
    signal: CancellationSignal,
    continuation: AsyncThrowingStream<String, Error>.Continuation
) async throws {
    defer {
        if self.activeGenerationId == generationId {
            self.activeGenerationId = nil
            self.activeCancellationSignal = nil
            if case .generating = self.state {
                self.state = .loaded(modelInfo: modelInfo)
            }
        }
    }

    do {
        try await worker.generate(...)
        continuation.finish()
    } catch {
        let mappedError: InferenceError
        if let infErr = error as? InferenceError {
            mappedError = infErr
        } else if error is CancellationError {
            mappedError = .cancelled
        } else {
            mappedError = .decodeFailed(code: -1, description: error.localizedDescription)
        }

        // DEFECT HERE: Line 342-344
        if mappedError != .cancelled {
            self.state = .failed(errorDescription: mappedError.localizedDescription)
        }
        continuation.finish(throwing: mappedError)
        throw mappedError
    }
}
```
**Exact Failure Sequence (Reproduction Trace):**
1. Service is in state `.loaded(modelA)`.
2. Caller issues Generation 1 (`generationId = UUID_1`).
   - `self.activeGenerationId = UUID_1`.
   - `self.state = .generating(modelA)`.
   - `executeGeneration(UUID_1)` starts in `generationTask_1`.
3. Consumer cancels Stream 1 (or breaks from loop).
   - `onTermination` runs, invoking `handleStreamTermination(UUID_1)`.
   - `handleStreamTermination` passes `guard self.activeGenerationId == UUID_1`.
   - `self.activeGenerationId` is set to `nil`.
   - `self.state` is set to `.loaded(modelA)`.
4. While Generation 1's worker is unwinding/failing, a new request arrives: Generation 2 (`generationId = UUID_2`).
   - `service.generate(...)` sees `self.state == .loaded(modelA)`.
   - Synchronously reserves: `self.activeGenerationId = UUID_2`, `self.state = .generating(modelA)`.
   - Generation 2 starts running successfully.
5. In the background, Generation 1's worker aborts with a non-cancellation error (e.g. `llama_decode` returns `-1`, or `InferenceError.decodeFailed(-1)`).
6. Generation 1's `executeGeneration` catches `mappedError = .decodeFailed(-1)`.
7. Line 342 evaluates: `if mappedError != .cancelled` -> **TRUE**!
8. Line 343 executes:
   ```swift
   self.state = .failed(errorDescription: mappedError.localizedDescription)
   ```
   **CRITICAL FAULT:** There is **NO CHECK** for `self.activeGenerationId == generationId`!
9. Result:
   - `self.state` is set to `.failed`!
   - But Generation 2 (`UUID_2`) is actively generating!
   - State observers receive a false `.failed` notification.
   - Any third request is rejected with `.notLoaded`.
   - When Generation 2 eventually finishes or yields, its state machine is hopelessly broken.

This is a **confirmed High-severity defect** in generation ownership. `[VERIFIED FACT]`

---

## 6. AUDIT D — NATIVE CANCELLATION AND RESOURCE LIFETIME

### 6.1 C11 Atomic Signal and Abort Callback
We inspected `CancellationSignal.swift`, `AetherAtomic.h`, and `AetherAtomic.c`:
1. **Flag Allocation:**
   `aether_atomic_flag_create()` uses `malloc(sizeof(AetherAtomicFlag))` and initializes `atomic_bool value` with `atomic_init(&flag->value, false)`.
2. **Memory Ordering:**
   - Set: `atomic_store_explicit(&flag->value, val, memory_order_release);`
   - Get: `atomic_load_explicit(&flag->value, memory_order_acquire);`
   - Memory ordering conforms to C11 acquire/release semantics. `[VERIFIED FACT]`
3. **Callback Implementation:**
   ```c
   bool aether_abort_callback(void * data) {
       if (!data) return false;
       return aether_atomic_flag_get((const AetherAtomicFlag *)data);
   }
   ```
4. **Pointer Safety & Callback Lifetime:**
   - In `LlamaInferenceWorker.swift:351-354`:
     ```swift
     llama_set_abort_callback(ctx, aether_abort_callback, cancellationSignal.rawPointer)
     defer {
         llama_set_abort_callback(ctx, nil, nil)
     }
     ```
   - `cancellationSignal` is retained by `InferenceStream` and passed into `worker.generate()`.
   - The defer block in `syncGenerate` guarantees `llama_set_abort_callback(ctx, nil, nil)` is called before `syncGenerate` exits.
   - Therefore, the native context **never retains a dangling pointer to deallocated atomic storage**. `[VERIFIED FACT]`

### 6.2 Metal Cancellation Reality vs Claims
Phase 3.4.5 noted:
> "Metal GPU In-Flight Cancellation Latency: Cooperative cancellation functions at the token boundary... When `CancellationSignal.cancel()` is called while a Metal command buffer is executing a matrix multiplication kernel on the GPU, that specific GPU dispatch completes before the C/C++ callback halts the next token step."

We audited the exact pinned source in `reference-repos/01-apple-silicon-and-inference/llama.cpp/ggml/src/ggml-metal/ggml-metal-context.m`:
```objc
// Lines 586-593
if (cb_idx < 2 || ctx->abort_callback == NULL) {
    [cmd_buf enqueue];
    ctx->cmd_buf_last = cmd_buf;
}
...
// Lines 600-602
if (use_capture && ctx->capture_started) {
    ...
    if (ctx->abort_callback && ctx->abort_callback(ctx->abort_callback_data)) {
        return GGML_STATUS_ABORTED;
    }
}
...
// Lines 768-770
if (cb_idx < 2 || ctx->abort_callback == NULL) {
    [cmd_buf commit];
}
```
**Findings on Metal Cancellation:**
1. In standard inference mode, `use_capture` is **false**. The abort callback inside line 644 is **never invoked during GPU execution**. `[VERIFIED FACT]`
2. Metal command buffers are enqueued and committed to the GPU asynchronously.
3. Apple Metal does not expose an external mid-kernel hardware interrupt API for general compute command buffers without resetting the device.
4. Cancellation in Aether is therefore **purely host-side cooperative at token boundaries**:
   - Before prompt decode (`if cancellationSignal.isCancelled`).
   - Between token generation steps (`if cancellationSignal.isCancelled`).
   - After decode returns.
5. In-flight Metal GPU dispatches will run to completion.
6. `llama_synchronize(ctx)` is correctly called on all exit/error paths in `LlamaInferenceWorker.swift` (lines 397, 405, 428, 471, 488) to block until outstanding GPU work completes before clearing KV memory or deallocating. `[VERIFIED FACT]`

---

## 7. AUDIT E — UTF-8 STREAMING

### 7.1 RFC 3629 Compliance Audit of `UTF8Buffer.swift`
We inspected `UTF8Buffer.swift`:
1. **ASCII Handling:** Bytes `< 0x80` set `expectedLen = 1`, emit character immediately.
2. **2-Byte Sequences:** `(first & 0xE0) == 0xC0 && first >= 0xC2` sets `expectedLen = 2`. Correctly rejects overlong 2-byte sequences (`0xC0`, `0xC1`).
3. **3-Byte Sequences:** `(first & 0xF0) == 0xE0` sets `expectedLen = 3`.
4. **4-Byte Sequences:** `(first & 0xF8) == 0xF0 && first <= 0xF4` sets `expectedLen = 4`. Correctly rejects code points beyond U+10FFFF (`0xF5` through `0xFF`).
5. **Partial Sequences Across Token Boundaries:** If `buffer.count < expectedLen`, `drain()` returns immediately, retaining the bytes until subsequent bytes arrive.
6. **Malformed Byte Recovery:** If an illegal leading byte or malformed sequence is encountered:
   ```swift
   onString("\u{FFFD}")
   buffer.removeFirst()
   ```
   Emits the Unicode replacement character (`\u{FFFD}`) and advances by exactly 1 byte.
7. **Buffer Flushing:** On stream termination, `flush(onString:)` converts remaining valid sequences or flushes replacement characters until the buffer is empty.

### 7.2 Verification Evidence
All 5 dedicated UTF-8 buffer unit tests passed:
- `testUTF8BufferValidASCII`: Valid ASCII streamed intact. `[MEASURED]`
- `testUTF8BufferMultibyteSplitAcrossChunks`: 3-byte Euro symbol (`€`) split across 3 separate 1-byte chunks assembled correctly. `[MEASURED]`
- `testUTF8BufferEmojiSplitAcrossChunks`: 4-byte Rocket emoji (`🚀`) split across chunks assembled without corruption. `[MEASURED]`
- `testUTF8BufferMalformedByteRecovery`: Byte `0xFF` followed by `abc` emits `\u{FFFD}abc` without buffer poisoning. `[MEASURED]`
- `testUTF8BufferTrailingIncompleteFlushedAsReplacement`: Incomplete 2-byte prefix `0xC3` flushed as `\u{FFFD}`. `[MEASURED]`

**Conclusion:** `UTF8Buffer.swift` is verified correct and robustly prevents buffer starvation and memory corruption.

---

## 8. AUDIT F — TOKEN LIMITS, SAMPLERS, AND DECODE ERRORS

### 8.1 Pre-Decode `maxTokens` Boundary
In `LlamaInferenceWorker.swift:455-457`:
```swift
nCur += 1
nDecoded += 1

// Terminate before singleBatch decode if maxTokens boundary has been reached
if nDecoded >= configuration.maxTokens {
    break
}

singleBatch.token[0] = newToken
...
let decodeRes = llama_decode(ctx, singleBatch)
```
**Verification:**
- Once `nDecoded` reaches `configuration.maxTokens`, the loop breaks **immediately** before setting up `singleBatch` and before calling `llama_decode`.
- No redundant final decode is dispatched.
- KV cache is not dirtied with an unused token, and no GPU cycle is wasted.
- Verified by `testExactMaxTokensBoundaryStopsWithoutExtraTokens` in `InferenceGenerationTests.swift:641-655`. `[MEASURED]`

### 8.2 Sampler Chain Order Verification
In `LlamaInferenceWorker.swift:365-376`:
```swift
if configuration.temperature <= 0.0 {
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy())
} else {
    if configuration.topK > 0 {
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(configuration.topK))
    }
    if configuration.topP < 1.0 {
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(configuration.topP, 1))
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(configuration.temperature))
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(configuration.seed))
}
```
**Comparison with Pinned Upstream llama.cpp (`llama.h` / `llama-sampling.cpp`):**
Upstream canonical sampling sequence is:
1. `top_k`: Filters distribution to top K candidates.
2. `top_p`: Filters distribution to cumulative probability mass P.
3. `temp`: Scales logits by `1.0 / temp`.
4. `dist` / `greedy`: Samples token from final distribution.

The sampler chain in `LlamaInferenceWorker.swift` matches canonical upstream ordering exactly. `[VERIFIED FACT]`

---

## 9. AUDIT G — TEST QUALITY AND EVIDENCE EVALUATION

We audited all 32 automated tests across `InferenceGenerationTests.swift` (21 tests) and `InferenceLifecycleTests.swift` (11 tests).

### 9.1 Test Quality Matrix

| Test Name | File | Implementation Target | What Test Actually Proves | What It Fails to Cover / Limitations |
| :--- | :--- | :--- | :--- | :--- |
| `testEmptyAndWhitespacePromptsThrow` | `Generation` | `service.generate` | Pre-flight validation rejects empty/whitespace prompts with pre-failed stream. | Does not invoke native worker. |
| `testInvalidConfigurationValidation` | `Generation` | `GenerationConfiguration.validate` | Boundary checks for contextLength, maxTokens, temperature, topP. | Pure unit test of struct methods. |
| `testGenerateWhenNotLoadedThrows` | `Generation` | `service.generate` | Unloaded service returns preFailed stream throwing `.notLoaded`. | Does not test transition during unload. |
| `testSuccessfulGenerationStreamingInOrder` | `Generation` | `service.generate` | Chunks yield in order; state transitions `.generating -> .loaded`. | Uses `MockGenerationWorker` with simulated delays; no native C execution. |
| `testMaxTokensEnforcement` | `Generation` | `service.generate` | `maxTokens: 3` limits output to 3 tokens. | Mock worker handles limit, not `LlamaInferenceWorker`. |
| `testConsumerEarlyTerminationTriggersCancellation` | `Generation` | `EarlyExitTracker` | Loop break triggers `EarlyExitTracker.deinit` -> `stream.cancel()`. | Uses 50ms sleep to observe state; timing dependent. |
| `testSubsequentGenerationAfterCancellationSucceeds` | `Generation` | Recovery flow | Service can generate again after cancellation. | Mock worker; does not test ADV-01 race where Generation 1 aborts late with error. |
| `testConflictingGenerationThrows` | `Generation` | State machine | Second `generate()` while generating throws `.conflictingOperation`. | Does not test concurrent actor calls arriving in the same microsecond. |
| `testNativeWorkerWhenNotLoadedThrows` | `Generation` | `LlamaInferenceWorker` | Calling `generate()` on uninitialized native worker throws `.notLoaded`. | Tests real `LlamaInferenceWorker` code path. |
| `testStreamRequestedAndAbandonedWithoutIterationHaultsAndRecovers` | `Generation` | `InferenceStream.deinit` | Dropping stream without iterating triggers deinit cancellation. | Relies on 100ms sleep for ARC deinit timing. |
| `testConsumerTaskCancellationPropagatesToWorker` | `Generation` | Task cancellation | Cancelling consumer Task causes `CancellationError` and state recovery. | Tests mock worker; does not test ADV-03 suspension point gap. |
| `testStreamMultipleIteratorsRejected` | `Generation` | `InferenceStream.makeAsyncIterator` | Calling `makeAsyncIterator()` twice throws `.conflictingOperation`. | Deterministic and robust. |
| `testRapidSequentialGenerationRequestsDoNotCorruptState` | `Generation` | State isolation | Conflicting request does not disrupt first active stream. | Both streams run against mock worker. |
| `testRejectedRequestCannotReplaceActiveCancellationSignal` | `Generation` | Signal isolation | Rejected second request does not overwrite `activeCancellationSignal`. | Deterministic and robust. |
| `testUTF8BufferValidASCII` | `Generation` | `UTF8Buffer` | ASCII bytes pass through intact. | Direct component test. |
| `testUTF8BufferMultibyteSplitAcrossChunks` | `Generation` | `UTF8Buffer` | Multi-byte Euro symbol split across chunks assembled properly. | Direct component test. |
| `testUTF8BufferEmojiSplitAcrossChunks` | `Generation` | `UTF8Buffer` | 4-byte Rocket emoji split across chunks assembled properly. | Direct component test. |
| `testUTF8BufferMalformedByteRecovery` | `Generation` | `UTF8Buffer` | Malformed byte replaced with `\u{FFFD}`, subsequent text decoded. | Direct component test. |
| `testUTF8BufferTrailingIncompleteFlushedAsReplacement` | `Generation` | `UTF8Buffer` | Incomplete trailing byte flushed as replacement char. | Direct component test. |
| `testExactMaxTokensBoundaryStopsWithoutExtraTokens` | `Generation` | Loop boundary | `maxTokens: 1` yields exactly 1 token. | Mock worker test. |
| `testGenerationConfigurationValidationAndDefaults` | `Generation` | Config defaults | Default values conform to project spec. | Pure unit test. |
| `testInitialStateIsUnloaded` | `Lifecycle` | `InferenceService.init` | Initial state is `.unloaded`. | Deterministic. |
| `testEmptyAndWhitespaceModelPaths` | `Lifecycle` | `loadModel` validation | Empty model path throws `.invalidModelPath`. | Deterministic. |
| `testNonExistentModelPath` | `Lifecycle` | `loadModel` validation | Non-existent path throws `.modelNotFound`. | Deterministic. |
| `testDirectoryAsModelPath` | `Lifecycle` | `loadModel` validation | Directory path throws `.invalidModelPath`. | Deterministic. |
| `testSuccessfulLoadAndStateTransition` | `Lifecycle` | `loadModel` state | Dummy file loads on mock worker, state becomes `.loaded`. | Mock worker. |
| `testLoadWhenAlreadyLoadedThrows` | `Lifecycle` | `loadModel` conflict | Second load throws `.alreadyLoaded`. | Deterministic. |
| `testUnloadWhenUnloadedIsSafeNoOp` | `Lifecycle` | `unloadModel` | Unload when unloaded is a safe no-op. | Deterministic. |
| `testRepeatedUnloadCallsAreSafe` | `Lifecycle` | `unloadModel` | Repeated unloads are safe idempotent no-ops. | Deterministic. |
| `testFailedLoadLeavesStateFailedAndConsistent` | `Lifecycle` | `loadModel` failure | Worker failure sets `.failed`, subsequent valid load recovers. | Mock worker. |
| `testStateStreamReceivesTransitions` | `Lifecycle` | `stateStream` | Observers receive all transitions in sequence. | Uses `StateAccumulator` and expectation. |
| `testNativeWorkerWithInvalidFormatFailsSafely` | `Lifecycle` | `LlamaInferenceWorker` | Native `llama.cpp` loader rejects plain text file safely. | **Executes real native llama.cpp library and initializes Metal device!** |

### 9.2 Key Test Limitations Identified
1. **Mock Reliance:** 20 out of 21 tests in `InferenceGenerationTests` use `MockGenerationWorker`. While effective for state machine testing, they do not verify native C memory allocation, Metal command buffer synchronization, or native decode errors under stress.
2. **Defect Blind Spot:** No test currently checks what happens if Generation 1 is cancelled, a new Generation 2 starts, and Generation 1's worker throws a late non-cancellation error. This allowed Defect ADV-01 to go completely unnoticed.
3. **ARC Timing Sensitivity:** Tests for stream abandonment and early exit rely on fixed `Task.sleep` durations (50ms–100ms). While passing reliably on M5 Apple Silicon, these are not strictly deterministic synchronizations.

---

## 10. LIFECYCLE BEHAVIOR MATRIX

| Execution Scenario | Service State Transition | Worker Queue Action | Stream / Iterator Outcome | CancellationSignal State |
| :--- | :--- | :--- | :--- | :--- |
| **Stream Created, Never Iterated (Abandoned)** | `.loaded -> .generating -> .loaded` (premature via ADV-02) | Cancelled before or during prompt eval | Stream deinitializes; task cancelled | Asserted (1) by `InferenceStream.deinit` |
| **Consumer Breaks Early from Loop** | `.generating -> .loaded` (premature via ADV-02) | Aborts at next token boundary; syncs GPU | Iterator drops; `EarlyExitTracker.deinit` cancels | Asserted (1) by `EarlyExitTracker.deinit` |
| **Consumer Task Cancelled (Idle/Between Tokens)** | `.generating -> .loaded` (premature via ADV-02) | Aborts at next token boundary; syncs GPU | `next()` throws `CancellationError` | Asserted (1) by `AsyncIterator.next()` |
| **Consumer Task Cancelled (During Suspended `next()`)** | `.generating -> .loaded` (premature via ADV-02) | Continues computing until next token yields (ADV-03) | Blocks until token arrives, then throws | Delayed assertion until `next()` resumes |
| **Normal Completion (EOS or maxTokens)** | `.generating -> .loaded` | Drains UTF-8 buffer, syncs GPU, clears KV | Returns `nil`, marks completed | Unasserted (0) |
| **Worker Fails (Decode Error - Isolated)** | `.generating -> .failed(error)` | Syncs GPU, clears KV cache | Throws `InferenceError` | Unasserted (0) |
| **Worker Fails (Late Error after Cancellation + New Gen)** | **CORRUPTS TO `.failed` (ADV-01)** | Unwinds old worker execution | Clobbers active Generation 2 state | Unasserted / Clobbered |
| **Concurrent Second Request** | First stays `.generating`; second rejected | Second request rejected on actor; never reaches worker | Second receives `preFailed(.conflictingOperation)` | Original signal untouched |
| **Model Unload During Generation** | Rejected immediately | Generation continues uninterrupted | `unloadModel()` throws `.conflictingOperation` | Untouched |
| **Model Unload Immediately After Stream Cancel** | **RACES (ADV-02)** | Unload enqueued while generate still unwinding | Undefined worker overlap | Untouched |

---

## 11. NATIVE INFERENCE GUARANTEES (PROVEN VS ASSUMED)

| Capability / Behavior | Audit Classification | Justification & Source Evidence |
| :--- | :--- | :--- |
| **C11 Atomic Memory Ordering** | `[VERIFIED FACT]` | Confirmed in `AetherAtomic.c`: uses C11 `stdatomic.h` with explicit `memory_order_release` (store) and `memory_order_acquire` (load). |
| **Abort Callback Storage Lifetime** | `[VERIFIED FACT]` | Confirmed in `LlamaInferenceWorker.swift:351-354`: defer block deregisters callback (`llama_set_abort_callback(ctx, nil, nil)`) before worker exits. |
| **Teardown Destruction Order** | `[VERIFIED FACT]` | Confirmed in `LlamaInferenceWorker.swift:46-56, 230-243`: Context is synchronized and freed (`llama_free`) before model is freed (`llama_model_free`), and model before backend (`llama_backend_free`). |
| **Token-Boundary Worker Cancellation** | `[VERIFIED FACT]` | Confirmed in `LlamaInferenceWorker.swift:396, 427`: Worker checks `cancellationSignal.isCancelled` before prompt decode and before each token generation step. |
| **Immediate Metal Kernel Interruption** | `[VERIFIED FACT]` (Negative) | Confirmed in `ggml-metal-context.m:586, 644, 768`: Metal backend does not check abort callback during ordinary asynchronous graph execution. In-flight GPU kernels always run to completion. |
| **Immediate Worker Quiescence on Cancel** | `[VERIFIED FACT]` (Negative) | Disproven by Defect ADV-02: `InferenceService` resets to `.loaded` while worker execution is still active on worker thread. |
| **Real GGUF Model Inference on Metal** | `[UNVERIFIED]` | Real model weights have not been evaluated because model files are not downloaded. Only GGUF format rejection and mock worker paths have been tested. |

---

## 12. TEST AND BUILD EVIDENCE

### 12.1 Test Suite Run (`xcodebuild test`)
* **Command:** `xcodebuild test -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS'`
* **Timestamp:** `2026-10-19 09:15:41.112`
* **Result:** `** TEST SUCCEEDED **`
* **Executed:** 32 tests (21 `InferenceGenerationTests`, 11 `InferenceLifecycleTests`).
* **Failures:** 0 unexpected failures, 0 errors.
* **Duration:** 1.101 seconds.
* **Metal Device Diagnostics Captured During Test:**
  ```
  ggml_metal_device_init: GPU name:   MTL0 (Apple M5)
  ggml_metal_device_init: GPU family: MTLGPUFamilyApple10  (1010)
  ggml_metal_device_init: GPU family: MTLGPUFamilyMetal4  (5002)
  ggml_metal_device_init: simdgroup reduction   = true
  ggml_metal_device_init: simdgroup matrix mul. = true
  ggml_metal_device_init: has unified memory    = true
  ggml_metal_device_init: recommendedMaxWorkingSetSize  = 12713.12 MB
  ```

### 12.2 Debug Build (`xcodebuild build -configuration Debug`)
* **Command:** `xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Debug`
* **Result:** `** BUILD SUCCEEDED **`
* **Warnings:** 0 compiler warnings, 0 concurrency diagnostics.

### 12.3 Release Build (`xcodebuild build -configuration Release`)
* **Command:** `xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Release`
* **Result:** `** BUILD SUCCEEDED **`
* **Warnings:** 0 compiler warnings, 0 concurrency diagnostics.

---

## 13. REPOSITORY AND SECURITY INTEGRITY CONFIRMATION

| Item | Requirement | Status | Evidence |
| :--- | :--- | :--- | :--- |
| **llama.cpp Pinned Revision** | `547208dca250ceb3e4c8615598d043f2b602a527` | Clean / Verified | `git -C reference-repos/.../llama.cpp rev-parse HEAD` returned exact commit. |
| **llama.cpp Working Tree** | Clean, unmodified | Clean / Verified | `git -C reference-repos/.../llama.cpp status` returned `working tree clean`. |
| **App Sandbox Entitlements** | Unmodified, sandboxed | Clean / Verified | `Aether.entitlements` contains only `com.apple.security.app-sandbox = true`. |
| **External Dependencies** | None added | Clean / Verified | No packages or Homebrew dependencies introduced. |
| **Model Downloads** | None authorized, zero downloaded | Clean / Verified | Workspace and temporary containers contain no GGUF model files. |
| **Audit Modifications** | Read-only audit | Clean / Verified | Only this report (`research/23-phase-3.4.6-adversarial-verification.md`) was written. |

---

## 14. REMAINING RISKS AND PRIORITIZED NEXT STEPS

### 14.1 Priority Defects for Remediation Phase 3.4.7

1. **Remediate Defect ADV-01 (Priority 1 - High):**  
   In `InferenceService.executeGeneration`, guard the catch block state mutation with an ownership check:
   ```swift
   if mappedError != .cancelled {
       if self.activeGenerationId == generationId {
           self.state = .failed(errorDescription: mappedError.localizedDescription)
       }
   }
   ```
2. **Remediate Defect ADV-02 (Priority 2 - High):**  
   Refactor stream cancellation and state restoration so that `self.state = .loaded` and `self.activeGenerationId = nil` are **deferred until `generationTask` completes**. For example, `generationTask` can await `worker.generate()` and perform the state transition inside its actor `defer` block, while `handleStreamTermination` only asserts `signal.cancel()` and cancels `generationTask` without resetting state prematurely.
3. **Remediate Defect ADV-03 (Priority 3 - Medium):**  
   Wrap `baseIterator.next()` inside `withTaskCancellationHandler` in `InferenceStream.AsyncIterator.next()` to ensure immediate cooperative cancellation propagation when consumer tasks cancel while suspended.
4. **Add Regression Tests for ADV-01 and ADV-02:**  
   Implement automated regression tests in `InferenceGenerationTests.swift` specifically verifying:
   - Generation 1 cancelled -> Generation 2 starts -> Generation 1 throws late error -> Generation 2 state remains `.generating`.
   - Stream cancelled -> `service.unloadModel()` awaits worker completion without racing.

### 14.2 Recommendation on Project Progression
Do **not** proceed to Phase 3.5 (UI / Product features) while ADV-01 and ADV-02 remain in the inference coordinator. Authorized remediation should be conducted under a narrow Phase 3.4.7 to permanently eliminate these concurrency defects.
