# AETHER — PHASE 3.4.7 REPORT
## Critical Concurrency & Ownership Remediation

**Date:** October 19, 2026  
**Status:** Complete  
**Execution Verdict:** PASS  
**Project:** Aether  
**Previous Phase:** 3.4.6 — Adversarial Verification Audit (`research/23-phase-3.4.6-adversarial-verification.md`)  
**Pinned upstream revision:** `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`)  
**Target Environment:** macOS 14.0+, Apple Silicon (arm64, M5 MacBook Air 16GB)  
**Strict Concurrency:** Swift 6 (`SWIFT_STRICT_CONCURRENCY = complete`)

---

## 1. EXECUTIVE VERDICT

### **VERDICT: PASS**

Phase 3.4.7 has resolved all three confirmed defects identified during the Phase 3.4.6 adversarial audit (`ADV-01`, `ADV-02`, and `ADV-03`). The inference service architecture, stream sequence, and iterator lifecycles now strictly enforce explicit ownership tokens, deterministic completion barriers, and asynchronous cancellation propagation:

1. **ADV-01 (HIGH) Remediated:** State mutations in error, completion, and cleanup pathways in `InferenceService.executeGeneration` are guarded with `self.activeGenerationId == generationId`. A stale generation encountering a late failure or decode abort can no longer mutate the state or overwrite the cancellation signal of an accepted newer generation. `[VERIFIED FACT]`
2. **ADV-02 (HIGH) Remediated:** Stream cancellation, loop break, and consumer abandonment no longer trigger premature state transitions to `.loaded`. The detached termination task has been eliminated. The transition out of `.generating` to `.loaded` occurs exclusively within the generation task's `defer` block after `worker.generate()` has completely exited and synchronized with the worker queue. While cancellation is pending and native worker execution is active, the service strictly rejects conflicting generation requests and model unload operations. `[VERIFIED FACT]`
3. **ADV-03 (MEDIUM) Remediated:** `InferenceStream.AsyncIterator.next()` wraps forward iteration in `withTaskCancellationHandler(operation:onCancel:)`. Consumer task cancellation while suspended awaiting token output immediately triggers `stream.cancel()`, asserting the atomic `CancellationSignal` without waiting for the next token to be decoded or emitted. Generation errors and EOF semantics are strictly preserved. `[VERIFIED FACT]`

The remediation was verified by adding 6 deterministic, gate-controlled regression tests (with zero reliance on arbitrary sleeps), achieving **38 / 38 passing tests** across `InferenceGenerationTests` and `InferenceLifecycleTests`. Both Debug and Release builds compile cleanly with zero concurrency diagnostics under Swift 6 strict concurrency.

---

## 2. FINDING-BY-FINDING REMEDIATION

### 2.1 Finding ADV-01 (HIGH) — Stale Generation Error State Corruption

#### Original Defect & Root Cause
In Phase 3.4.5, `InferenceService.executeGeneration` lines 342–344 caught errors from `worker.generate(...)` and unconditionally assigned:
```swift
if mappedError != .cancelled {
    self.state = .failed(errorDescription: mappedError.localizedDescription)
}
```
If Generation A was cancelled or completed, and Generation B was subsequently accepted, Generation A's background task could catch a late non-cancellation error (e.g. simulated decode error, context abort) and overwrite `self.state` with `.failed`, clobbering Generation B's active `.generating` state.

#### Corrected Design & Changes
- **File:** `Aether/Sources/Inference/InferenceService.swift`
- **Lines Changed:** 339–344
- **Implementation:**
  ```swift
  if mappedError != .cancelled {
      if self.activeGenerationId == generationId {
          self.state = .failed(errorDescription: mappedError.localizedDescription)
      }
  }
  ```
  Both the error-state assignment and the `defer` state restoration (`defer { if self.activeGenerationId == generationId { ... } }`) strictly verify ownership of `self.activeGenerationId` before mutating actor state.

#### Regression Tests Added
- `testADV01_staleGenerationCannotCorruptActiveGeneration`: Uses a mock worker to trigger Generation A, cancels A, releases A with a simulated decode failure, accepts Generation B, and verifies that A's late error is safely discarded by the actor state machine. Generation B runs to completion and restores `.loaded`. `[MEASURED]`

#### Before-and-After Behavior
- **Before:** Generation A's error set `service.state = .failed`, leaving the service unusable even though Generation B was actively generating.
- **After:** Generation A's error only terminates its own `AsyncThrowingStream` continuation; `service.state` remains strictly associated with Generation B.

#### Remaining Limitations
The check relies on Swift actor isolation ensuring atomic evaluation of `self.activeGenerationId == generationId` and state assignment. This is fully thread-safe within the Swift concurrency runtime.

---

### 2.2 Finding ADV-02 (HIGH) — Premature `.loaded` State Restoration

#### Original Defect & Root Cause
In Phase 3.4.5, `InferenceService.generate()` configured stream termination as:
```swift
let onTermination: @Sendable () -> Void = { [weak self] in
    signal.cancel()
    generationTask.cancel()
    Task { [weak self] in
        await self?.handleStreamTermination(generationId: generationId, modelInfo: modelInfo)
    }
}
```
`handleStreamTermination` immediately cleared `self.activeGenerationId` and set `self.state = .loaded(modelInfo:)` in a detached task without awaiting `generationTask` or `worker.generate()`. Consequently, external consumers observed `.loaded` while the native worker thread or GPU command buffer was still executing.

#### Corrected Design & Changes
- **File:** `Aether/Sources/Inference/InferenceService.swift`
- **Lines Changed:** 270–284, 300–309
- **Implementation:**
  1. Completely removed `handleStreamTermination(generationId:modelInfo:)`.
  2. Stream termination and cancellation handlers now only signal cancellation:
     ```swift
     let onTermination: @Sendable () -> Void = {
         signal.cancel()
         generationTask.cancel()
     }
     continuation.onTermination = { @Sendable _ in
         onTermination()
     }
     ```
  3. State restoration to `.loaded` and clearing of `activeGenerationId` is performed **exclusively** inside the `defer` block of `executeGeneration`:
     ```swift
     defer {
         if self.activeGenerationId == generationId {
             self.activeGenerationId = nil
             self.activeCancellationSignal = nil
             self.activeGenerationTask = nil
             if case .generating = self.state {
                 self.state = .loaded(modelInfo: modelInfo)
             }
         }
     }
     ```
     Because `executeGeneration` awaits `worker.generate(...)`, this `defer` block cannot execute until the worker has completely returned, synchronized in-flight Metal commands via `llama_synchronize(ctx)`, and exited the serial worker queue.
  4. Added `public func waitForTermination() async` to `InferenceStream`, allowing callers and tests to deterministically await generation task exit.
  5. Added preflight cancellation check at the start of `executeGeneration` to prevent starting worker work if already cancelled before dispatch.

#### Regression Tests Added
- `testADV02_serviceDoesNotRestoreLoadedWhileWorkerActive`: Gates the worker inside `generate()`, triggers `stream.cancel()`, and confirms that while the worker is held in the gate, `service.state` remains `.generating`. Verifies that conflicting `generate()` calls and `unloadModel()` calls are rejected with `.conflictingOperation`. Only after the gate is opened and the worker finishes does the service return to `.loaded`. `[MEASURED]`
- `testADV02_cancellationFollowedByDelayedNativeErrorLeavesFailedState`: Cancels an active generation held in a gate, then causes the worker to exit with a native error. Verifies that the service transitions to `.failed` (reflecting native abort) without ever improperly exposing an intermediate `.loaded` state. `[MEASURED]`

#### Before-and-After Behavior
- **Before:** A cancellation request was conflated with completed cancellation; consumers could immediately unload the model or start a new generation while the worker was active.
- **After:** Cancellation request is decoupled from completion. State transitions out of `.generating` only when native execution has terminated and synchronized.

#### Remaining Limitations
In-flight Metal GPU kernels execute to completion at cooperative token boundaries (per ADV-05). Metal does not support asynchronous kernel preemption; the worker completion barrier ensures host synchronization before state restoration.

---

### 2.3 Finding ADV-03 (MEDIUM) — Unbounded Cancellation Latency in `AsyncIterator.next()`

#### Original Defect & Root Cause
In Phase 3.4.5, `InferenceStream.AsyncIterator.next()` called `try await baseIterator.next()` directly. If the consumer task was cancelled while suspended awaiting prompt evaluation or token generation, `baseIterator.next()` was not notified, and cancellation remained unhandled until a token was emitted or the stream closed.

#### Corrected Design & Changes
- **File:** `Aether/Sources/Inference/InferenceService.swift`
- **Lines Changed:** 463–520
- **Implementation:**
  1. Introduced a Sendable storage wrapper around the underlying iterator:
     ```swift
     private final class Storage: @unchecked Sendable {
         var baseIterator: AsyncThrowingStream<String, Error>.AsyncIterator?
         init(baseIterator: AsyncThrowingStream<String, Error>.AsyncIterator?) {
             self.baseIterator = baseIterator
         }
         func next() async throws -> String? {
             guard baseIterator != nil else { return nil }
             return try await baseIterator?.next()
         }
     }
     ```
  2. Wrapped forward progress in `withTaskCancellationHandler`:
     ```swift
     let nextItem: String? = try await withTaskCancellationHandler(
         operation: {
             try await storage.next()
         },
         onCancel: {
             stream?.cancel()
         }
     )
     ```
  3. If consumer task cancellation occurs during suspension, `onCancel` executes immediately on the cancellation thread, invoking `stream?.cancel()`, which sets `cancellationSignal.cancel()` and cancels `generationTask`.

#### Regression Tests Added
- `testADV03_cancellationWhileNextSuspendedPropagatesPromptly`: Starts consumption of a stream, blocks the worker before the first token, suspends consumer in `for try await`, cancels consumer task, and verifies that `signal.isCancelled` becomes `true` immediately without any token emission. `[MEASURED]`
- `testADV03_cancellationCallbackFromTerminatedGenerationCannotCancelNewGeneration`: Verifies that an orphaned cancellation handler from Generation 1 cannot cancel Generation 2's signal. `[MEASURED]`
- `testADV03_workerErrorsAreNotSwallowedOrTransformedToCancellation`: Verifies that native decode errors and worker errors are delivered to the consumer as genuine errors rather than converted to `CancellationError`. `[MEASURED]`

#### Before-and-After Behavior
- **Before:** Consumer task cancellation was dormant during suspension; slow prompts or stalled decodes would hang until unblocked.
- **After:** Consumer task cancellation immediately triggers cooperative cancellation in the native generation worker.

#### Remaining Limitations
The cancellation handler requests cooperative cancellation via the C11 atomic signal. The worker checks this signal between token evaluation steps. Cancellation latency is bounded by the time required for a single token's batch evaluation.

---

## 3. LIFECYCLE AND STATE-TRANSITION EVIDENCE

The following matrix documents the precise lifecycle events, authority, state, and native resource guarantees across all phases of generation:

| Phase / Event | Authority | Service State | Worker Queue Status | Native Context / Resource Status | Guarantees Enforced |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Generation Requested & Accepted** | `InferenceService.generate()` | `.generating(modelInfo)` | Idle or accepting work | Valid, reserved | Atomic state mutation on actor. Generation ID and Signal allocated. Conflicting operations rejected. |
| **Worker Execution Active** | `LlamaInferenceWorker.generate()` | `.generating(modelInfo)` | Serial thread running `syncGenerate` | Context active, KV cache mutating, Metal kernels dispatching | Service remains in `.generating`. Unload and second generation strictly forbidden. |
| **Cancellation Requested (Stream Cancel / Task Cancel)** | `InferenceStream.cancel()` or `onCancel` | `.generating(modelInfo)` | Serial thread still executing until next check | Context active, in-flight Metal commands executing | **State does NOT change to `.loaded`.** `CancellationSignal` asserted atomically. `activeGenerationId` retained. |
| **Worker Cooperative Exit** | `LlamaInferenceWorker.generate()` | `.generating(modelInfo)` | Unwinding `syncGenerate`; executing `llama_synchronize(ctx)` | Cleaned up sampler, context synchronized with host | In-flight GPU work synchronized before function exit. |
| **Worker Task Completion Barrier** | `executeGeneration` (defer block) | Transitions to `.loaded(modelInfo)` | Serial queue idle | Resources quiescent, safe for subsequent use | **Only authority for `.loaded` restoration.** Clears `activeGenerationId` and `activeCancellationSignal`. |
| **Late / Stale Error Arrival** | `executeGeneration` (catch block) | Stays `.loaded` or `.failed` | Worker queue idle | Safely reported or discarded | Guard `activeGenerationId == generationId` prevents corrupting newer generations. |
| **Model Unloading Requested** | `InferenceService.unloadModel()` | `.unloading` | Enqueuing `syncUnloadModel` | Teardown initiated | Only permitted when `state == .loaded`. Never races with active worker. |
| **Model Unloaded** | `InferenceService.unloadModel()` | `.unloaded` | Teardown complete | `llama_context` freed before `llama_model` | Complete native release. |

---

## 4. REGRESSION TEST EVIDENCE

All tests were executed on macOS 14+ Apple Silicon via `xcodebuild test`:

| Test Name | Test Suite | Proves | Mock or Native | Result |
| :--- | :--- | :--- | :--- | :--- |
| `testADV01_staleGenerationCannotCorruptActiveGeneration` | `InferenceGenerationTests` | Stale error from aborted generation cannot mutate state of newer active generation | Mock | **PASS** (0.002s) |
| `testADV02_serviceDoesNotRestoreLoadedWhileWorkerActive` | `InferenceGenerationTests` | Service does not restore `.loaded` while worker is active; rejects conflicting operations | Mock | **PASS** (0.001s) |
| `testADV02_cancellationFollowedByDelayedNativeErrorLeavesFailedState` | `InferenceGenerationTests` | Cancellation followed by delayed native abort settles in `.failed`, never premature `.loaded` | Mock | **PASS** (0.001s) |
| `testADV03_cancellationWhileNextSuspendedPropagatesPromptly` | `InferenceGenerationTests` | Consumer task cancellation while suspended in `next()` immediately asserts cancellation signal | Mock | **PASS** (0.001s) |
| `testADV03_cancellationCallbackFromTerminatedGenerationCannotCancelNewGeneration` | `InferenceGenerationTests` | Cancellation callbacks from older generations cannot affect newer generation signal | Mock | **PASS** (0.001s) |
| `testADV03_workerErrorsAreNotSwallowedOrTransformedToCancellation` | `InferenceGenerationTests` | Non-cancellation decode errors are preserved and delivered to consumer without alteration | Mock | **PASS** (0.001s) |
| `testEmptyAndWhitespacePromptsThrow` | `InferenceGenerationTests` | Rejection of empty/whitespace prompts | Mock | **PASS** (0.002s) |
| `testInvalidConfigurationValidation` | `InferenceGenerationTests` | Configuration validation failure paths | Unit | **PASS** (0.001s) |
| `testGenerateWhenNotLoadedThrows` | `InferenceGenerationTests` | Rejection of generation when unloaded | Mock | **PASS** (0.001s) |
| `testSuccessfulTokenStreaming` | `InferenceGenerationTests` | Normal end-to-end multi-token streaming | Mock | **PASS** (0.001s) |
| `testMaxTokensEnforced` | `InferenceGenerationTests` | Token cutoff at configured limit | Mock | **PASS** (0.001s) |
| `testDecodeFailurePropagatesAndSetsFailedState` | `InferenceGenerationTests` | Decode failure error propagation and state settling | Mock | **PASS** (0.002s) |
| `testExplicitCancellationViaServiceMethod` | `InferenceGenerationTests` | `service.cancelGeneration()` API correctness | Mock | **PASS** (0.001s) |
| `testExplicitCancellationViaStreamMethod` | `InferenceGenerationTests` | `stream.cancel()` API correctness | Mock | **PASS** (0.001s) |
| `testConsumerEarlyTerminationTriggersCancellation` | `InferenceGenerationTests` | Iterator deinit on loop break triggers cancellation | Mock | **PASS** (0.001s) |
| `testStreamRequestedAndAbandonedWithoutIterationHaultsAndRecovers` | `InferenceGenerationTests` | Stream drop without iteration halts generation | Mock | **PASS** (0.001s) |
| `testPreFlightCancellationChecks` | `InferenceGenerationTests` | Pre-flight cancellation checks in worker and service | Mock | **PASS** (0.001s) |
| `testStateTransitionsDuringGenerationLifecycle` | `InferenceGenerationTests` | State transitions across complete lifecycle | Mock | **PASS** (0.002s) |
| `testWorkerTeardownDuringActiveGeneration` | `InferenceGenerationTests` | Safe worker shutdown while active | Mock | **PASS** (0.001s) |
| `testPromptTokenEvaluationLimitRejection` | `InferenceGenerationTests` | Prompt token limit guards | Mock | **PASS** (0.001s) |
| `testPreDecodeMaxTokensEnforcement` | `InferenceGenerationTests` | Token limit enforcement before decode | Mock | **PASS** (0.001s) |
| `testUTF8BufferSplitTwoByteSequence` | `InferenceGenerationTests` | UTF-8 multi-byte sequence assembly | Unit | **PASS** (0.001s) |
| `testUTF8BufferSplitThreeByteSequence` | `InferenceGenerationTests` | 3-byte UTF-8 character assembly across chunks | Unit | **PASS** (0.001s) |
| `testUTF8BufferSplitFourByteSequence` | `InferenceGenerationTests` | 4-byte emoji assembly across chunks | Unit | **PASS** (0.001s) |
| `testUTF8BufferFlushIncompleteBytes` | `InferenceGenerationTests` | Incomplete byte replacement on stream flush | Unit | **PASS** (0.001s) |
| `testUTF8BufferInvalidContinuationBytesFlushedAsReplacement` | `InferenceGenerationTests` | Corrupted byte fallback handling | Unit | **PASS** (0.001s) |
| `testUTF8BufferValidASCII` | `InferenceGenerationTests` | Standard ASCII fast-path pass-through | Unit | **PASS** (0.001s) |
| `testDirectoryAsModelPath` | `InferenceLifecycleTests` | Rejection of directory paths | Unit | **PASS** (0.001s) |
| `testEmptyAndWhitespaceModelPaths` | `InferenceLifecycleTests` | Rejection of empty model paths | Unit | **PASS** (0.001s) |
| `testFailedLoadLeavesStateFailedAndConsistent` | `InferenceLifecycleTests` | Failed load handling | Mock | **PASS** (0.002s) |
| `testInitialStateIsUnloaded` | `InferenceLifecycleTests` | Initial state verification | Unit | **PASS** (0.001s) |
| `testLoadWhenAlreadyLoadedThrows` | `InferenceLifecycleTests` | Double-load rejection | Mock | **PASS** (0.003s) |
| `testNativeWorkerWithInvalidFormatFailsSafely` | `InferenceLifecycleTests` | Native loader rejects non-GGUF file safely | **Native (llama.cpp)** | **PASS** (0.060s) |
| `testNonExistentModelPath` | `InferenceLifecycleTests` | Missing file error handling | Unit | **PASS** (0.001s) |
| `testRepeatedUnloadCallsAreSafe` | `InferenceLifecycleTests` | Idempotent unloads | Mock | **PASS** (0.001s) |
| `testStateStreamReceivesTransitions` | `InferenceLifecycleTests` | State notification stream verification | Mock | **PASS** (0.001s) |
| `testSuccessfulLoadAndStateTransition` | `InferenceLifecycleTests` | Successful load state transitions | Mock | **PASS** (0.001s) |
| `testUnloadWhenUnloadedIsSafeNoOp` | `InferenceLifecycleTests` | Safe no-op on unloaded service | Mock | **PASS** (0.001s) |

**Total Tests:** 38  
**Passed:** 38 (100%) `[MEASURED]`  
**Failed:** 0 `[MEASURED]`  
**Execution Time:** 1.082s `[MEASURED]`

---

## 5. BUILD EVIDENCE

### 5.1 Debug Build
- **Command:** `xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Debug`
- **Result:** `** BUILD SUCCEEDED **` `[MEASURED]`
- **Diagnostics:** 0 errors, 0 warnings (except standard AppIntents metadata notice).

### 5.2 Release Build
- **Command:** `xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Release`
- **Result:** `** BUILD SUCCEEDED **` `[MEASURED]`
- **Diagnostics:** 0 errors, 0 warnings.

### 5.3 Swift Concurrency Validation
- **Configuration:** `SWIFT_STRICT_CONCURRENCY = complete`
- **Language Mode:** Swift 6
- **Result:** Clean compilation with zero concurrency diagnostics across actor boundaries, `@Sendable` closures, and cross-thread signals.

---

## 6. NATIVE SAFETY ANALYSIS

1. **Callback Lifetime:**
   The `llama_progress_callback` and token delivery closures remain alive for the exact duration of the worker invocation. No pointers to Swift structs or temporary buffers escape to native asynchronous dispatch queues.
2. **C11 Atomic Signal Ownership:**
   `CancellationSignal` wraps an atomic C11 pointer allocated via `aether_atomic_bool_create()`. Each generation owns its independent signal. Old cancellation signals or delayed callbacks cannot cancel a newly allocated signal.
3. **Worker Serialization:**
   All native operations (`llama_model_load`, `llama_init_from_model`, `llama_decode`, `llama_synchronize`, `llama_free`, `llama_model_free`) execute exclusively on the dedicated serial dispatch queue `com.aether.inference.worker`. This prevents any concurrent access to native context, batch, or model pointers.
4. **Metal Synchronization:**
   Before releasing resources or exiting `syncGenerate`, `LlamaInferenceWorker` invokes `llama_synchronize(ctx)` to ensure that any GPU command buffers submitted to the Apple Silicon Metal command queue are completely finished before the host releases temporary batches or marks work complete.
5. **Native Teardown Order:**
   During unload, `llama_free(ctx)` is strictly called before `llama_model_free(model)`. `ctx` is nulled immediately.

---

## 7. INTEGRITY CONFIRMATION

- **Pinned Upstream Revision:** `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`) `[VERIFIED FACT]`
- **Upstream Working Tree:** Clean (`git status` reports 0 modifications) `[VERIFIED FACT]`
- **Dependencies:** 0 dependencies added `[VERIFIED FACT]`
- **Model Downloads:** 0 models downloaded `[VERIFIED FACT]`
- **Sandbox Entitlements:** Strictly unchanged (`com.apple.security.app-sandbox = true`, `com.apple.security.get-task-allow = true`) `[VERIFIED FACT]`
- **Diff Scope:** Strictly limited to `InferenceService.swift`, `InferenceGenerationTests.swift`, and this report. `[VERIFIED FACT]`

---

## 8. EVIDENCE CLASSIFICATIONS

- `[MEASURED]`: Test execution results (38/38 passing, 1.082s total duration), Debug and Release build outcomes, and upstream commit hash.
- `[VERIFIED FACT]`: Line numbers, source diffs, Swift actor isolation semantics, ARC lifetimes, and C11 atomic behavior.
- `[CALCULATED]`: Latency bounds for single-token Metal kernel dispatches and cooperative cancellation intervals.
- `[ESTIMATED]`: N/A.
- `[UNVERIFIED]`: End-to-end native token streaming against a real physical GGUF model file on disk (mocked in unit test suite per scope boundary).

---

## 9. REMAINING RISKS AND NEXT RECOMMENDATION

### Remaining Low-Risk Constraints
1. **Real-Model Validation:**
   While `testNativeWorkerWithInvalidFormatFailsSafely` exercises real native `llama.cpp` C code and Metal device initialization, real multi-token text generation has been validated using the high-fidelity `MockGenerationWorker`. End-to-end validation with a real GGUF model file remains to be performed once model download or import is authorized.

### Next Recommendation
All critical, high, and medium defects from Phase 3.4.6 are fully remediated and verified. The inference foundation is rock-solid, concurrency-safe, and ready for model management and UI integration.

**Recommendation:** Await authorization to proceed to **Phase 3.4.8 (Real Model Integration & GGUF Validation)** or **Phase 3.5 (Model Library & UI Integration)**.
