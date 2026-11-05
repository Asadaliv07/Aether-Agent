# Aether: Capstone Presentation & Demo Video Recording Script

**Project:** Aether — Local-First Apple Silicon AI Agent  
**Format:** Screen Recording + Voiceover Demo  
**Target Duration:** 5–7 minutes  
**Target Audience:** Capstone Evaluators, Technical Reviewers, Systems Engineers  
**System Baseline:** macOS 14.0+ (Sonoma/Sequoia), Apple Silicon (M1/M2/M3/M4)

---

## Technical Capabilities Verified for Demonstration

| Feature Component | Implementation in Codebase | Demonstration Focus |
| :--- | :--- | :--- |
| **Native Apple Silicon Inference** | `llama.xcframework` + Metal Performance Shaders | Zero-cloud, 100% local token streaming |
| **Hugging Face Model Manager** | `HuggingFaceCatalogService`, `ModelDownloadManager` | In-app search, quantization tiers, background downloads |
| **Agent Reasoning Engine** | `AgentOrchestrator.swift` | Visible `<thought>` process & collapsible reasoning UI |
| **Tool Execution Engine** | `ToolRegistry.swift`, `Tool.swift` | Safe recursive descent arithmetic, Darwin hardware metrics |
| **Security & Human-in-the-Loop** | `ToolSecurityGuard.swift`, `ChatView.swift` | Interactive continuation modal (`ToolConfirmationDialog`) |
| **Prompt Injection & Path Defense**| `ToolSecurityGuard.detectPromptInjection` | Rejection of traversal (`..`) and jailbreak overrides |
| **Audit Trail & Observability** | `ToolAuditLogger.swift` | Redacted in-memory telemetry, structured `os.Logger` |

---

## Detailed Scene-by-Scene Script

### Scene 1: Introduction & Architectural Overview (0:00 - 0:45)
- **Visual:** Open macOS Desktop showing system specifications (Apple Silicon Mac), terminal with zero external cloud daemon dependencies, and the `Aether.app` icon in Applications.
- **Narrator (Spoken):**
  > "Welcome to this demonstration of Aether. Aether is a private, local-first personal AI agent engineered natively in Swift 6 for Apple Silicon Macs. 
  > Unlike cloud-tethered agents that transmit private data to external servers, Aether executes directly on Apple Silicon unified memory using Metal compute kernels. 
  > Today, we'll demonstrate Aether's cold-start performance, local model execution, multi-step autonomous agent loop, native tool execution, and our strict human-in-the-loop security architecture."

---

### Scene 2: Application Cold Start & Interface Tour (0:45 - 1:30)
- **Action:** Launch `Aether.app` from Finder or Spotlight.
- **Visual:** App window opens instantly (~25–35 MB idle RAM footprint). The split-view interface shows the Chat conversation sidebar on the left and the primary interaction workspace on the right.
- **Narrator (Spoken):**
  > "Launching Aether, we observe an instant cold start with an idle memory footprint under 35 megabytes. The UI is built entirely in native SwiftUI and AppKit, respecting macOS design principles and running strictly inside the macOS App Sandbox.
  > In the top navigation bar, notice our Agent Mode toggle, active model badge, and session controls. Let's first inspect the Model Library."

---

### Scene 3: Model Library & Hugging Face Catalog (1:30 - 2:30)
- **Action:** Click "Model Library" in the sidebar. Show the curated catalog (e.g., Qwen 2.5 Coder, Llama 3.2, Mistral). Show quantization tags (Q4_K_M, Q8_0), memory budget estimates, and SHA-256 verification.
- **Visual:** Initiate or inspect an existing downloaded GGUF model. Show that model files are stored safely in the App Sandbox Application Support container with security-scoped bookmarks.
- **Narrator (Spoken):**
  > "Aether features an integrated Hugging Face Hub catalog manager. Users can discover, inspect, and download GGUF models across quantization tiers—from lightweight 1.5B parameter models up to 14B models, depending on unified memory capacity. 
  > Downloads utilize Apple's background URLSession with resume capabilities and SHA-256 integrity verification. Once downloaded, models are bound via security-scoped bookmarks and ready for in-process Metal inference."

---

### Scene 4: Core Inference & Agent Reasoning Loop (2:30 - 3:30)
- **Action:** Switch to Chat. Ensure "Agent Mode" toggle in the header is **ON**. Select a loaded model (e.g., Qwen 2.5 Coder or Llama 3.2).
- **Prompt:**
  ```text
  Please calculate the volume of a sphere with a radius of 14.5 cm, and explain your steps.
  ```
- **Visual:** As tokens stream in real time, show the UI automatically isolating the `<thought>` tag into a dedicated, collapsible **"Reasoning Process"** disclosure card with an orange bulb icon.
- **Narrator (Spoken):**
  > "Now, let's observe Aether's agent loop. When Agent Mode is active, Aether injects structured tool definitions and instructions into the model context. 
  > As the model generates its response, our AgentOrchestrator parses the stream in real time. Notice how internal chain-of-thought reasoning is segregated into this collapsible 'Reasoning Process' card, keeping conversational output clean while maintaining complete transparency."

---

### Scene 5: Tool Calling & Pure Swift Execution (3:30 - 4:30)
- **Visual:** The model determines it needs arithmetic precision and emits:
  ```xml
  <tool_call>
  <name>safe_calculator</name>
  <parameters>{"expression": "(4/3) * 3.1415926535 * (14.5 ^ 3)"}</parameters>
  </tool_call>
  ```
- **Action:** Point out the animated active tool telemetry capsule in the header (`Executing: safe_calculator`). Show the resulting tool badge in the message bubble displaying `SUCCESS` with the computed output.
- **Narrator (Spoken):**
  > "Rather than guessing calculations with hallucinated floating-point math, the agent delegates the expression to `safe_calculator`. 
  > Because math computation is classified as `.safeReadOnly`, the tool registry executes it immediately via a pure Swift recursive descent arithmetic parser with zero subprocesses and zero shell invocations.
  > The tool response is formatted into an observation block, fed back into the agent context, and synthesized into the final conversational answer."

---

### Scene 6: Human-in-the-Loop Security & Permission Gate (4:30 - 5:30)
- **Prompt:**
  ```text
  Please inspect the file at /Users/Shared/notes.txt and summarize its content for me.
  ```
- **Visual:** The model emits a call to `sandboxed_file_reader`.
- **UI Event:** Instead of silently executing file I/O, the interface immediately halts and presents the **`ToolConfirmationDialog`** sheet.
- **Visual:** The sheet highlights:
  - Tool: `sandboxed_file_reader`
  - Permission Level: Sensitive / User Authorization Required
  - Target Path: `/Users/Shared/notes.txt`
  - Action Buttons: `[Deny]`, `[Allow Once]`, `[Allow for Session]`
- **Action:** Click "Allow Once". The file is read, line-clamped, and summarized in the chat.
- **Narrator (Spoken):**
  > "This brings us to Aether's core security boundary: explicit human authorization. 
  > Any tool that accesses the file system or triggers native notifications is classified as `.userConfirmationRequired`. 
  > The agent loop suspends using Swift Concurrency continuations and presents this confirmation modal. The user retains complete authority: they can inspect the exact path, allow the operation once, trust it for the session, or deny it. 
  > Furthermore, our Security Guard actively validates inputs against directory traversal attacks like `../` escapes and scans for adversarial prompt injection attempts."

---

### Scene 7: Observability, Reviewer Models & Audit Logs (5:30 - 6:30)
- **Action:** Open macOS Console.app or show internal audit logging stream.
- **Visual:** Filter for subsystem `com.aether.agent` / category `ToolAudit`.
- **Show Log Entries:**
  ```
  [ToolAudit] Tool executed: safe_calculator in 0.000412s [status=success]
  [ToolAudit] User confirmation granted for tool: sandboxed_file_reader
  ```
- **Narrator (Spoken):**
  > "For enterprise auditability and evaluation, every tool invocation is tracked by our `ToolAuditLogger`. 
  > Execution durations are measured to nanosecond precision with continuous monotonic clocks. Sensitive parameters like tokens or private keys are automatically redacted before logging. 
  > Quality gates and stop-sequence filters ensure that models do not run in infinite recursive loops, enforcing an automatic five-step execution budget."

---

### Scene 8: Conclusion & Capstone Summary (6:30 - 7:00)
- **Visual:** Return to the primary Aether window with the completed conversation.
- **Narrator (Spoken):**
  > "In summary, Aether proves that capable, autonomous AI agents do not require sacrificing privacy or running in unconstrained cloud environments. 
  > With native Apple Silicon Metal acceleration, a modular tool architecture, and human-in-the-loop permission gates, Aether delivers the power of agentic workflows entirely on-device.
  > Thank you."

---

## Presenter Preparation Checklist

Before recording:
1. **Model Preparation:** Pre-download a tested GGUF model (e.g. `Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf` or `Llama-3.2-3B-Instruct-Q4_K_M.gguf`) to avoid waiting for network downloads during the video.
2. **Test File:** Create a sample text file at `/Users/Shared/notes.txt` with sample project notes.
3. **Display Settings:** Set display resolution to 1920x1080 (1080p) or 2560x1440 for clean recording with visible UI fonts.
4. **Clean macOS Environment:** Hide desktop icons, enable 'Do Not Disturb', and close background apps.
