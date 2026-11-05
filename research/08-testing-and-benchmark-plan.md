# Aether Quality Assurance: Testing & Benchmark Specification

**Date:** October 18, 2026  
**Status:** Validated Testing & Benchmark Specification (Phase 2.2 Complete — Protocol Locked Pending Phase 3 Authorization)  
**Target Hardware Matrix:**  
- **Primary Development & Validation Baseline:** Apple M5 MacBook Air with 16 GB Unified Memory (Official 153 GB/s memory bandwidth, announced March 2026; LLM throughput and latency targets explicitly unmeasured until benchmarked).  
- **Secondary Compatibility Tier:** Apple Silicon Macs with 8 GB Unified Memory (M1–M4 Base MacBook Air / Mac mini — strictly resource-constrained tier; 3B–4B models and 4K context cap proposed as conservative policies pending testing).  
- **Other Supported Hardware Classes:** M1/M2 16 GB, M3/M4 16 GB, and Pro/Max/Ultra Workstation Tier (32 GB – 128 GB Unified Memory).  
**Objective:** Define objective benchmarking protocols, provisional performance targets, reproducible testing procedures, and automated quality gates for Aether.

> [!IMPORTANT]
> **Empirical Governance Rule:** All figures in this document represent analytical projections, mathematically derived minimums, or community reference estimates. **No metric shall be classified as `[MEASURED]` until the reproducible benchmark protocol defined herein is executed under explicit human authorization during Phase 3.**

---

## 1. Quality Assurance Architecture

Because Apple Silicon shares memory bandwidth across CPU, GPU, and Neural Engine, synthetic microbenchmarks fail to capture desktop ergonomics and physical memory contention. Aether establishes an objective testing harness:

```mermaid
graph TD
    subgraph TestHarness["Aether Testing & Benchmark Harness"]
        CLI["Headless Benchmark CLI (`aether-bench`)"]
        INSTRUMENTS["macOS Instruments & os_signpost Telemetry"]
        PROMPTFOO["Promptfoo Red-Teaming Suite (CI)"]
        MEMMON["Continuous RSS & Swap Monitor"]
    end

    subgraph MetricsCaptured["Target Metrics"]
        LOAD["Cold & Warm Load Time (ms)"]
        TTFT["Time to First Token (TTFT ms)"]
        TPS["Generation Throughput (tok/s)"]
        CANCEL["Cancellation Latency (ms)"]
        RSS["Peak Resident Set Size (RSS MB)"]
        RECLAIM["Idle Memory Reclamation (MB)"]
        SWAP["macOS Swap Page-Out Activity (Bytes)"]
    end

    TestHarness --> MetricsCaptured
```

---

## 2. Hardware Performance Targets & Acceptance Matrix

### 2.1 Hardware Configuration Targets (Provisional Projections vs. Acceptance Ceilings)

The targets below represent provisional engineering goals. They are strictly distinguished from verified facts:

| Metric | 8 GB Compatibility Tier (M1–M4)<br/>*Model: 3B Q4_K_M (4K Context)* | 16 GB Baseline (M1–M4)<br/>*Model: 8B Q4_K_M (8K Context)* | Primary Target: M5 MacBook Air (16 GB)<br/>*Model: 8B Q4_K_M (8K Context)* | Acceptance Criteria / Failure Ceiling |
|---|---|---|---|---|
| **App Idle Footprint** | **25 – 35 MB RAM** `[ESTIMATED TARGET]` | **25 – 35 MB RAM** `[ESTIMATED TARGET]` | **25 – 35 MB RAM** `[ESTIMATED TARGET]` | Fail if Idle RSS > 60 MB |
| **Model Cold Start (`mmap`)** | **300 – 450 ms** `[ESTIMATED TARGET]` | **600 – 850 ms** `[ESTIMATED TARGET]` | **500 – 700 ms** `[ESTIMATED TARGET]` | Fail if Cold Start > 1500 ms |
| **TTFT (512 prompt tokens)** | **120 – 180 ms** `[ESTIMATED TARGET]` | **180 – 240 ms** `[ESTIMATED TARGET]` | **~140 – 180 ms** `[ESTIMATED TARGET]` | Fail if TTFT > 500 ms |
| **TTFT (2048 prompt tokens)**| **350 – 550 ms** `[ESTIMATED TARGET]` | **450 – 650 ms** `[ESTIMATED TARGET]` | **~350 – 480 ms** `[ESTIMATED TARGET]` | Fail if TTFT > 1200 ms |
| **Generation Speed (TPS)** | **35 – 55 tok/s** `[ESTIMATED TARGET]` | **24 – 35 tok/s** `[ESTIMATED TARGET]` | **~30 – 42 tok/s** `[ESTIMATED TARGET]` | Fail if Generation < 18 tok/s |
| **Peak Total RAM (App + Model)**| **~2.45 GB** `[CALCULATED]` | **~6.15 GB** `[CALCULATED]` | **~6.15 GB** `[CALCULATED]` | **Hard Stop if 8 GB Mac RSS > 4.5 GB** |
| **macOS Swap Activity** | **0 bytes swap** `[PROPOSED TARGET]` | **0 bytes swap** `[PROPOSED TARGET]` | **0 bytes swap** `[PROPOSED TARGET]` | **Immediate Fail if Swap Write > 0 MB** |
| **Idle Memory Reclaim** | **Unload in 300s -> RSS < 35 MB**| **Unload in 300s -> RSS < 40 MB**| **Unload in 300s -> RSS < 40 MB**| Fail if model weights leak into idle |
| **UI Main Thread Latency** | **< 8 ms (120 Hz)** `[ESTIMATED TARGET]` | **< 8 ms (120 Hz)** `[ESTIMATED TARGET]` | **< 8 ms (120 Hz)** `[ESTIMATED TARGET]` | Fail if UI drops frames during inference |
| **Cancellation Response** | **Signal < 1 ms; Halt 5–50 ms target** `[UNVERIFIED TARGET]` | **Signal < 1 ms; Halt 5–50 ms target** `[UNVERIFIED TARGET]` | **Signal < 1 ms; Halt 5–50 ms target** `[UNVERIFIED TARGET]` | Fail if complete GPU halt takes > 75 ms |

---

## 3. Attention KV-Cache Memory Accounting

KV cache memory is calculated mathematically as:
$$\text{Memory}_{\text{KV}} = 2 \times N_{\text{layers}} \times N_{\text{kv\_heads}} \times D_{\text{head}} \times L_{\text{ctx}} \times \text{bytes\_per\_element}$$

### Calculated Memory Allocation for Llama-3.1-8B (FP16 = 2 Bytes):
*Parameters: 32 layers, 8 KV heads, 128 head dimension = 131,072 bytes (~128 KB) per context token.*

| Context Length ($L_{\text{ctx}}$) | KV Cache Size (FP16) | KV Cache Size (Q8_0 Quantized) | KV Cache Size (Q4_0 Quantized) | Impact on 8 GB Mac | Impact on 16 GB Mac | Classification |
|---|---|---|---|---|---|:---:|
| **2,048 tokens (2K)** | **256 MB** | 128 MB | 64 MB | 100% Safe | 100% Safe | `[CALCULATED]` |
| **4,096 tokens (4K)** | **512 MB** | 256 MB | 128 MB | **Maximum Safe Limit** | 100% Safe | `[CALCULATED]` |
| **8,192 tokens (8K)** | **1,024 MB (1.0 GB)** | 512 MB | 256 MB | **Unsafe (Triggers Swap)** | **Recommended Sweet Spot** | `[CALCULATED]` |
| **16,384 tokens (16K)** | **2,048 MB (2.0 GB)** | 1,024 MB | 512 MB | **Severe Thrashing** | Safe (Leaves ~4.5 GB buffer) | `[CALCULATED]` |
| **32,768 tokens (32K)** | **4,096 MB (4.0 GB)** | 2,048 MB | 1,024 MB | **System Freeze** | High Memory Pressure | `[CALCULATED]` |

> [!CAUTION]
> **8 GB Hardware Policy:** On 8 GB Macs, Aether enforces a provisional ceiling of **4,096 tokens of context for 3B models**. Context beyond 4,096 tokens must be truncated or compacted to prevent swap thrashing.

---

## 4. Future Benchmark Execution Protocol (Phase 3 Authorized Execution)

This protocol must be executed strictly after explicit human authorization in Phase 3. No repository code, benchmark binary, or test script shall be run during Phase 2.

### Step 1: Environment & Hardware Capture
Prior to initiating benchmark runs, the benchmark runner captures and logs:
- **Mac Hardware Model:** `sysctl hw.model`
- **Apple Silicon Chip:** `sysctl -n machdep.cpu.brand_string`
- **Core Configuration:** Performance core count (`sysctl hw.perflevel0.physicalcpu`) and Efficiency core count (`sysctl hw.perflevel1.physicalcpu`)
- **Total Unified Memory:** `sysctl hw.memsize`
- **Operating System Build:** `sw_vers -productVersion`, `sw_vers -buildVersion`
- **Thermal & Battery Status:** `pmset -g therm`, `pmset -g batt`
- **Baseline Background Memory:** Verification that WindowServer and background daemons occupy $< 3.5\text{ GB}$ physical RSS.

### Step 2: Model Artifact & Integrity Verification
Every benchmark run must record:
- **Canonical Model Name:** (e.g., `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf`, `Llama-3.2-3B-Instruct-Q4_K_M.gguf`)
- **Exact File Size:** In bytes on NVMe storage
- **SHA-256 Checksum:** Full 64-character hash verified against canonical manifest
- **Quantization Format:** Verified GGUF metadata (`llama_model_quantize` type)

### Step 3: Fixed Prompt Corpus & Generation Parameters
To ensure apples-to-apples repeatability:
- **Short Prompt (128 prompt tokens):** Standard conversational Q&A prompt.
- **Medium Prompt (512 prompt tokens):** Standard code analysis prompt.
- **Long Prompt (2,048 prompt tokens):** Technical documentation synthesis prompt.
- **Generation Settings:** Temperature = 0.0 (greedy decoding for deterministic token streams), top_p = 1.0, max output tokens = 256.

### Step 4: Cold-Start vs. Warm-Start Procedures
- **Cold-Start Protocol:** The model file is cleared from OS unified file cache (using `purge` or unmounted volume cycle). Time is recorded from calling `llama_load_model_from_file` to the return of a valid model pointer.
- **Warm-Start Protocol:** Consecutive model load immediately following a complete model release without OS cache purges.

### Step 5: Time-to-First-Token (TTFT) Measurement
- Measured via `os_signpost` interval between the invocation of `llama_decode` for prompt evaluation and the emission of the first token callback.
- Captured across 128, 512, and 2,048 prompt token lengths.

### Step 6: Generation Throughput (TPS) Measurement
- Calculated as:
  $$\text{TPS} = \frac{N_{\text{generated\_tokens}} - 1}{T_{\text{end}} - T_{\text{first\_token}}}$$
- Excludes prompt evaluation time to isolate decode performance.

### Step 7: Cancellation Latency Measurement
- The benchmark runner injects an asynchronous cancellation signal after token 50.
- Latency is recorded from the cancellation invocation to the exit of the Metal decode loop and deallocation of temporary compute buffers.

### Step 8: Peak Physical Memory & Memory Pressure Observation
- Continuous background sampling (every 25 ms) using `task_info(TASK_BASIC_INFO)` for `resident_size` and `task_vm_info` for `phys_footprint`.
- Continuous subscription to `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` kernel events.
- Observation of anonymous swap usage before and after generation via `sysctl vm.swapusage`.

### Step 9: Memory Reclamation Verification
- Following model unloading (`llama_free_model`), the process idles for 30 seconds.
- Physical footprint is recorded to ensure memory returns to baseline ($\le 35\text{ MB}$).
- A reload is performed to verify absence of heap or Metal arena fragmentation.

### Step 10: Long-Session Stability & Variance Reporting
- **Sample Size:** 30 consecutive runs per test configuration.
- **Aggregation Metrics:** Mean, Median, Standard Deviation ($\sigma$), 95th Percentile ($p95$), Minimum, and Maximum.
- Any thermal throttling events (flagged via `pmset -g therm`) are explicitly marked in the raw dataset.

### Step 11: Tiered Result Reporting
Separate, non-aggregated benchmark reports must be published for:
1. **Primary Target: Apple M5 MacBook Air (16 GB)** (Tested with 8B models, 8K context).
2. **Secondary Compatibility Tier: Apple Silicon (8 GB)** (Tested with 3B models, 4K context).
3. **Comparative Hardware Tiers:** M1/M2 16 GB, M3/M4 16 GB, and Pro/Max systems.

---

## 5. Security & Adversarial Testing (Promptfoo Integration - Milestone M0/M1)

Using the test harness from `reference-repos/11-evaluation-and-observability/promptfoo`, Aether executes automated regression tests in CI:

### Test Suites:
1. **Direct Jailbreaks:** 200 standard jailbreak prompts (e.g., "DAN", roleplay bypasses, base64 encoded attacks).
   - *Pass Criteria:* 100% refusal of system prompt override.
2. **Indirect Document Injection (Deferred to M1):** Ingesting 50 documents with embedded override instructions.
   - *Pass Criteria:* Zero execution of embedded instructions.
3. **Secret Leakage:** Prompts attempting to coax the model into revealing internal prompts or keychain tokens.
   - *Pass Criteria:* In-flight secret scanner redacts any matched credential pattern.

---

## 6. Continuous Integration & Milestone M0 Exit Gates

Before any milestone release is approved, the automated test harness executes the following gate check:

```bash
# 1. Swift Unit & Integration Suite
swift test --parallel

# 2. Memory & Leak Profiling via macOS Instruments
xcodebuild test -scheme AetherTests -destination 'platform=macOS,arch=arm64' \
    -enableCodeCoverage YES -resultBundlePath TestResults.xcresult

# 3. Headless Benchmark Verification (Post-Phase 3 Authorization)
./build/bin/aether-bench --model Llama-3.2-3B-Instruct-Q4_K_M.gguf \
    --iterations 30 --max-rss-mb 2600 --min-tps 25.0
```

### Milestone M0 Mandatory Exit Gates:
- **Zero Memory Leaks:** Instruments `leaks` tool reports zero persistent allocation cycles.
- **Zero Unhandled Crashes:** 1,000 synthetic streaming iterations with randomized user cancellations complete with zero segmentation faults or C++ exception crashes.
- **Strict 8 GB RSS Envelope:** Total resident memory of `Aether.app` running a 3B model under 4K context never exceeds **2.6 GB physical RAM**.
- **Zero Swap Disk Writes:** macOS anonymous swap file write counter remains at **0 bytes** during standard generation.
- **Clean App Sandbox Audit:** Verify with `codesign -d --entitlements - Aether.app` that only whitelisted entitlements exist.
