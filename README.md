# Aether

Aether is an offline-first, private personal AI platform engineered natively for Apple Silicon Macs.

> **Status:** Phase 4 (Advanced Agent Capabilities & Tool Execution) Verified.  
> Target Platform: macOS 14.0+ (Sonoma) on Apple Silicon (arm64).

---

## Capabilities & Architecture Highlights

- **Native Apple Silicon Inference:** Hardware-accelerated LLM execution via embedded `llama.xcframework` and Metal compute kernels.
- **Model Catalog & Manager:** In-app discovery, download manager with SHA-256 verification, and security-scoped bookmark persistence.
- **Secure Tool Execution Engine (Phase 4):**
  - Protocol-oriented tool interface (`Tool`, `ToolDefinition`, `ToolParameter`) with automated XML and JSON Schema generation.
  - Three-tier permission architecture (`.safeReadOnly`, `.userConfirmationRequired`, `.restrictedSystem`).
  - Interactive user authorization gate with Swift Concurrency continuation-based UI approvals.
  - Strict App Sandbox compliance, path traversal prevention, and adversarial prompt injection heuristics.
  - Subprocess-free computation (`SafeCalculatorTool`), hardware telemetry (`SystemInfoTool`), sandboxed file inspection (`SandboxedFileReaderTool`), document structure extraction (`DocumentTextExtractorTool`), and native desktop notifications (`SystemNotificationTool`).
  - Asynchronous execution bounded by `TaskGroup` timeout racing and user-directed cancellation.
- **Multi-Step Agent Orchestrator:** Chain-of-thought parsing (`<thought>`), tool extraction (`<tool_call>`), structured observation injection (`<tool_response>`), and recursive execution bounds.
- **Privacy & Audit Logging:** Zero cloud telemetry, local-only SQLite storage, and redacted in-memory tool audit trail.

---

## Quick Start: Building and Running

### Prerequisites
- macOS 14.0 or later (Apple Silicon)
- Xcode 16.0 or later with Command Line Tools installed

### Open in Xcode
Double-click `Aether.xcodeproj` or open via terminal:
```bash
open "Aether.xcodeproj"
```
Select the **Aether** scheme and press **Cmd + R** to run.

### Build from Terminal
```bash
xcodebuild -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" build
```

### Run Automated Tests
```bash
xcodebuild test -project Aether.xcodeproj -scheme Aether -destination 'platform=macOS' CODE_SIGN_IDENTITY="-"
```

---

## Architecture & Documentation

- [Phase 4 Agent Tool Execution Architecture](file:///Users/asadalishaikh/Aether%20Agent/research/53-phase-4-agent-tool-execution-architecture.md): Formal design specification of the Phase 4 tool engine, security guard, native macOS tools, and multi-step orchestration loop.
- [Project Foundation Guide](file:///Users/asadalishaikh/Aether%20Agent/docs/PROJECT_FOUNDATION.md): Detailed project structure, toolchain assumptions, App Sandbox least-privilege configuration, and build validation.
- [Executive Summary](file:///Users/asadalishaikh/Aether%20Agent/research/00-executive-summary.md): High-level architectural overview and Apple Silicon memory thesis.
- [Product Requirements](file:///Users/asadalishaikh/Aether%20Agent/research/01-product-requirements.md): Hardware matrix, memory budgets, and PRD specifications.
- [Proposed Architecture](file:///Users/asadalishaikh/Aether%20Agent/research/05-proposed-architecture.md): Subsystems, clean interfaces, and dataflow.
- [Security Threat Model](file:///Users/asadalishaikh/Aether%20Agent/research/06-security-threat-model.md): Multi-layer defense and sandboxing.
- [Milestone Roadmap](file:///Users/asadalishaikh/Aether%20Agent/research/09-milestone-roadmap.md): Staged delivery from M0 MVP to M4 ecosystem.

---

## License

The top-level project license (MIT vs. Apache-2.0) is open pending distribution review. See [License & Dependency Review](file:///Users/asadalishaikh/Aether%20Agent/research/07-license-and-dependency-review.md).
