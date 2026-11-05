# Aether v1.0.0 — Capstone Release

**Release Name:** Aether v1.0.0 (Phase 4 Capstone Edition)  
**Target Platform:** macOS 14.0+ (Sonoma, Sequoia)  
**Supported Hardware:** Apple Silicon Macs (M1 / M2 / M3 / M4, arm64)  
**Release Artifact:** `Aether-v1.0.0-arm64.dmg`  
**SHA-256 Checksum:** `4a077eacb5e020c53660cffeac28f6954e4cb853c2e964bb1f37d9c4076d51ce`

---

## Overview

Aether v1.0.0 is an offline-first, private personal AI agent engineered natively in Swift 6 and SwiftUI for Apple Silicon Macs. It runs local large language models (GGUF format) with direct Metal hardware acceleration, features an integrated Hugging Face model catalog, and executes autonomous, multi-step agentic workflows with strict human-in-the-loop security boundaries.

---

## What's New in v1.0.0

### 1. Native Apple Silicon Inference Engine
- In-process C/Metal binding via `llama.xcframework` running on Apple Silicon unified memory.
- Real-time token streaming with configurable context windows and stop sequences.
- Zero network telemetry during inference.

### 2. Autonomous Multi-Step Agent Loop (Phase 4)
- **Chain-of-Thought Parsing:** Automatically segregates `<thought>` tags into an interactive, collapsible "Reasoning Process" UI disclosure card.
- **Dynamic Tool Definitions:** Injects XML and JSON schemas into local model system prompts.
- **Recursive Execution Budgeting:** Automatically clamps multi-step agent actions to a maximum of 5 iterations to prevent runaway execution.

### 3. Built-in Native Tools & Security Architecture
- **Safe Calculator (`safe_calculator`):** Pure Swift recursive descent arithmetic parser with support for transcendental functions (`sqrt, sin, cos, tan, log, ln, abs`). Zero subprocess or shell invocations.
- **Hardware Telemetry (`system_info`):** Retrieves Apple Silicon chip model, CPU core counts, physical RAM via Darwin `sysctl`, and thermal state.
- **Sandboxed File Reader (`sandboxed_file_reader`):** Safely reads local files with 10MB bounds, line clamping, and strict directory traversal prevention (`..`, `%2e%2e`).
- **Document Text Extractor (`document_text_extractor`):** Extracts structural summaries for JSON, CSV, Markdown, and plain text.
- **Desktop Notifications (`system_notification`):** Dispatches native macOS notifications via `UNUserNotificationCenter`.

### 4. Human-in-the-Loop Security & App Sandbox
- **Permission Tiers:** Separates `.safeReadOnly` operations from sensitive actions requiring user consent.
- **Interactive Approval Modal (`ToolConfirmationDialog`):** Suspends execution via Swift Concurrency continuations, allowing users to inspect exact parameters before granting "Allow Once", "Allow for Session", or "Deny".
- **Prompt Injection Defense:** Heuristically blocks prompt override attacks, jailbreak directives, and tag closure exploits.
- **Redacted Audit Trail:** Records all tool calls with automatic scrubbing of keys, tokens, and secrets.

### 5. Hugging Face Catalog & Download Manager
- Integrated model browser supporting popular open-weight architectures (Qwen 2.5, Llama 3.2, Mistral).
- Multi-tier quantization selection (Q4_K_M, Q8_0, etc.) with estimated RAM requirements.
- Resilient background downloads with SHA-256 validation and security-scoped bookmark persistence.

---

## Installation Instructions

### Option 1: Drag-and-Drop via DMG
1. Download `Aether-v1.0.0-arm64.dmg`.
2. Double-click the DMG to mount it.
3. Drag the **Aether** app icon into the **Applications** folder shortcut.
4. Eject the DMG.

### Option 2: Gatekeeper First-Launch Verification (Ad-Hoc Signed Build)
Because this capstone build is ad-hoc signed for open-source evaluation without a paid Apple Developer ID certificate:
- **First Launch (GUI):** Right-click (or Control-click) `Aether.app` in `/Applications` and select **Open**, then click **Open** in the security confirmation dialog.
- **First Launch (Terminal alternative):** If macOS Gatekeeper displays a quarantine prompt, remove the quarantine attribute:
  ```bash
  xattr -d com.apple.quarantine /Applications/Aether.app
  ```

---

## Quick Start Guide

1. **Launch Aether** from your Applications folder.
2. Navigate to the **Model Library** in the sidebar.
3. Select and download a lightweight model (e.g. `Qwen 2.5 Coder 1.5B Instruct Q4_K_M` or `Llama 3.2 3B Instruct Q4_K_M`).
4. Return to **Chat**, toggle **Agent Mode** to **ON** in the top bar.
5. Enter a prompt requiring computation or file inspection (e.g., *"Calculate the square root of 529 plus 14 squared"*).
6. Observe the agent plan in the "Reasoning Process" card, call the native tool, and synthesize the result.

---

## Verification & Build Metadata

- **Compiler:** Apple Swift 6.4 (Xcode 27.1 / macOS 27.2 SDK)
- **Target OS:** macOS 14.0+
- **Architecture:** `arm64` (Apple Silicon)
- **App Sandbox:** Enabled (`com.apple.security.app-sandbox = true`)
- **Automated Tests:** 239 passed / 0 failed (100% pass rate)
