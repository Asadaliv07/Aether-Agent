# Aether Project Foundation Specification & Technical Guide

**Document Version:** 1.0.0  
**Phase:** 3.1 (Minimal Project Foundation)  
**Date:** October 18, 2026  
**Status:** Verified & Complete — Ready for Phase 3.2 Authorization  

---

## 1. Executive Summary & Scope Declaration

Phase 3.1 establishes the minimal, verified, native macOS project foundation for **Aether**—a local-first, zero-telemetry personal AI platform engineered for Apple Silicon.

In strict adherence to the Phase 3.1 authorization boundaries:
- **Authorized Scope:** Native macOS application target (`Aether.app`), SwiftUI + AppKit architecture, macOS 14.0 (Sonoma) deployment target, Swift 6 language mode with complete concurrency checking, App Sandbox least-privilege boundary, clean Xcode project configuration, and initial technical documentation.
- **Strictly Prohibited & Deferred:** Zero inference backends (`llama.cpp`, Metal compute kernels), zero C/C++ bindings, zero model downloads or weights, zero chat interfaces or conversation logic, zero SQLite persistence or migrations, zero RAG or vector stores, zero MCP tool servers or subprocesses, and zero third-party dependencies.

---

## 2. Project Directory Structure

The repository foundation is organized into a modular, clean hierarchy designed for incremental milestone implementation:

```
Aether Agent/
├── Aether/
│   ├── Sources/
│   │   ├── App/
│   │   │   ├── AetherApp.swift            # SwiftUI @main application entry point
│   │   │   ├── ContentView.swift          # Foundation verification shell view
│   │   │   └── AppState.swift             # Swift 6 @Observable foundation telemetry model
│   │   └── UI/
│   │       └── Components/
│   │           └── FoundationBadge.swift  # Modular telemetry badge component
│   └── Resources/
│       ├── Aether.entitlements            # App Sandbox entitlements (least privilege)
│       ├── Info.plist                     # Application metadata and system configuration
│       └── Assets.xcassets/               # Asset catalog (AppIcon, AccentColor)
│           ├── Contents.json
│           ├── AccentColor.colorset/
│           │   └── Contents.json
│           └── AppIcon.appiconset/
│               └── Contents.json
├── Aether.xcodeproj/
│   ├── project.pbxproj                    # Standard Xcode project manifest
│   └── xcshareddata/
│       └── xcschemes/
│           └── Aether.xcscheme            # Shared build/launch scheme for GUI and CLI
├── docs/
│   └── PROJECT_FOUNDATION.md              # Technical architecture and build guide
├── reference-repos/                       # Upstream reference implementations (read-only)
└── research/                              # Phase 2 validated research documents (read-only)
```

---

## 3. Build Configuration & Toolchain Environment

### 3.1 Verified System & Toolchain Telemetry
- **Host Operating System:** macOS 27.0.1 (Darwin 26A434 / Apple Silicon `arm64`)
- **Xcode Version:** Xcode 27.1 (Build `27A9275`)
- **Swift Compiler:** Apple Swift version 6.4 (`swiftlang-6.4.0.34.1 clang-2100.3.34.1`)
- **macOS SDK:** macOS 27.0 (`macosx27.0`)
- **Configured Deployment Target:** `macOS 14.0 (Sonoma)` (`MACOSX_DEPLOYMENT_TARGET = 14.0`)
- **Swift Language Version:** `6.0` (`SWIFT_VERSION = 6.0`)
- **Concurrency Mode:** Complete (`SWIFT_STRICT_CONCURRENCY = complete`)

### 3.2 Target Settings & Build Flags
- **Target Type:** Native macOS Application (`com.apple.product-type.application`)
- **Bundle Identifier:** `com.aether.Aether`
- **Product Name:** `Aether`
- **Hardened Runtime:** Enabled (`ENABLE_HARDENED_RUNTIME = YES`)
- **Code Signing:** Automatic ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) configured to run locally without external developer team certificates.
- **Runpath Search Paths:** `@executable_path/../Frameworks`

---

## 4. Application Sandbox & Least-Privilege Security

### 4.1 Enforced Sandbox Boundary
Aether is compiled with the macOS App Sandbox strictly enabled (`com.apple.security.app-sandbox = true`).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
</dict>
</plist>
```

### 4.2 Least-Privilege Posture & Future Entitlement Justification
In accordance with zero-trust local application principles:
- **Network Egress:** `com.apple.security.network.client` is **omitted**. Core platform operations remain 100% offline. When user-initiated model downloads are authorized in Milestone 3.5, this entitlement will be evaluated and proposed for explicit user review.
- **User-Selected Files:** `com.apple.security.files.user-selected.read-write` is **omitted**. External model directory workflows remain disabled until authorized in Milestone 3.5.
- **Hardware Access:** Microphone, camera, location, and Apple Events entitlements are strictly disabled.

---

## 5. How to Open and Build the Project

### 5.1 Using Xcode GUI
1. Double-click `Aether.xcodeproj` in Finder, or run from terminal:
   ```bash
   open "Aether.xcodeproj"
   ```
2. In the scheme selector at the top of the Xcode window, select the **Aether** scheme and target destination **My Mac**.
3. Press **`Cmd + B`** to build, or **`Cmd + R`** to run.

### 5.2 Using Command Line (`xcodebuild`)
To perform a clean build of the Debug configuration:
```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" build
```

To perform an optimized Release build with hardened runtime:
```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' -configuration Release CODE_SIGN_IDENTITY="-" build
```

---

## 6. Dependency and Licensing Audit

### 6.1 Direct Dependencies
**Zero external packages or third-party libraries have been added.**

The foundation depends strictly on first-party Apple SDK frameworks:
- `SwiftUI`: Native declarative presentation and window management.
- `AppKit`: Native macOS platform integration, standard panels, and menu responders.
- `Foundation`: Core operating system utilities and process information.
- `Observation`: Swift 6 thread-safe state modeling.

### 6.2 Top-Level Project Licensing
The selection between **Apache-2.0** and **MIT** remains intentionally open pending review of the distribution model (direct notarized Developer ID distribution vs. Mac App Store) with the user.

---

## 7. Repository-First Feature Reuse Audit

In accordance with the repository-first engineering policy, candidate repositories in `reference-repos/` were directly inspected before architectural decisions were made:

| Candidate Repository | Exact Paths Inspected | Findings & Technical Evaluation | Foundation Reuse Decision | License & Attribution |
|---|---|---|---|---|
| **`llama.cpp`** (`llama.swiftui`) | `examples/llama.swiftui/llama.swiftui.xcodeproj`<br/>`examples/llama.swiftui/llama.swiftui/llama_swiftuiApp.swift`<br/>`examples/llama.swiftui/llama.swiftui/UI/ContentView.swift` | Implements an Xcode project wrapping `llama.xcframework`. However, the UI code is structured for iOS (`UIKit`, `UIApplication`, `NavigationView`) and lacks modern macOS desktop patterns. | **Adapted project packaging intent; rejected iOS source implementation.** Built a clean macOS 14.0 SwiftUI 6 desktop architecture. | MIT License (Georgi Gerganov). Attribution preserved. |
| **`mlx-swift-examples`** | `Applications/LLMBasic/LLMBasicApp.swift`<br/>`Applications/MLXChatExample/MLXChatExample.entitlements`<br/>`Package.swift` | Modern SwiftUI macOS app lifecycle and App Sandbox entitlements (`com.apple.security.app-sandbox`). Uses macOS 14.0 deployment baseline. | **Reused App Sandbox pattern; pruned all unnecessary entitlements.** Applied strict least-privilege principles. | MIT License (Apple Inc.). Attribution preserved. |
| **`duckdb-swift`** (`ExoplanetExplorer`) | `Examples/SwiftUI/ExoplanetExplorer.xcodeproj/project.pbxproj` | Demonstrates clean PBX build configuration, asset catalog handling, and macOS target settings. | **Adapted clean PBX target structure and asset catalog organization.** | MIT License (DuckDB Foundation). |
| **`desktop`** (Open WebUI Desktop) / **`tauri`** | `reference-repos/08-desktop-ui-and-application-frameworks/desktop`<br/>`reference-repos/08-desktop-ui-and-application-frameworks/tauri` | Heavyweight WebKit/Electron wrapper runtimes. Open WebUI Desktop is licensed under GNU GPL-3.0. | **Strictly REJECTED.** Aether is 100% native Swift/SwiftUI to maintain ~25–35 MB idle RAM target and avoid copyleft hazards. | GPL-3.0 (Strict avoidance). |

---

## 8. Validation Results

The Phase 3.1 foundation was empirically validated using the local macOS 27.0 / Xcode 27.1 toolchain:

| Validation Check | Tool / Command | Expected Outcome | Actual Outcome | Status |
|---|---|---|---|:---:|
| **PBX Syntax & Linting** | `plutil -lint Aether.xcodeproj/project.pbxproj` | Valid plist format | `OK` | **PASS** |
| **Info.plist Linting** | `plutil -lint Aether/Resources/Info.plist` | Valid plist format | `OK` | **PASS** |
| **Entitlements Linting** | `plutil -lint Aether/Resources/Aether.entitlements` | Valid plist format | `OK` | **PASS** |
| **Debug Build** | `xcodebuild -scheme Aether build` | Compile & link with 0 errors | `** BUILD SUCCEEDED **` | **PASS** |
| **Release Build** | `xcodebuild -scheme Aether -configuration Release build` | Compile, optimize, & link with 0 errors | `** BUILD SUCCEEDED **` | **PASS** |
| **Sandbox Verification** | `codesign -d --entitlements :- Aether.app` | Contains only `app-sandbox` and debug token | `com.apple.security.app-sandbox = true` | **PASS** |
| **Architecture Verification** | `file Aether.app/Contents/MacOS/Aether` | Mach-O 64-bit arm64 executable | `Mach-O 64-bit executable arm64` | **PASS** |
| **Target Deployment Version** | `plutil -p Aether.app/Contents/Info.plist` | `LSMinimumSystemVersion = 14.0` | `LSMinimumSystemVersion = "14.0"` | **PASS** |
| **Live Execution Test** | Direct invocation of `Aether.app` binary | Launch, initialize, run runloop, terminate cleanly | Process ran stably; terminated cleanly with 0 errors | **PASS** |

---

## 9. Known Limitations & Prerequisites for Phase 3.2

### 9.1 Known Limitations of Phase 3.1
- The application currently displays the verification shell. It cannot perform AI inference, load GGUF weights, persist messages, or connect to external tools.
- Network access is disabled at the sandbox boundary.

### 9.2 Prerequisites for Phase 3.2 (Inference Backend Integration)
Before Milestone 3.2 can be authorized:
1. User authorization for Phase 3.2.
2. Selection of `llama.cpp` upstream release tag (e.g., `b3800`+) to vendor into the internal SPM target (`LlamaCore`).
3. Confirmation of Metal compute shader compilation configuration for Apple Silicon.
