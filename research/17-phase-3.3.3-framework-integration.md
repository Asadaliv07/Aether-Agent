# Phase 3.3.3: Framework Integration into the macOS App

## 1. Executive Summary

Phase 3.3.3 successfully integrated the isolated and validated `llama.xcframework` into the Aether macOS application. The integration strictly followed the minimal change principle: no source code in `Aether/Sources/` was modified, no inference shims or model loading logic were introduced, no upstream files in `reference-repos/` were touched, and the project configuration was modified solely to reference, link, embed, and code-sign the XCFramework.

A complete `Debug` build of the application succeeded with zero new warnings. The built application bundle (`Aether.app`) correctly embeds `llama.framework` in `Contents/Frameworks/`, signed with the local ad-hoc identity and stripped of unnecessary build-time headers. At runtime, macOS dynamic link editor (`dyld`) successfully resolves the `@rpath` dependency from `@executable_path/../Frameworks`, and runtime process inspection (`vmmap`) confirms that `llama.framework` Mach-O segments—including the embedded Metal kernel library—are loaded into the active address space of the running `Aether` process.

---

## 2. Pre-Integration Verification and Checksum Comparison

Before applying any modifications, the pre-built artifact and upstream repository were audited against the criteria established in Phase 3.3.2.

### 2.1 Artifact Checksum Verification

| Checkpoint | Target Path | SHA-256 Checksum | Match Status |
| :--- | :--- | :--- | :--- |
| **Phase 3.3.2 Report** | `research/16-phase-3.3.2-framework-build-validation.md` | `4f9141be26de3b9aed9c73395289290f5bb4e697850ce2483450fb761efc7584` | Expected Baseline |
| **Pre-Integration** | `/tmp/aether-llama-build/out/llama.xcframework/.../llama` | `4f9141be26de3b9aed9c73395289290f5bb4e697850ce2483450fb761efc7584` | **Exact Match (100%)** |
| **Post-Copy** | `Aether/Frameworks/llama.xcframework/.../llama` | `4f9141be26de3b9aed9c73395289290f5bb4e697850ce2483450fb761efc7584` | **Exact Match (100%)** |
| **Post-Build (Embedded)** | `Aether.app/Contents/Frameworks/llama.framework/Versions/A/llama` | `88f85941915eec393a977ae89a5ae8d017224092b80a8043b5edbec2b4e9a96a` | Modified only by Xcode ad-hoc code signature (`LC_CODE_SIGNATURE`) |

### 2.2 Framework Inspection Details

- **Packaging:** `wrapper.xcframework` with valid `Info.plist` (Format 1.0, identifier `macos-arm64`).
- **Binary Format:** Dynamic Mach-O 64-bit (`MH_DYLIB`), architecture `arm64`.
- **Install Name:** `@rpath/llama.framework/Versions/Current/llama`.
- **Deployment Baseline:** Platform macOS (1), Minimum OS `14.0`, SDK `27.0`.
- **dSYM Availability:** Included in `macos-arm64/dSYMs/llama.dSYM`, UUID `7E58AED8-9059-34BB-962E-5DB7E723CEA0` (matches binary UUID identically).
- **Public Headers:** `ggml-alloc.h`, `ggml-backend.h`, `ggml-blas.h`, `ggml-cpu.h`, `ggml-metal.h`, `ggml-opt.h`, `ggml.h`, `gguf.h`, `llama.h`.
- **Module Map:** Valid Clang module map (`module.modulemap`) exporting umbrella headers and linking `Accelerate`, `Metal`, `Foundation`, and `libc++`.

### 2.3 Upstream Repository Cleanliness

The pinned reference repository was verified prior to integration and remained clean throughout:
```
$ git -C reference-repos/01-apple-silicon-and-inference/llama.cpp status
On branch master
Your branch is up to date with 'origin/master'.
nothing to commit, working tree clean

$ git -C reference-repos/01-apple-silicon-and-inference/llama.cpp rev-parse HEAD
547208dca250ceb3e4c8615598d043f2b602a527
```

---

## 3. Integration Procedure and Exact Project Changes

### 3.1 Filesystem Additions

1. Created directory `Aether/Frameworks/`.
2. Copied `llama.xcframework` from `/tmp/aether-llama-build/out/llama.xcframework` to `Aether/Frameworks/llama.xcframework`.
3. Added `Aether/Frameworks/LICENSE-llama.cpp.txt` containing the MIT License notice from `llama.cpp` (Copyright (c) 2023-2026 The ggml authors) for bundled attribution.

### 3.2 Xcode Project (`Aether.xcodeproj/project.pbxproj`) Modifications

The project file was modified following the project's established hex ID format (`AE0000...20261018...`):

1. **PBXBuildFile Section:**
   - Added `AE0000262026101800000026`: `llama.xcframework in Frameworks` (for linkage).
   - Added `AE0000272026101800000027`: `llama.xcframework in Embed Frameworks` with attributes `(CodeSignOnCopy, RemoveHeadersOnCopy)`.
2. **PBXCopyFilesBuildPhase Section:**
   - Added phase `AE0000342026101800000034` (`Embed Frameworks`) targeting subfolder `10` (`Frameworks`) with file reference `AE0000272026101800000027`.
3. **PBXFileReference Section:**
   - Added `AE0000182026101800000018`: `llama.xcframework` (`lastKnownFileType = wrapper.xcframework; path = llama.xcframework; sourceTree = "<group>";`).
4. **PBXFrameworksBuildPhase Section:**
   - Appended `AE0000262026101800000026` to `files` in the target's existing `Frameworks` build phase (`AE0000322026101800000032`).
5. **PBXGroup Section:**
   - Added `Frameworks` group `AE00000A202610180000000A` (`path = Frameworks; children = (llama.xcframework);`) as a child of main `Aether` group `AE0000042026101800000004`.
6. **PBXNativeTarget Section:**
   - Appended `Embed Frameworks` phase `AE0000342026101800000034` to target `AE0000302026101800000030` (`buildPhases`).
7. **Runtime Search Paths:**
   - The target's `LD_RUNPATH_SEARCH_PATHS` already contained `"@executable_path/../Frameworks"`. No alteration of existing rpaths was required.

### 3.3 Diff Summary
```diff
--- Aether.xcodeproj/project.pbxproj (pre-integration)
+++ Aether.xcodeproj/project.pbxproj (post-integration)
@@ -14,6 +14,22 @@
 		AE0000252026101800000025 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = AE0000152026101800000015 /* Assets.xcassets */; };
+		AE0000262026101800000026 /* llama.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = AE0000182026101800000018 /* llama.xcframework */; };
+		AE0000272026101800000027 /* llama.xcframework in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = AE0000182026101800000018 /* llama.xcframework */; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
 /* End PBXBuildFile section */
 
+/* Begin PBXCopyFilesBuildPhase section */
+		AE0000342026101800000034 /* Embed Frameworks */ = {
+			isa = PBXCopyFilesBuildPhase;
+			buildActionMask = 2147483647;
+			dstPath = "";
+			dstSubfolderSpec = 10;
+			files = (
+				AE0000272026101800000027 /* llama.xcframework in Embed Frameworks */,
+			);
+			name = "Embed Frameworks";
+			runOnlyForDeploymentPostprocessing = 0;
+		};
+/* End PBXCopyFilesBuildPhase section */
+
 /* Begin PBXFileReference section */
@@ -25,2 +41,3 @@
 		AE0000172026101800000017 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
+		AE0000182026101800000018 /* llama.xcframework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = llama.xcframework; sourceTree = "<group>"; };
 /* End PBXFileReference section */
@@ -32,2 +49,3 @@
 			files = (
+				AE0000262026101800000026 /* llama.xcframework in Frameworks */,
 			);
@@ -58,2 +76,3 @@
 				AE0000052026101800000005 /* Sources */,
+				AE00000A202610180000000A /* Frameworks */,
 				AE0000082026101800000008 /* Resources */,
@@ -108,2 +127,10 @@
 		};
+		AE00000A202610180000000A /* Frameworks */ = {
+			isa = PBXGroup;
+			children = (
+				AE0000182026101800000018 /* llama.xcframework */,
+			);
+			path = Frameworks;
+			sourceTree = "<group>";
+		};
 /* End PBXGroup section */
@@ -118,2 +145,3 @@
 				AE0000332026101800000033 /* Resources */,
+				AE0000342026101800000034 /* Embed Frameworks */,
 			);
```

---

## 4. Build Execution and Results

### 4.1 Invocation Command
```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -configuration Debug build
```

### 4.2 Build Result
```
Command Output Snippet:
...
ExtractAppIntentsMetadata (in target 'Aether' from project 'Aether')
    warning: Metadata extraction skipped, no AppIntents.framework dependency found

CodeSign .../Aether.app/Contents/Frameworks/llama.framework (via CodeSignOnCopy)
CodeSign .../Aether.app/Contents/MacOS/Aether.debug.dylib
CodeSign .../Aether.app

note: Disabling hardened runtime with ad-hoc codesigning. (in target 'Aether' from project 'Aether')
** BUILD SUCCEEDED **
```

### 4.3 Warnings Audit
- **New warnings introduced:** 0
- **Pre-existing diagnostic notes:**
  1. `warning: Metadata extraction skipped, no AppIntents.framework dependency found` (standard AppIntents build-phase note from Xcode 16/27.0 SDK).
  2. `note: Disabling hardened runtime with ad-hoc codesigning` (standard Xcode behavior for development builds signed with `CODE_SIGN_IDENTITY = "-"`).

---

## 5. Built Bundle & Dynamic Linker Validation

### 5.1 Embedded Framework Inspection

The built application is located at:
`/Users/asadalishaikh/Library/Developer/Xcode/DerivedData/Aether-cjpfhhxjwtzfczgtskgobxcnuets/Build/Products/Debug/Aether.app`

Within the bundle:
- Path: `Contents/Frameworks/llama.framework`
- Headers: Removed automatically by `RemoveHeadersOnCopy` attribute.
- Code Signature directory: `Contents/Frameworks/llama.framework/Versions/A/_CodeSignature/CodeResources` present.
- Deployment target: macOS `14.0`.
- Architecture: `arm64`.

### 5.2 Code Signing Verification

```bash
$ codesign --verify --verbose=4 .../Contents/Frameworks/llama.framework
/Users/asadalishaikh/.../Contents/Frameworks/llama.framework: valid on disk
/Users/asadalishaikh/.../Contents/Frameworks/llama.framework: satisfies its Designated Requirement

$ codesign --verify --verbose=4 --deep .../Aether.app
--prepared:.../Contents/MacOS/__preview.dylib
--validated:.../Contents/MacOS/__preview.dylib
--prepared:.../Contents/MacOS/Aether.debug.dylib
--validated:.../Contents/MacOS/Aether.debug.dylib
--prepared:.../Contents/Frameworks/llama.framework/Versions/Current/.
--validated:.../Contents/Frameworks/llama.framework/Versions/Current/.
/Users/asadalishaikh/.../Aether.app: valid on disk
/Users/asadalishaikh/.../Aether.app: satisfies its Designated Requirement
```

### 5.3 Dynamic Loader Dependency Resolution

Inspection of Mach-O headers confirms the linkage and search paths:
1. `Aether.debug.dylib` (app logic dylib) references:
   ```
   @rpath/llama.framework/Versions/Current/llama
   ```
2. Both `Aether` executable and `Aether.debug.dylib` define `LC_RPATH`:
   ```
   path @executable_path/../Frameworks
   ```
3. Therefore, dyld resolves:
   `@executable_path/../Frameworks/llama.framework/Versions/Current/llama` which cleanly matches `Aether.app/Contents/Frameworks/llama.framework/Versions/Current/llama`.

### 5.4 Runtime Process Verification

The built `Aether.app` binary was launched to verify runtime behavior:
1. **Execution Status:** Process launched under PID `33785`, initialized without crash, assertion, or dyld missing-library failure.
2. **Memory Map Verification (`vmmap`):**
   ```
   __TEXT         1053f8000-10581c000  r-x/rwx  .../Aether.app/Contents/Frameworks/llama.framework/Versions/A/llama
   __DATA_CONST   10581c000-105830000  r--/rw-  .../Aether.app/Contents/Frameworks/llama.framework/Versions/A/llama
   __DATA         105830000-105d30000  rw-/rwx  .../Aether.app/Contents/Frameworks/llama.framework/Versions/A/llama
   __DATA         105d30000-105db4000  rw-/rwx  .../Aether.app/Contents/Frameworks/llama.framework/Versions/A/llama
   __LINKEDIT     105db4000-105ed4000  r--/rwx  .../Aether.app/Contents/Frameworks/llama.framework/Versions/A/llama
   ```
   The `__DATA` mapping spans 5.12 MB, accommodating the embedded 5.2 MB `__DATA,__ggml_metallib` section containing all 36 compiled Metal kernels.
3. **UI / Window Inspection Note:** Automated UI scripting via `osascript` in the subshell returned macOS error `-1728` (`assistive access not allowed`) due to TCC privacy protections on headless terminal commands without Accessibility permissions. However, the app process ran cleanly with no stderr diagnostics or runtime faults.

---

## 6. Strict Scope Adherence Checklist

- [x] No inference implementation (`InferenceService`, model loading, token generation).
- [x] No streaming, cancellation, or atomic shims implemented.
- [x] No UI redesign or code refactoring in `Aether/Sources/`.
- [x] No entitlement or sandbox configuration changes.
- [x] No changes inside `reference-repos/`.
- [x] Pinned repository verified clean at commit `547208dca250ceb3e4c8615598d043f2b602a527`.
- [x] Minimum necessary changes applied to `project.pbxproj`.
- [x] Preserved required MIT attribution notice in `Aether/Frameworks/LICENSE-llama.cpp.txt`.

---

## 7. Current Project State & Next Step

The native macOS application target is fully configured and verified to build, link, embed, and load `llama.framework`.

Inference implementation remains unauthorized. Per instructions, all work stops here until explicit user authorization for Phase 3.4.
