# AETHER — PHASE 3.6.4 ACCEPTANCE REPORT
## Packaged-App GUI & Cold-Relaunch Acceptance
### Gate D: End-to-End Verification

**Workspace:** `/Users/asadalishaikh/Aether Agent`  
**Platform:** macOS 14.0+, Apple Silicon (Target: arm64)  
**Host Hardware:** MacBook Air M5, 16 GB unified memory (`hw.memsize: 17179869184`)  
**Host OS:** Darwin 24.x / macOS 15.x (`arm64`)  
**Language:** Swift 6, strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`)  
**Inference Backend:** Pinned `llama.cpp` revision `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`)  
**Prior Remediation Deliverable:** `research/32-phase-3.6.3-security-scoped-access-remediation.md`  
**New Deliverable:** `research/33-phase-3.6.4-gui-cold-relaunch-acceptance.md`  
**Date:** October 19, 2026  

---

## 1. Executive Summary & Overall Verdict

### Overall Verdict
**`ACCEPT WITH DOCUMENTED LIMITATIONS`**

### Summary
Phase 3.6.4 conducted end-to-end acceptance testing of the packaged application bundles (`Debug` and `Release`), the App Sandbox environment, security-scoped bookmark persistence, and model lifecycle management as remediated in Phase 3.6.3.

- **Automated Verification:** 100% PASS. All 88 automated tests passed (`** TEST SUCCEEDED **`) with 0 failures, including all 19 model catalog and lifecycle tests.
- **Codesigning & Entitlements:** Both `Debug` and `Release` application bundles were verified via `codesign --verify --deep --strict --verbose=4` and `codesign -dvvv --entitlements -`. Both bundles satisfy their designated requirements, embed the authorized read-only user-selected file entitlement and app-scope bookmark entitlement, maintain `ENABLE_HARDENED_RUNTIME = NO` for ad-hoc Release signing, and link `llama.framework` without signature mismatches.
- **Headless Execution Limitation:** Because autonomous agent execution operates in a non-interactive shell without access to an interactive macOS WindowServer session, visual/manual UI interactions involving the native AppKit `NSOpenPanel` modal dialog cannot be directly observed by the agent. In accordance with strict instructions, Tests A–G are classified with programmatic/headless verification status while interactive visual steps are marked `NOT VERIFIED (GUI)`. A comprehensive, step-by-step manual acceptance checklist is provided for user verification on their Mac.
- **Preservation Status:** The user's live database (`aether.sqlite`), conversations, existing external model files at `~/.hermes/models/` and `~/.ollama/models/`, the pinned `llama.cpp` commit, and all pre-change backups remain 100% intact.

---

## 2. Test Environment & Application Bundles

### 1. Application Bundles Evaluated
- **Release Bundle Path:**  
  `/Users/asadalishaikh/Library/Developer/Xcode/DerivedData/Aether-cjpfhhxjwtzfczgtskgobxcnuets/Build/Products/Release/Aether.app` [VERIFIED FACT]
- **Release Executable Path:**  
  `.../Release/Aether.app/Contents/MacOS/Aether` (1,929,840 bytes, Mach-O 64-bit executable arm64) [VERIFIED FACT]
- **Debug Bundle Path:**  
  `/Users/asadalishaikh/Library/Developer/Xcode/DerivedData/Aether-cjpfhhxjwtzfczgtskgobxcnuets/Build/Products/Debug/Aether.app` [VERIFIED FACT]
- **Bundle Identifier:** `com.aether.Aether` [VERIFIED FACT]
- **Deployment Target:** macOS 14.0+ (`LSMinimumSystemVersion = 14.0`) [VERIFIED FACT]

### 2. Code Signing & Embedded Entitlements Inspection
Validated via `codesign -d --entitlements -`:
```xml
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
```
- App Sandbox is strictly active (`com.apple.security.app-sandbox = true`) [VERIFIED FACT].
- Both authorized file entitlements are present [VERIFIED FACT].
- No broad filesystem entitlements (`com.apple.security.files.all-files` absent) [VERIFIED FACT].
- No network client/server entitlements present [VERIFIED FACT].
- Embedded framework `llama.framework` signed ad-hoc, bundle verified on disk [VERIFIED FACT].

### 3. Local Model Test Candidates (Outside App Sandbox)
Two valid, uncorrupted GGUF models were identified on the host filesystem:
1. **Model Candidate 1 (Primary Candidate):**  
   - Path: `/Users/asadalishaikh/.hermes/models/Qwen3.5-9B-Q4_K_M.gguf`  
   - File Size: `5,715,690,464` bytes (5.3 GB) [MEASURED]  
   - Format: GGUF v3, 427 tensors, 46 metadata KV pairs [VERIFIED FACT]  
   - Outside Sandbox: Resides in user home folder (`~/.hermes/models/`), strictly external to container.
2. **Model Candidate 2 (Secondary Switch Candidate):**  
   - Path: `/Users/asadalishaikh/.ollama/models/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463`  
   - File Size: `4,683,107,328` bytes (4.4 GB) [MEASURED]  
   - Format: GGUF v3, 339 tensors, 34 metadata KV pairs [VERIFIED FACT]  

### 4. Real Database Baseline
- Container Database Path: `~/Library/Containers/com.aether.Aether/Data/Library/Application Support/Aether/aether.sqlite`
- Integrity: `PRAGMA integrity_check` returned `ok` [VERIFIED FACT].
- Initial Record Count: 1 conversation, 0 messages, 0 cataloged models [MEASURED].

---

## 3. Results for Acceptance Tests A–G

| Test ID | Description | Preconditions | Action Performed | Expected Behavior | Observed Behavior | Status |
|---|---|---|---|---|---|---|
| **Test A** | Application launch & initial state | Built Release/Debug bundles | Inspect running process (PID 48699) & unified system logs | Window renders, responds to events; no sandbox or dyld crashes | Unified log confirmed AppKit event dispatching (`trackMouse`, `sendAction`, `NSPersistentUIManager`) without dyld/sandbox errors | `PASS (Headless) / NOT VERIFIED (GUI)` |
| **Test B** | Select & catalog external model | External GGUF model exists at `~/.hermes/models/...` | Invoke `NSOpenPanel`, select GGUF file | GGUF header parsed, metadata extracted, security bookmark persisted to SQLite | Programmatic GGUF metadata parsing & catalog persistence passed in test suite (`testModelCatalogCRUD`); interactive modal requires human clicks | `PASS (Unit) / NOT VERIFIED (GUI)` |
| **Test C** | Load and generate | Cataloged model available | User loads model and prompts assistant | Model memory-mapped (`mmap`) under active security scope; streaming output produced | Engine streaming, token accumulation, and batch persistence verified via `InferenceLifecycleTests` (18 tests passed) | `PASS (Unit) / NOT VERIFIED (GUI)` |
| **Test D** | Switch or unload | Active loaded model | User switches to Model 2 or unloads | Active generation cancelled, termination barrier awaited, native model freed, scope released, replacement loaded | Ordering verified via `testSwitchModelPreLoadActionTeardownOrdering` and `testChatViewModelSelectAndLoadModelMaintainsScopeLifecycle` | `PASS (Unit) / NOT VERIFIED (GUI)` |
| **Test E** | Cold relaunch & bookmark restoration | Model cataloged with bookmark; app quit and relaunched | Quit process, relaunch app, select cataloged model without file dialog | Stored bookmark resolves `.withSecurityScope`, `startAccessingSecurityScopedResource()` returns true, model loads without prompt | Bookmark resolution & scope activation verified in `testSecurityScopedAccessLifecycleBalance`; GUI relaunch workflow requires user manual test | `PASS (Unit) / NOT VERIFIED (GUI)` |
| **Test F** | Non-destructive catalog removal | Model cataloged in database | Remove entry from library UI | Metadata removed from SQLite; physical model file on disk untouched | Verified in `testModelCatalogCRUD` (`deleteModel` removed database record while `fileExists(atPath: fakePath)` remained true) | `PASS (Unit) / NOT VERIFIED (GUI)` |
| **Test G** | Stability & resource cleanup | Multiple load/unload cycles | Execute rapid switch cycles and application shutdown | Zero leaked scopes, zero double-frees, active access count returns to 0 | Verified in `testReleaseAllModelAccessOnShutdown` and `testSecurityScopedAccessLifecycleBalance` (`activeAccessCount() == 0`) | `PASS (Unit) / NOT VERIFIED (GUI)` |

---

## 4. Direct Observations vs. Headless / Inferred Evidence

### Direct Observations Made by Agent
1. `[VERIFIED FACT]` The Release binary at `Build/Products/Release/Aether.app` is ad-hoc signed, codesign validation passes with deep verification, and embeds `com.apple.security.files.user-selected.read-only` and `com.apple.security.files.bookmarks.app-scope`.
2. `[VERIFIED FACT]` The full automated test suite executed via `xcodebuild test` and passed all 88 test cases without failure.
3. `[VERIFIED FACT]` In the live unified system log, the running Aether instance (PID 48699) logged AppKit windowing, event handling, and state restoration events without crashing or encountering dyld validation errors.
4. `[MEASURED]` Two external models exist outside the sandbox: `~/.hermes/models/Qwen3.5-9B-Q4_K_M.gguf` (5.3 GB) and `~/.ollama/models/blobs/...` (4.4 GB). Both headers were parsed directly and verified as valid GGUF v3 binaries.
5. `[VERIFIED FACT]` The user's live database at `~/Library/Containers/com.aether.Aether/Data/Library/Application Support/Aether/aether.sqlite` passes `PRAGMA integrity_check` with `ok`.

### Headless Limitations
1. `[NOT VERIFIED (GUI)]` The visual appearance of the `NavigationSplitView`, the sidebar model selector, the toolbar "Model Library" sheet, and the native `NSOpenPanel` file selection modal could not be visually confirmed by the agent because the subagent shell has no interactive display server or virtual framebuffer.
2. `[NOT VERIFIED (GUI)]` An actual mouse click on an external file inside `NSOpenPanel` inside the packaged sandboxed app could not be performed by the agent without human interaction.

---

## 5. Cold-Relaunch Bookmark-Restoration Result

### Technical Verification
In Phase 3.6.3, two critical changes were implemented to guarantee cold-relaunch bookmark restoration:
1. **Entitlement Addition:** Adding `com.apple.security.files.bookmarks.app-scope` enables macOS kernel and `launchd` security policies to permit the sandboxed application to resolve security-scoped bookmarks created in prior process lifetimes.
2. **Pre-Stat Resolution in `prepareModelForLoading` & `fetchCatalog`:** Prior to Phase 3.6.3, `ModelLibraryService` called `FileManager.default.fileExists(atPath: model.filePath)` before resolving the bookmark, which failed in a cold session because external paths are inaccessible prior to security scope activation. The remediated implementation resolves the bookmark with `.withSecurityScope` and calls `startAccessingSecurityScopedResource()` **before** any file stat operations.

### Unit Test Proof
- `testSecurityScopedAccessLifecycleBalance` verified that:
  - Resolving stored bookmark data acquires security-scoped access.
  - Active access is tracked (`activeAccessCount() == 1`).
  - Subsequent preparation does not duplicate tokens.
  - Calling `releaseModelAccess` revokes access (`activeAccessCount() == 0`).
  - Double release is safe and idempotent.

---

## 6. Model-Switching & Teardown Observations

1. **Generation Termination Barrier:** Verified in `InferenceLifecycleTests` that requesting an unload or model switch while generating sets the atomic cancellation flag, awaits the worker task completion, and blocks until Metal compute buffers have finished.
2. **Strict Teardown Ordering (`preLoadAction`):** Verified via `testSwitchModelPreLoadActionTeardownOrdering` that native worker unload completes (`worker.unloadCallCount >= 1`) **before** `preLoadAction` releases the prior model's security-scoped access token.
3. **No Dangling Scope on Load Failure:** Verified via `testChatViewModelFailedLoadCleansUpSecurityScope` that if the replacement model fails to load, its acquired scope is immediately released and `loadedModelId` is reset to `nil`, leaving zero leaked access tokens (`activeAccessCount() == 0`).

---

## 7. Non-Destructive Deletion Verification

1. **Database-Only Removal:** `ModelLibraryService.removeModelFromCatalog(id:)` executes:
   - `releaseModelAccess(id: id)` to stop security-scoped access.
   - `database.deleteModel(id: id)` to remove the row from SQLite.
2. **Filesystem Preservation:**
   - In `testModelCatalogCRUD`, removing the catalog entry was verified to leave the underlying file at `fakePath` completely intact on disk.
   - The method contains zero filesystem deletion APIs (`FileManager.default.removeItem` is never invoked).

---

## 8. Manual Acceptance Checklist for User Execution

Because visual GUI acceptance requires human interaction with macOS `NSOpenPanel`, the user can execute this 10-minute verification sequence on their Mac:

```markdown
### Step 1: Launch the Packaged Release Application
Command:
open "/Users/asadalishaikh/Library/Developer/Xcode/DerivedData/Aether-cjpfhhxjwtzfczgtskgobxcnuets/Build/Products/Release/Aether.app"

Verification:
- Confirm the window titled "Aether" appears with the native macOS 14+ navigation split view.
- Confirm no crash dialog or system warning appears.

### Step 2: Open Model Library & Select External Model
Action:
1. In the toolbar, click the "Model Library" icon/button.
2. Click "Add Model..." to open the native macOS NSOpenPanel file picker.
3. Navigate to and select:
   /Users/asadalishaikh/.hermes/models/Qwen3.5-9B-Q4_K_M.gguf
   (or press Cmd+Shift+G in the dialog and paste the path).
4. Click "Open".

Verification:
- The model library sheet processes the GGUF header without error.
- "Qwen3.5-9B-Q4_K_M" appears in the library catalog with size (5.3 GB) and architecture.

### Step 3: Load Model & Perform Short Inference
Action:
1. In the sidebar or model selector dropdown, select "Qwen3.5-9B-Q4_K_M".
2. Wait for the status indicator to change from "Loading..." to "Ready".
3. In the chat composer, type: "Hello! Tell me in one sentence what you are." and press Return.

Verification:
- Tokens stream into the assistant message bubble in real time.
- Status displays "Completed".

### Step 4: Test Cold Relaunch & Security-Scoped Bookmark Restoration
Action:
1. Press Cmd+Q to quit Aether completely.
2. Confirm the process has terminated (`ps aux | grep [A]ether` returns no running app).
3. Relaunch the application:
   open "/Users/asadalishaikh/Library/Developer/Xcode/DerivedData/Aether-cjpfhhxjwtzfczgtskgobxcnuets/Build/Products/Release/Aether.app"
4. Open the chat window.

Verification:
- "Qwen3.5-9B-Q4_K_M" is still listed in the model catalog without showing "Missing".
- The model can be loaded immediately without re-opening NSOpenPanel.
- Send a second prompt: "What is 2 + 2?" and confirm inference streams correctly.

### Step 5: Test Non-Destructive Catalog Removal
Action:
1. Open Model Library.
2. Click "Remove" next to the cataloged model.
3. Confirm the model disappears from the Aether catalog.
4. In Terminal, run:
   ls -la "/Users/asadalishaikh/.hermes/models/Qwen3.5-9B-Q4_K_M.gguf"
5. Confirm the file still exists on disk with unchanged size (5,715,690,464 bytes).
```

---

## 9. Preservation & Rollback Verification

Prior to concluding Phase 3.6.4, all project files and dependencies were audited:

| Item | Status | Verification Detail |
|---|---|---|
| `Aether.entitlements` | **Preserved** | SHA-256: `6bb71769c345f157...` matches approved Phase 3.6.3 state. |
| `ModelLibraryService.swift` | **Preserved** | SHA-256: `f9ce228a726533e3...` matches approved Phase 3.6.3 state. |
| `InferenceService.swift` | **Preserved** | SHA-256: `d34607c2c189a028...` matches approved Phase 3.6.3 state. |
| `ChatViewModel.swift` | **Preserved** | SHA-256: `d1d915ab5b7cb7a8...` matches approved Phase 3.6.3 state. |
| `ModelLibraryTests.swift` | **Preserved** | SHA-256: `46b4cb869c9222bd...` matches approved Phase 3.6.3 state. |
| Pinned `llama.cpp` | **Preserved** | Commit `547208dca250ceb3e4c8615598d043f2b602a527` (`b11718`). |
| Release Signing Settings | **Preserved** | `ENABLE_HARDENED_RUNTIME = NO` for ad-hoc Release builds. |
| User SQLite Database | **Preserved** | `aether.sqlite` verified intact with `PRAGMA integrity_check = ok`. |
| Model Weight Files | **Preserved** | Real model files at `~/.hermes/models/` and `~/.ollama/models/` untouched. |
| Pre-change Backups | **Preserved** | Available in `scratch/backups_phase363/`. |

---

## 10. Final Recommendation

**Recommendation: `ACCEPT WITH DOCUMENTED LIMITATIONS`**

### Justification
1. The programmatic foundation, App Sandbox entitlement configuration, security-scoped bookmark persistence, and native resource teardown sequence are complete, robust, and verified with 88 passing tests.
2. The packaged Release application builds cleanly, is validly ad-hoc signed, and contains no missing framework or linker errors.
3. Because the execution environment is a headless subagent, GUI interactions with `NSOpenPanel` are honestly documented as `NOT VERIFIED (GUI)`, and the user is provided with a concrete manual checklist to confirm live desktop behavior.
4. No further code edits, feature development, or Phase 3.7 work should proceed until the user reviews this report and confirms acceptance.
