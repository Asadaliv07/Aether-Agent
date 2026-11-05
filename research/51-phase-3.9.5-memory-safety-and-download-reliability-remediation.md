# AETHER — PHASE 3.9.5 IMPLEMENTATION REPORT
## Targeted Reliability & Memory-Safety Remediation (DEF-39-04, DEF-39-05, DEF-39-06)

**Project:** Aether  
**Workspace:** `/Users/asadalishaikh/Aether Agent`  
**Execution Context:** Gate C Authorized Implementation & Regression Verification  
**Date:** October 19, 2026  
**Status:** IMPLEMENTATION COMPLETE — All 3 Defects Remediated, 18 New Regression Tests Added, Full Suite (204/204 Tests) Passing, Debug & Release Builds Succeeded.  
**Deliverable File:** `research/51-phase-3.9.5-memory-safety-and-download-reliability-remediation.md`  

---

## 1. Executive Summary & Authorization Scope

Phase 3.9.5 executes targeted, minimal remediation for the three audited defects identified and classified in `research/50-phase-3.9.4-end-to-end-acceptance-and-memory-audit.md`:

1. **DEF-39-04 (High Priority — Runtime Memory Compatibility Assessment):** Replaced the simplistic disk-file-size threshold with a conservative, physics-grounded runtime memory admission budget incorporating model weight memory, exact GGUF architecture-derived Key-Value (KV) cache memory, compute scratch buffer overhead (`sched_reserve`), and tiered macOS operating system reserves. Missing or untrusted metadata safely transitions to `.unknown` with diagnostic explanations.
2. **DEF-39-05 (Medium Priority — Interrupted Download Recovery):** Reconciled orphaned in-flight downloads left in `.downloading` or `.pending` states following abrupt application crashes, process SIGKILL, or system power loss. Reconciles non-active download tasks to `.paused` with user-visible explanations, validates binary/XML property-list resume data integrity, safely resets corrupt resume artifacts to enable clean restarts, and guarantees idempotent launch behavior without duplicate tasks.
3. **DEF-39-06 (Medium Priority — Orphaned GGUF Cleanup After Registration Failure):** Enforced atomic file installation and rollback semantics in `handleDownloadFinished`. Tracks filesystem ownership so that if SQLite catalog registration or post-move validation throws an error, only the newly promoted `.gguf` artifact is cleanly unlinked, while strictly protecting pre-existing user files from deletion or corruption.

### Key Verification Metrics
- **Focused Defect Tests:** 49 of 49 passed (28 `ModelLibraryTests` in 0.086s + 21 `ModelDownloadManagerTests` in 0.140s).
- **Full Application Regression Suite:** **204 of 204 tests passed** (0 failures, 0 regressions) in **19.870 seconds** on native Apple Silicon (`arm64`).
- **Build Configurations:** Both `Debug` and `Release` targets compiled and signed cleanly (`** BUILD SUCCEEDED **`).
- **Strict Scope Boundaries:** Zero new external dependencies, zero database schema migrations, zero entitlement modifications, and zero changes to the pinned `llama.cpp` revision (`b11718`).

---

## 2. Workspace & Toolchain Baseline

### 2.1 Workspace Configuration
- **Path:** `/Users/asadalishaikh/Aether Agent`
- **Version Control Status:** Files managed directly in workspace directory tree. Unrelated files in `reference-repos/` and `.build/` preserved untouched.
- **Pinned llama.cpp Revision:** Commit `547208dca250ceb3e4c8615598d043f2b602a527` (tag `b11718`) in `reference-repos/01-apple-silicon-and-inference/llama.cpp`.
- **Pre-compiled Binary Framework:** Embedded `Aether/Frameworks/llama.xcframework` (`macos-arm64`).

### 2.2 Host Environment
- **Hardware:** Apple M5 (16 GB Unified Memory, `hw.memsize: 17179869184` bytes)
- **Host OS:** macOS 27.0.1 (Darwin 26A434 / `arm64`)
- **Xcode Version:** Xcode 27.1 (Build `27A9275`)
- **Swift Compiler:** Apple Swift version 6.4 (`swiftlang-6.4.0.34.1 clang-2100.3.34.1`)
- **Deployment Target:** macOS 14.0 (Sonoma)

### 2.3 Packaged Entitlements Active
Verified via `codesign -d --entitlements :-` on the built application bundle:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
```

---

## 3. Mandatory Reference-Repository Investigation

In adherence to Aether's repository-first engineering discipline, reference repositories under `reference-repos/` were inspected before designing each fix:

| Reference Repository | Inspected Path & Revision | License | Reusable Architecture & Algorithmic Analysis | Decision & Rationale |
|---|---|---|---|---|
| **llama.cpp** | `reference-repos/01-apple-silicon-and-inference/llama.cpp` (`b11718`) | MIT | **KV Cache & Scratch Allocations:** Inspected `src/llama-kv-cache.cpp` (`llama_kv_cache_init`), `src/llama-context.cpp`, and `src/llama-model.cpp`. Verified: `n_embd_k_gqa = (n_embd_head_k * n_head_kv)`, `size_k = n_embd_k_gqa * n_ctx * sizeof(type_k)`, `size_v = n_embd_v_gqa * n_ctx * sizeof(type_v)`. Compute buffer allocations use `ggml_backend_sched_reserve()` yielding Metal/CPU scratch spaces typically between 250 MiB and 750 MiB depending on model context length and batch size. | **Adapted Core Logic:** Implemented exact GGUF architecture-based KV cache calculation formula and compute buffer bounds directly in `GGUFMetadataReader.swift` and `HuggingFaceCatalogModels.swift`. |
| **mlx-swift / mlx-swift-examples** | `reference-repos/01-apple-silicon-and-inference/mlx-swift` | MIT | **Unified Memory Management:** Examined Metal device memory queries (`device.recommendedMaxWorkingSetSize`). Confirmed Apple Silicon unified memory reserves ~25-30% of system RAM for the kernel, WindowServer, display buffers, and background daemon services to avoid memory pressure and disk swapping. | **Adapted Reserve Rationale:** Derived tiered macOS system reserve thresholds (3.0 GiB for 8 GB Macs, 4.5 GiB for 16 GB Macs, 5.5 GiB for $\ge 24$ GB Macs). |
| **whisper.cpp** | `reference-repos/01-apple-silicon-and-inference/whisper.cpp` | MIT | **Platform API Constraints:** Verified that macOS does not expose `os_proc_available_memory()`, and runtime monitoring requires Mach kernel calls (`task_info` with `TASK_VM_INFO` for resident footprint, and `host_statistics64` with `HOST_VM_INFO64` for free/inactive page counts). | **Adopted Platform Pattern:** Kept static preflight admission checks strictly separated from transient Mach memory queries; preflight checks rely on verified hardware bounds. |
| **desktop (Jan UI)** | `reference-repos/08-desktop-ui-and-application-frameworks/desktop` | Apache 2.0 | **Download Resumption & State Machine:** Examined download lifecycle state transitions in Electron/Node environment. Inspected handling of stale lockfiles and interrupted downloads on startup. | **Adapted Philosophy:** Replaced destructive auto-resume on boot with safe reconciliation to `.paused` state with clear user notification, preventing background network stampedes. |
| **huggingface_hub** | `reference-repos/02-model-formats-and-model-hubs/huggingface_hub` | Apache 2.0 | **File Atomic Promotion & Cleanup:** Inspected `huggingface_hub/file_download.py` staging lock patterns (`.incomplete` suffixes, temporary atomic renames, and cleanup hooks on checksum/metadata failure). | **Adapted Ownership Pattern:** Implemented explicit destination ownership tracking (`didMoveToFinalDestination`) to guard against unlinking pre-existing files on failure. |

---

## 4. DEF-39-04: Runtime Memory Compatibility Assessment

### 4.1 Audited Root Cause
Previously, `GGUFMetadataReader.checkCompatibility(fileSize:totalRAM:)` evaluated compatibility using:
$$\text{fileSize} \le \text{totalRAM} \times 0.70$$
This heuristic suffered from three fatal flaws:
1. **Neglected KV Cache:** A 7B model at 32k context length can consume over 4.5 GB of RAM solely for its KV cache, which was completely omitted from the calculation.
2. **Neglected Compute Buffers:** Metal compute graphs (`ggml-metal`) allocate intermediate activation buffers during `sched_reserve`, adding 250–750 MiB.
3. **Neglected OS Baseline:** A 7.0 GB model on an 8 GB Mac was marked `.compatible` because $7.0 \le 8.0 \times 0.90$, despite the operating system and WindowServer requiring at least 3.0 GB, guaranteeing an immediate system freeze or OOM SIGKILL.

### 4.2 Mathematical Model & Derivation
The new admission model evaluates total runtime demand:
$$\text{TotalDemand} = M_{\text{weights}} + M_{\text{kv}} + M_{\text{compute}} + M_{\text{app\_reserve}}$$

Where:
1. **Weight Memory ($M_{\text{weights}}$):**
   - For local files: `fileSize` on disk (GGUF tensors are mapped directly or loaded into Metal buffers).
   - For remote catalog files: `remoteFileSize` from Hugging Face sibling metadata.

2. **KV Cache Memory ($M_{\text{kv}}$):**
   Derived from pinned llama.cpp `src/llama-kv-cache.cpp`:
   $$M_{\text{kv}} = 2 \times n_{\text{layers}} \times n_{\text{kv\_heads}} \times d_{\text{head}} \times \text{bytesPerElem} \times n_{\text{ctx}}$$
   - $n_{\text{layers}}$: Architecture block count (`llama.block_count`, `qwen2.block_count`, etc.).
   - $n_{\text{kv\_heads}}$: Grouped-query attention (GQA) key-value head count (`*.attention.head_count_kv`). Defaults to standard attention head count (`*.attention.head_count`) if not specified.
   - $d_{\text{head}}$: Head dimension, calculated as $\frac{n_{\text{embd}}}{n_{\text{head}}}$, or explicit `*.attention.key_length`.
   - $\text{bytesPerElem}$: Precision format multiplier (2.0 bytes for `f16`, 1.0625 bytes for `q8_0`, 0.5625 bytes for `q4_0`, 4.0 bytes for `f32`). Defaults conservatively to `f16` (2.0 bytes).
   - $n_{\text{ctx}}$: Effective context length (evaluated at 4096 default or model's maximum trained context).

   *Fallback:* If detailed attention head metadata is not present in the GGUF header, a conservative estimate based on parameter count and embedding dimensions is applied:
   $$M_{\text{kv\_fallback}} = 2 \times n_{\text{layers}} \times 2048 \times n_{\text{ctx}} \times 2.0$$

3. **Compute Buffer Overhead ($M_{\text{compute}}$):**
   - Bounded between 250 MiB (for $n_{\text{ctx}} \le 2048$) and 750 MiB (for $n_{\text{ctx}} \ge 16384$), matching `llama.cpp` `sched_reserve` Metal scratch graphs.

4. **Tiered System & Application Reserve ($M_{\text{sys}}$):**
   Apple Silicon unified memory requires dedicated DRAM for the Darwin kernel, WindowServer, GPU framebuffers, and user applications:
   - **Total RAM $\le 9$ GB (8 GB Macs):** $M_{\text{sys}} = 3.0\text{ GiB}$ ($3{,}221{,}225{,}472$ bytes).
   - **Total RAM $\le 17$ GB (16 GB Macs):** $M_{\text{sys}} = 4.5\text{ GiB}$ ($4{,}831{,}838{,}208$ bytes).
   - **Total RAM $> 17$ GB (24 GB+ Macs):** $M_{\text{sys}} = 5.5\text{ GiB}$ ($5{,}905{,}580{,}032$ bytes).
   - **Aether Application Reserve ($M_{\text{app\_reserve}}$):** 256 MiB ($268{,}435{,}456$ bytes) for SwiftUI, SQLite, and network buffers.

5. **Admission Rule:**
   $$\text{Headroom} = \text{TotalRAM} - M_{\text{sys}}$$
   $$\text{Status} = \begin{cases} 
   \text{.compatible} & \text{if } \text{TotalDemand} \le \text{Headroom} \\
   \text{.exceedsMemory} & \text{if } \text{TotalDemand} > \text{Headroom} \\
   \text{.unknown} & \text{if metadata is missing or untrusted}
   \end{cases}$$

### 4.3 Overflow Protection & Robustness
- **Saturating Arithmetic:** Calculations use `Double` intermediates with bounds checks before casting to `Int64`, preventing integer overflow wrap-around (`Int64.max &+ 1` wrapping to negative numbers).
- **Physical RAM Clamping:** `totalRAM` clamped safely against `UInt64(Int64.max)` to prevent runtime traps on extreme inputs.
- **Untrusted Metadata Handling:** If `fileSize <= 0`, `tensorCount <= 0`, or context length is invalid, the engine returns `.unknown(reason:)` rather than misclassifying the model.

---

## 5. DEF-39-05: Interrupted Download Recovery

### 5.1 Audited Root Cause
When Aether exits abruptly (user quit, crash, system shutdown), SQLite persisted download records remain marked as `.downloading` or `.pending`. Upon relaunch:
1. `loadPersistedDownloads()` restored records into memory with their stale `.downloading` status.
2. No active `URLSessionDownloadTask` was running in the background.
3. The UI displayed an active downloading spinner, but progress was frozen at 0%.
4. Attempting to click "Download" triggered `startDownload`, which checked `activeDownloads[modelId]` and immediately threw `ModelDownloadError.alreadyDownloading`.
5. The download remained permanently wedged unless the user manually located and deleted the Application Support SQLite database.

### 5.2 Implementation Details
1. **Active Task Reattachment Audit:**
   Inspected Foundation `URLSession` capabilities. Standard (non-background) `URLSession` tasks cannot be reattached across process lifecycles. Therefore, in-flight tasks without matching active session tasks must be reconciled immediately on startup.
2. **Reconciliation on Startup:**
   In `ModelDownloadManager.loadPersistedDownloads()`:
   - Evaluates all records with `.downloading` or `.pending` status.
   - For any record that lacks an active `URLSessionDownloadTask`, transitions its database status to `.paused`.
   - Sets a localized diagnostic message: `"Interrupted by application exit and paused for safe resumption."`
3. **Resume Data Integrity Validation:**
   - URLSession resume data is a serialized property list (`NSKeyedArchiver` or XML/Binary plist).
   - When loading resume data from disk, Aether validates the binary payload via `PropertyListSerialization.propertyList(from:options:format:)`.
   - If valid, the existing `.resumeData` is preserved for byte-range HTTP resumption.
   - If invalid or corrupted (0-byte file, truncated bytes, invalid XML), the corrupt file is unlinked, `downloadedBytes` is reset to 0, and the status allows clean restart from byte 0.
4. **Idempotent Execution:**
   Multiple calls to `loadPersistedDownloads()` or repeated application restarts maintain state consistency without duplicate tasks or database corruption.

---

## 6. DEF-39-06: Orphaned GGUF Cleanup After Registration Failure

### 6.1 Audited Root Cause
In `ModelDownloadManager.handleDownloadFinished(item:tempURL:)`:
1. The temporary download was moved to `stagingURL` (`<modelId>.download`).
2. GGUF header validation passed.
3. The staging file was moved to its final destination (`finalURL = modelsDirectory.appendingPathComponent(item.suggestedFilename)`).
4. `modelLibraryService.registerModel(at:finalURL, ...)` was called to register the model in the SQLite catalog and create security-scoped bookmarks.
5. If `registerModel` threw an error (e.g., database constraint failure, disk I/O error), the catch block executed:
   `try? fileManager.removeItem(at: stagingURL)`
6. Because the file had **already** been renamed to `finalURL`, `stagingURL` no longer existed. The newly moved `.gguf` file at `finalURL` remained stranded on disk.
7. Subsequent attempts to re-download the model failed with: `"A model file already exists at target destination."`

### 6.2 Implementation Details
1. **Ownership Tracking (`didMoveToFinalDestination`):**
   Introduced a strict boolean state flag tracking the atomic movement of the file from staging to `finalURL`.
2. **Defensive Cleanup on Registration Failure:**
   If `registerModel` fails:
   - If `didMoveToFinalDestination` is `true`, the error handler immediately unlinks `finalURL`.
   - If `didMoveToFinalDestination` is `false`, the error handler unlinks `stagingURL`.
3. **Strict User File Protection:**
   Before moving to `finalURL`, `handleDownloadFinished` explicitly verifies `!fileManager.fileExists(atPath: finalURL.path)`. Aether will never overwrite or unlink a pre-existing user file.
4. **Diagnostic Logging:**
   If unlinking fails, a detailed diagnostic error is logged with the exact file path and underlying POSIX error code.

---

## 7. Files Changed and Technical Diffs

### 7.1 `Aether/Sources/ModelLibrary/ModelRecord.swift`
- Added `KVCacheDataType` enum with precision element sizes (`f16`: 2.0 bytes, `q8_0`: 1.0625 bytes, `q4_0`: 0.5625 bytes, `f32`: 4.0 bytes).
- Added `headCount`, `headCountKV`, `embeddingLength`, and `keyLength` to `GGUFMetadata`.
- Added `RuntimeMemoryEstimate` struct capturing weights, KV cache, compute buffers, system reserve, headroom, compatibility flag, and warning reasons.

### 7.2 `Aether/Sources/ModelLibrary/GGUFMetadataReader.swift`
- Implemented `parseArchitectureHyperparameters()` to extract attention head counts, embedding lengths, and block counts from GGUF metadata key-value tables.
- Implemented `estimateRuntimeMemory(metadata:fileSize:contextLength:kvCacheType:hostRAM:)`.
- Implemented tiered system reserve ($3.0\text{ GiB}$ for $\le 9\text{ GB}$, $4.5\text{ GiB}$ for $\le 17\text{ GB}$, $5.5\text{ GiB}$ for $24+\text{ GB}$).
- Added saturating addition preventing integer overflow wrap-around.
- Clamped `totalRAM` to avoid `Int64` conversion traps on `UInt64.max`.

### 7.3 `Aether/Sources/ModelLibrary/HuggingFaceCatalogModels.swift`
- Updated `HuggingFaceQuantUtils.evaluateFileCompatibility` to compute runtime memory demand using `GGUFMetadataReader.estimateRuntimeMemory`.
- Formatted human-readable status explanations detailing weight memory, KV cache, and total required RAM.

### 7.4 `Aether/Sources/ModelLibrary/ModelDownloadManager.swift`
- Updated `loadPersistedDownloads()`: Reconciles non-active `.downloading` and `.pending` records to `.paused` with `"Interrupted by application exit and paused for safe resumption."`
- Validates property-list format of existing resume data; discards corrupt data and resets byte offsets.
- Updated `handleDownloadFinished`: Added `didMoveToFinalDestination` tracking, rollback cleanup of `finalURL` if registration throws, and strict guards preventing overwriting existing files.

### 7.5 `Aether/Tests/ModelLibraryTests.swift`
Added 9 new targeted regression tests for DEF-39-04:
1. `testSmallCompatibleModelWithKnownMetadata`: Validates small 0.5B model at 2048 ctx fits within 8 GB RAM.
2. `testModelExceedsConservativeMemoryBudget`: Validates 8B model with large footprint exceeds 8 GB RAM budget.
3. `testContextLengthIncreasesRaiseKVCacheDemand`: Validates KV cache scaling from 2048 to 32768 tokens.
4. `testDifferentKVHeadCountsAndCacheDataTypes`: Validates GQA head count scaling and `q8_0`/`q4_0` memory reductions.
5. `testMissingArchitectureOrTensorMetadata`: Validates fallback to `.unknown` when block count or tensors are missing.
6. `testOverflowAndInvalidNumericInputs`: Validates saturating arithmetic against `Int64.max` and negative inputs.
7. `testMemoryConfigurations8GBAnd16GB`: Validates budget tier transitions between 8 GB and 16 GB host RAM.
8. `testUnknownOrUnsupportedArchitecture`: Validates `.unsupported` status for non-whitelisted architectures.
9. `testExistingCompatibilityUIBehaviorAndRegressionCases`: Validates backward-compatible `.compatible` and `.exceedsMemory` mappings.

### 7.6 `Aether/Tests/ModelDownloadManagerTests.swift`
Added 9 new targeted regression tests for DEF-39-05 and DEF-39-06:
1. `testInterruptedDownloadingStateReconcilesToPausedOnLaunch`: Verifies orphaned `.downloading` records become `.paused`.
2. `testInterruptedPendingStateReconcilesToPausedOnLaunch`: Verifies orphaned `.pending` records become `.paused`.
3. `testInterruptedDownloadWithValidResumeDataPreserved`: Verifies valid property-list resume data is retained.
4. `testInterruptedDownloadWithCorruptResumeDataHandledSafely`: Verifies corrupt resume data is unlinked and state reset.
5. `testRecoveryIsIdempotentAcrossRepeatedLaunches`: Verifies multiple startup cycles maintain consistent state.
6. `testDuplicateStartPreventedForActiveAndPausedDownloads`: Verifies duplicate task initiation is rejected.
7. `testRegistrationFailureCleansUpPromotedGGUF`: Verifies newly installed `.gguf` is unlinked if registration throws.
8. `testRegistrationFailurePreservesPreExistingUserFile`: Verifies pre-existing user files are never deleted on failure.
9. `testSuccessfulRegistrationPreservesFinalGGUF`: Verifies successful downloads remain intact in catalog.

---

## 8. Verification & Test Execution Results

### 8.1 Focused Defect Test Suites
Executed via `xcodebuild test -only-testing`:
- **`ModelLibraryTests`:** 28 executed, 0 failures, 0 unexpected, duration: **0.086 seconds**.
- **`ModelDownloadManagerTests`:** 21 executed, 0 failures, 0 unexpected, duration: **0.140 seconds**.
- **Total Focused Tests:** **49 executed, 49 passed, 0 failures**.

### 8.2 Full Application Regression Test Suite
Executed full test suite across all 11 test modules:
```
Test Suite 'All tests' passed at 2026-10-19 21:41:26.720.
	 Executed 204 tests, with 0 failures (0 unexpected) in 19.870 (19.926) seconds
```

#### Detailed Breakdown by Test Suite:
| Test Suite | Total Tests | Passed | Failed | Duration |
|---|---|---|---|---|
| `AppSmokeTests` | 3 | 3 | 0 | 0.001 s |
| `ChatViewModelTests` | 27 | 27 | 0 | 0.021 s |
| `ConversationDatabaseTests` | 34 | 34 | 0 | 0.052 s |
| `DownloaderStateTests` | 9 | 9 | 0 | 0.015 s |
| `HuggingFaceCatalogTests` | 13 | 13 | 0 | 0.035 s |
| `InferenceCancellationTests` | 7 | 7 | 0 | 18.910 s |
| `InferenceWorkerTests` | 19 | 19 | 0 | 0.528 s |
| `LlamaInferenceEngineTests` | 16 | 16 | 0 | 0.078 s |
| `ModelDownloadManagerTests` | 21 | 21 | 0 | 0.140 s |
| `ModelLibraryTests` | 28 | 28 | 0 | 0.086 s |
| `StreamingStopFilterTests` | 15 | 15 | 0 | 0.005 s |
| **Total Full Suite** | **204** | **204** | **0** | **19.870 s** |

### 8.3 Compilation & Build Verification
- **Debug Build:** `xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Debug`  
  `** BUILD SUCCEEDED **` [0 compiler warnings, codesign verified]
- **Release Build:** `xcodebuild build -project Aether.xcodeproj -scheme Aether -configuration Release`  
  `** BUILD SUCCEEDED **` [0 compiler warnings, dSYM generated, codesign verified]

---

## 9. Unresolved Risks & Operational Boundaries

1. **Transient Metal Memory Spikes:** During initial model compilation and Metal compute pipeline state object (PSO) creation, macOS may allocate transient temporary buffers that briefly exceed `TotalDemand`. The conservative system reserve ($3.0\text{--}5.5\text{ GiB}$) absorbs these spikes under normal conditions, but running heavily GPU-intensive third-party applications concurrently may still trigger memory pressure.
2. **App Sandbox Container Boundaries:** Because Aether operates under strict macOS App Sandbox constraints (`com.apple.security.app-sandbox = true`), files cannot be hard-linked across different container volumes or user directories. All file operations utilize atomic copy/rename semantics within the sandbox Application Support container.
3. **HTTP Server Byte-Range Support:** If a remote Hugging Face endpoint does not support RFC 7233 HTTP `Range` requests or returns `HTTP 200 OK` instead of `HTTP 206 Partial Content`, `URLSession` will safely discard resume data and restart the download from byte 0.

---

## 10. Manual Acceptance Testing Protocol (Packaged App)

Automated unit tests execute in a headless Xcode test runner. Final acceptance verification should be conducted on the packaged `.app` bundle:

1. **Test Runtime Memory Assessment in UI:**
   - Launch `DerivedData/Aether-.../Build/Products/Debug/Aether.app`.
   - Open Model Library (`Cmd + Shift + M`).
   - Search for a 70B parameter model (e.g., `Llama-3.3-70B-Instruct-GGUF`).
   - Verify the UI badge displays `⚠️ Exceeds Memory (Requires ~42.5 GB, available headroom: 11.5 GB)` on a 16 GB Mac.
   - Search for a 1.5B or 3B model (e.g., `Qwen2.5-3B-Instruct-GGUF`).
   - Verify the UI badge displays `Compatible (Requires ~3.2 GB)`.
2. **Test Interrupted Download Recovery:**
   - Start downloading any catalog model.
   - While the progress bar is active (e.g., at 25%), force terminate the app via `killall -9 Aether` from Terminal.
   - Relaunch `Aether.app`.
   - Open Model Library -> Downloads.
   - Verify the download record shows `Paused: Interrupted by application exit and paused for safe resumption.`
   - Click `Resume`. Verify download resumes without throwing `alreadyDownloading`.
3. **Test Registration Rollback:**
   - Verify that corrupted GGUF downloads or aborted registrations do not leave dangling `.gguf` files in `~/Library/Containers/com.aether.Aether/Data/Library/Application Support/Aether/Models/`.
