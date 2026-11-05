# Aether

Aether is an offline-first, private personal AI platform engineered natively for Apple Silicon Macs.

> **Status:** Phase 3.1 (Minimal Project Foundation) Verified.  
> Target Platform: macOS 14.0+ (Sonoma) on Apple Silicon (arm64).

---

## Quick Start: Building and Running

### Prerequisites
- macOS 14.0 or later
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

---

## Architecture & Documentation

- [Project Foundation Guide](file:///Users/asadalishaikh/Aether%20Agent/docs/PROJECT_FOUNDATION.md): Detailed project structure, toolchain assumptions, App Sandbox least-privilege configuration, and build validation.
- [Executive Summary](file:///Users/asadalishaikh/Aether%20Agent/research/00-executive-summary.md): High-level architectural overview and Apple Silicon memory thesis.
- [Product Requirements](file:///Users/asadalishaikh/Aether%20Agent/research/01-product-requirements.md): Hardware matrix, memory budgets, and PRD specifications.
- [Proposed Architecture](file:///Users/asadalishaikh/Aether%20Agent/research/05-proposed-architecture.md): Subsystems, clean interfaces, and dataflow.
- [Security Threat Model](file:///Users/asadalishaikh/Aether%20Agent/research/06-security-threat-model.md): Multi-layer defense and sandboxing.
- [License & Dependency Audit](file:///Users/asadalishaikh/Aether%20Agent/research/07-license-and-dependency-review.md): Repository licenses, copyleft hazards, and dependency guidelines.
- [Milestone Roadmap](file:///Users/asadalishaikh/Aether%20Agent/research/09-milestone-roadmap.md): Staged delivery from M0 MVP to M4 ecosystem.

---

## License

The top-level project license (MIT vs. Apache-2.0) is open pending distribution review. See [License & Dependency Review](file:///Users/asadalishaikh/Aether%20Agent/research/07-license-and-dependency-review.md).
