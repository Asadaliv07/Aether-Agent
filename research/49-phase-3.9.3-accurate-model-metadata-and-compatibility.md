# AETHER — PHASE 3.9.3 IMPLEMENTATION REPORT
## Accurate Model File Sizes & Compatibility Metadata (DEF-39-02 Remediation)

**Project:** Aether  
**Workspace:** `/Users/asadalishaikh/Aether Agent`  
**Execution Context:** Gate C Authorized Implementation for Phase 3.9.3  
**Date:** October 19, 2026  
**Status:** COMPLETE — All Authorized Changes Implemented, 186 of 186 Tests Passing, Debug & Release Builds Succeeded.  
**Deliverable File:** `research/49-phase-3.9.3-accurate-model-metadata-and-compatibility.md`  

---

## 1. Executive Summary & Objective

In Phase 3.9.1 acceptance audit (`research/47-phase-3.9.1-model-download-acceptance-audit.md`), defect **DEF-39-02** was identified:
- Hugging Face's model summary API (`/api/models?filter=gguf&full=true`) returns repository sibling file records with null or missing file-size metadata.
- Consequently, Aether previously rendered "Unknown size" for discovered GGUF files and evaluated compatibility using `fileSize = 0`.
- Because `fileSize = 0` was below memory thresholds, models were prematurely or misleadingly marked `.compatible` even when their true weight size exceeded unified memory or when their architecture was unrecognized.

**Phase 3.9.3 Objective:**
Implement accurate remote GGUF file metadata retrieval via the official Hugging Face Hub repository tree endpoint, introduce a bounded in-memory cache with request coalescing, implement a four-tier compatibility model (`.compatible`, `.memoryWarning`, `.unsupportedArchitecture`, `.unknown`), and update the native SwiftUI Model Library interface without UI freezing or request storms.

---

## 2. Root Cause & Technical Findings

1. **Hugging Face Hub API Discrepancy:**
   - The catalog search endpoint `GET https://huggingface.co/api/models?filter=gguf&full=true` returns model cards and sibling filenames (`rfilename`), but intentionally leaves `size` and `lfs` null in catalog summary queries to minimize database overhead on Hugging Face servers.
   - The dedicated file-tree endpoint `GET https://huggingface.co/api/models/{repo_id}/tree/{revision}?recursive=true` returns an array of file entries with exact byte sizes (`size` and `lfs.size`).

2. **RFC 5988 Cursor Pagination:**
   - For repositories with many files, Hugging Face Hub paginates tree results using standard RFC 5988 `Link` response headers containing `rel="next"`, e.g.:
     `Link: <https://huggingface.co/api/models/{repo_id}/tree/main?cursor=...&recursive=true>; rel="next"`
   - Aether's implementation follows `rel="next"` links across multiple pages (bounded at 20 pages max) to aggregate file sizes.

3. **Memory Footprint & Selective Filtering:**
   - Large repositories can contain hundreds of non-GGUF files (e.g. `tokenizer.json`, PyTorch checkpoints, documentation).
   - Storing all files in memory would waste cache space. Aether filters tree entries specifically for `.gguf` files (case-insensitive) during ingestion, keeping memory usage minimal.

---

## 3. Reference Repository Investigation

In accordance with Aether's repository-first policy, reference repositories in `reference-repos/` were investigated prior to implementation:

| Reference Repository | Inspected Path & Revision | License | Architectural Relevance & Reuse |
|---|---|---|---|
| **Jan / desktop** | `reference-repos/desktop/src/main/utils/huggingface.ts` | Apache 2.0 | Inspected remote Hugging Face API interactions. Jan uses `/api/models/{id}/tree/main` to discover files and sizes when siblings omit size metadata, and matches files using basename and path components. |
| **mlx-swift-examples** | `reference-repos/mlx-swift-examples/Libraries/Hub/HubApi.swift` | MIT | Inspected Swift actor implementations querying Hugging Face Hub REST endpoints. Re-used actor isolation and concurrency patterns. |
| **huggingface_hub (Python)** | `src/huggingface_hub/hf_api.py` | Apache 2.0 | Verified official specification of the repository tree endpoint `/api/models/{repo_id}/tree/{revision}`, cursor-based pagination, and `Link` header format. |

---

## 4. Exact API Endpoints & Pagination Strategy

### Primary Endpoints
1. **Search Endpoint:**  
   `GET https://huggingface.co/api/models?filter=gguf&sort={sort}&direction=-1&limit={limit}&full=true&search={query}`  
   Returns initial list of model repositories and sibling filenames.
2. **Repository Tree Endpoint:**  
   `GET https://huggingface.co/api/models/{repo_id}/tree/{revision}?recursive=true`  
   Returns JSON array of `HuggingFaceTreeEntry` objects:
   ```json
   [
     {
       "type": "file",
       "path": "TinyLlama-1.1B-Chat-v1.0.Q4_K_M.gguf",
       "size": 668984928,
       "lfs": {
         "size": 668984928,
         "sha256": "4b971a815a51963071daeef9e4eb090547781b2ffccb9a6d393661beae0eeb9e",
         "pointerSize": 134
       }
     }
   ]
   ```

### Pagination Implementation (`HuggingFaceCatalogService.parseNextLink`)
- Inspects HTTP response `Link` header.
- Splits comma-separated links and semicolon-separated parameters.
- Matches `rel="next"` or `rel=next`.
- Extracts URL enclosed in `<...>` and continues traversal until no `rel="next"` link is returned or the 20-page safety cap is reached.

---

## 5. Cache Design, Expiration Policy & Concurrency

### In-Memory Cache
- **Key:** `"{repoId}@{revision}"`
- **Value:** `CachedRepoMetadata(fileSizes: [String: Int64], timestamp: Date)`
- **TTL (Time to Live):** 3600 seconds (1 hour). Requests within TTL return immediately without network access.
- **Capacity:** Maximum 200 repositories.
- **Pruning Strategy:** When capacity is reached, expired entries are purged first. If still at capacity, the oldest 20% of entries by insertion timestamp are evicted (LRU approximation).
- **Explicit Refresh:** Passing `forceRefresh: true` bypasses the cache and pulls fresh tree data from Hugging Face Hub.
- **Failure Non-Persistence:** Failed network requests or decoding errors are **never** cached, ensuring transient outages do not permanently poison metadata.

### Request Coalescing (In-Flight Deduplication)
- Managed by `inFlightTasks: [String: Task<[String: Int64], Error>]` inside `HuggingFaceCatalogService`.
- If multiple components or search queries request sizes for the same repository concurrently, subsequent requests await the single in-flight `Task.value`.

---

## 6. Compatibility Assessment Logic

`HuggingFaceQuantUtils.evaluateFileCompatibility(architecture:fileSize:)` was rewritten with truthful, four-state classification:

1. **Unknown Architecture:**
   - If architecture is nil or empty, returns:
     `.unknown("Architecture is unverified or not declared")`
2. **Unsupported Architecture:**
   - If architecture is declared but absent from `GGUFMetadataReader.supportedArchitectures`, returns:
     `.unsupportedArchitecture(arch)`
3. **Unknown File Size:**
   - If `fileSize <= 0`, returns:
     `.unknown("File size unknown; memory requirements cannot be evaluated")`
4. **Hardware Memory Tier Checks (Host RAM):**
   - Evaluates host memory via `ProcessInfo.processInfo.physicalMemory`:
     - **8 GB Unified Memory Tier (RAM <= 9 GB):** If `fileSize > 4.0 GB`, returns `.memoryWarning("Model file size (...) may exceed available unified memory on 8 GB systems.")`.
     - **16 GB Unified Memory Tier (RAM <= 17 GB):** If `fileSize > 10.0 GB`, returns `.memoryWarning("Model file size (...) may leave very limited headroom on 16 GB systems.")`.
     - **Sufficient Headroom:** Returns `.compatible`.

### Status Transition Lifecycle
- When a model is first discovered without sibling sizes, files start in the `.unknown` state.
- Upon asynchronous resolution of the repository tree, files are updated via `file.withUpdatedSize(accurateSize, architecture:)`, transitioning to `.compatible` or `.memoryWarning`.
- In the UI, `.unknown` displays as a neutral gray badge with a hover tooltip explaining the pending or missing status, avoiding misleading "Ready" badges.

---

## 7. Files Changed and Reasons

| File Path | Description of Changes |
|---|---|
| `Aether/Sources/ModelLibrary/ModelRecord.swift` | Added `case unknown(String)` to `ModelCompatibility` with `isUsable: false` and descriptive `displayMessage`. |
| `Aether/Sources/ModelLibrary/HuggingFaceCatalogModels.swift` | Defined `HuggingFaceTreeEntry` and `HuggingFaceTreeLFS`. Added `withUpdatedSize` on `HuggingFaceGGUFFile` and `withUpdatedGGUFFiles` on `HuggingFaceModel`. Updated `evaluateFileCompatibility` to return `.unknown` when size is 0 or architecture is undeclared. |
| `Aether/Sources/ModelLibrary/HuggingFaceCatalogService.swift` | Added `fetchRepoFileSizes` and `enrichModelWithAccurateFileSizes` to protocol and actor. Implemented tree fetching, RFC 5988 `Link` pagination, 1-hour bounded cache with LRU eviction, request coalescing, and non-GGUF filtering. Added `#if DEBUG` helpers (`clearCache`, `cachedEntryCount`). |
| `Aether/Sources/UI/Chat/ChatViewModel.swift` | Added `repoMetadataLoading: Set<String>` and `repoMetadataErrors: [String: String]`. Implemented `fetchAccurateSizes(for:forceRefresh:)`. Dispatched non-blocking background enrichment upon search completion. |
| `Aether/Sources/UI/ModelLibrary/HuggingFaceModelCardView.swift` | Added `isMetadataLoading`, `metadataError`, and `onRefreshMetadata` properties. Added loading spinners, size retry buttons, and `.unknown` / `.corruptHeader` badge rendering with tooltips. |
| `Aether/Sources/UI/ModelLibrary/ModelLibraryView.swift` | Connected view model metadata loading states and refresh actions into `HuggingFaceModelCardView`. |
| `Aether/Sources/UI/Chat/ConversationSidebarView.swift` | Repaired accidental 'w' typo on line 1 (`wimport SwiftUI` -> `import SwiftUI`). |
| `Aether/Tests/HuggingFaceCatalogTests.swift` | Expanded unit test suite with 10 new test cases covering tree entry decoding, pagination, non-GGUF filtering, caching, coalescing, HTTP 429 / 401 handling, and compatibility transitions. |
| `Aether/Tests/ChatViewModelTests.swift` | Added `MockCatalogService` and tests for `ChatViewModel.fetchAccurateSizes` success and error states. |

---

## 8. Security & Concurrency Analysis

1. **Swift 6 Strict Concurrency:**
   - All models (`HuggingFaceTreeEntry`, `HuggingFaceTreeLFS`, `CachedRepoMetadata`) conform to `Sendable`.
   - `HuggingFaceCatalogService` is an `actor`, serializing internal cache mutations and in-flight deduplication.
   - Tests use thread-safe `AtomicCounter` locking boxes for sendable URLProtocol handlers.
2. **App Sandbox Compliance:**
   - All network traffic flows over HTTPS through `URLSession` conforming to `com.apple.security.network.client`.
   - No temporary files or cache data escape the App Sandbox container.
3. **Privacy & Authentication:**
   - Public model browsing requires no user authentication or token.
   - Zero private user content, prompts, or identifiers are transmitted to Hugging Face Hub.

---

## 9. Test Execution & Verification

### Focused Catalog Test Suite (`HuggingFaceCatalogTests`)
```
Test Suite 'HuggingFaceCatalogTests' passed at 2026-10-19 20:53:57.131.
	 Executed 17 tests, with 0 failures (0 unexpected) in 0.035 (0.038) seconds
```
- `testCatalogServiceHandles403GatedRepository` — PASSED
- `testCatalogServiceHandles429RateLimit` — PASSED
- `testCatalogServiceSearchModels` — PASSED
- `testCorruptTreePayloadThrowsDecodingErrorWithoutCaching` — PASSED
- `testGGUFFileWithUpdatedSizeReEvaluatesCompatibility` — PASSED
- `testMemoryCompatibilityClassification` — PASSED
- `testModelDecodingFromValidJSON` — PASSED
- `testModelEnrichmentReEvaluatesCompatibilityFromUnknown` — PASSED
- `testParseNextLinkFromRFC5988Header` — PASSED
- `testQuantTokenExtraction` — PASSED
- `testTreeConcurrentRequestsDeduplication` — PASSED
- `testTreeEndpoint401Or403GatedRepository` — PASSED
- `testTreeEndpoint429RateLimit` — PASSED
- `testTreeEntryDecodingAndResolvedSize` — PASSED
- `testTreeFilteringNonGGUFFiles` — PASSED
- `testTreeMetadataCachingAndExplicitRefresh` — PASSED
- `testTreePaginationFollowsLinkHeader` — PASSED

### Focused ViewModel Test Suite (`ChatViewModelTests`)
```
Test Suite 'ChatViewModelTests' passed at 2026-10-19 20:54:10.260.
	 Executed 25 tests, with 0 failures (0 unexpected) in 4.653 (4.666) seconds
```
- Includes `testChatViewModelFetchAccurateSizesSuccess` and `testChatViewModelFetchAccurateSizesHandlesError`.

### Full Project Regression Suite (`xcodebuild test -scheme Aether`)
```
Test Suite 'All tests' passed at 2026-10-19 20:54:38.912.
	 Executed 186 tests, with 0 failures (0 unexpected) in 20.569 (20.623) seconds
** TEST SUCCEEDED **
```

### Build Verification
- **Debug Configuration:** `xcodebuild build -scheme Aether -configuration Debug` — **SUCCEEDED**
- **Release Configuration:** `xcodebuild build -scheme Aether -configuration Release` — **SUCCEEDED**

---

## 10. Remaining Risks & Manual GUI Acceptance Steps

### Remaining Risks
1. **Unusual Repository Structures:** If a model creator hosts GGUF files in deeply nested subdirectories beyond 20 pages of tree entries, tree pagination terminates at the 20-page safety cap. Basename fallback lookup ensures matching wherever possible.
2. **Offline Remote Browsing:** If the user opens the Hugging Face tab while offline, remote models cannot be browsed, but installed local models remain completely unaffected and functional.

### Manual GUI Acceptance Steps
1. Launch `Aether.app` (Debug or Release build).
2. Open the **Model Library** sheet by clicking the Model indicator in the sidebar or menu item.
3. Switch to the **Discover Hugging Face** tab.
4. Type `TinyLlama` or `Qwen` in the search field and submit.
5. Verify that:
   - Search results load immediately without UI freezing.
   - For models with pending sizes, a subtle "Loading sizes…" indicator appears.
   - Once retrieved, real formatted file sizes (e.g. `668.9 MB`, `4.68 GB`) replace "Unknown size".
   - The compatibility pill reflects the true size against host RAM:
     - Models <= 4 GB display green `Ready` pill on 8 GB systems.
     - Large models display yellow `RAM Warning` with an informative tooltip.
     - Unsupported architectures display red `Unsupported` pill with architecture name.
   - Clicking "Fetch sizes" or "Retry" refreshes file sizes as expected.
   - Clicking "Download" begins downloading the model file with accurate progress tracking.
