# AETHER × LANGGRAPH DEPENDENCY MANIFEST
## Production Lockfile & Open-Source License Audit

**Environment:** Python 3.11.17 (`aarch64-apple-darwin`)  
**Package Manager:** uv / pip  
**Virtual Environment Path:** `Aether/Resources/Sidecars/MultiAgent/.venv`  
**Lockfile:** `Aether/Resources/Sidecars/MultiAgent/requirements.lock.txt`  
**Date:** November 11, 2026  

---

## 1. Primary Orchestration Dependencies

| Package | Version | License | Primary Purpose |
| :--- | :--- | :--- | :--- |
| **`langgraph`** | `1.2.20` | MIT | Graph-based multi-agent state orchestration, conditional branching, and checkpointing |
| **`langgraph-checkpoint`** | `4.3.1` | MIT | State persistence, checkpoint interfaces, and workflow resumption |
| **`langgraph-prebuilt`** | `1.1.1` | MIT | Standard agent loop graphs and tool-calling node primitives |
| **`langgraph-sdk`** | `0.4.14` | MIT | Client interfaces and serialization schemas |
| **`langchain-core`** | `1.7.7` | MIT | Base message abstractions (`HumanMessage`, `AIMessage`, `ToolMessage`) and state schemas |
| **`agent-framework-core`** | `1.24.0` | MIT | Official Microsoft Agent Framework core orchestration engine |

---

## 2. Transitive Support Libraries

| Package | Version | License | Role in Runtime |
| :--- | :--- | :--- | :--- |
| `anyio` | `4.16.0` | MIT | High-level asynchronous concurrency and structured tasks |
| `certifi` | `2026.10.23` | MPL-2.0 | Mozilla CA bundle |
| `charset-normalizer` | `3.5.2` | MIT | Encoding detection |
| `distro` | `1.9.0` | Apache 2.0 | Linux/macOS OS distribution detection |
| `h11` | `0.16.0` | MIT | HTTP/1.1 protocol parser |
| `httpcore` | `1.0.9` | BSD-3-Clause | Minimal low-level HTTP transport |
| `httpcore2` | `2.16.0` | BSD-3-Clause | Extended HTTP core client |
| `httpx` | `0.28.1` | BSD-3-Clause | Asynchronous HTTP client |
| `httpx2` | `2.16.0` | BSD-3-Clause | Extended async HTTP client |
| `idna` | `3.20` | BSD-3-Clause | Internationalized Domain Names in Applications |
| `jsonpatch` | `1.46` | BSD-3-Clause | RFC 6902 JSON patch implementation |
| `jsonpointer` | `3.11` | BSD-3-Clause | RFC 6901 JSON pointer implementation |
| `langchain-protocol` | `0.0.21` | MIT | LangChain interoperability protocol |
| `langsmith` | `0.14.17` | MIT | Observability instrumentation (disabled for offline-first mode) |
| `msgspec` | `0.22.0` | BSD-3-Clause | Fast binary/JSON serialization |
| `opentelemetry-api` | `1.45.2` | Apache 2.0 | OpenTelemetry metrics and tracing API |
| `orjson` | `3.13.0` | Apache 2.0 / MIT | High-performance JSON serialization |
| `ormsgpack` | `1.13.1` | Apache 2.0 / MIT | High-performance MessagePack serialization |
| `packaging` | `26.3` | Apache 2.0 / BSD-2-Clause | Version parsing and dependency specifiers |
| `pydantic` | `2.14.3` | MIT | Data validation and typed schema enforcement |
| `pydantic-core` | `2.50.4` | MIT | Rust core for Pydantic v2 |
| `pygments` | `2.21.0` | BSD-2-Clause | Syntax highlighting |
| `pytest` | `9.2.0` | MIT | Testing harness |
| `pytest-asyncio` | `1.4.1.post1` | Apache 2.0 | Asyncio support for pytest |
| `python-dotenv` | `1.2.4` | BSD-3-Clause | Environment variable loading |
| `pyyaml` | `6.0.3` | MIT | YAML configuration parser |
| `regex` | `2026.11.7` | Apache 2.0 | Alternative regular expression engine |
| `requests` | `2.34.2` | Apache 2.0 | Synchronous HTTP library |
| `requests-toolbelt` | `1.0.0` | Apache 2.0 | Utilities for requests |
| `sniffio` | `1.3.1` | Apache 2.0 / MIT | Async library sniffer |
| `tenacity` | `9.2.1` | Apache 2.0 | Retry logic and backoff |
| `truststore` | `0.10.5` | MIT | macOS system keychain trust store integration |
| `typing-extensions` | `4.16.0` | Python Software Foundation | Backported typing features for Python 3.11 |
| `typing-inspection` | `0.4.5` | MIT | Runtime type introspection |
| `urllib3` | `2.8.0` | MIT | HTTP client library |
| `uuid-utils` | `0.19.0` | Apache 2.0 / MIT | High-performance UUID utilities |
| `websockets` | `17.4` | BSD-3-Clause | WebSocket protocol implementation |
| `xxhash` | `4.1.0` | BSD-2-Clause | Fast hashing algorithm |
| `zstandard` | `0.25.0` | BSD-3-Clause | Zstandard compression bindings |

---

## 3. Compliance and Security Validation

1. **Permissive Licensing:**
   All installed packages utilize permissive open-source licenses (MIT, Apache 2.0, BSD-2/3-Clause, PSF, or MPL-2.0). There are zero copyleft (GPL / AGPL) dependencies.
2. **Offline-First Compatibility:**
   Telemetry and remote tracing hooks in `langsmith` and `requests` are dormant. No remote cloud endpoints or tracking servers are queried during local execution.
3. **No Dual Python Runtime:**
   Both Microsoft Agent Framework and LangGraph run in the exact same Python 3.11 virtual environment under `Aether/Resources/Sidecars/MultiAgent/.venv`. No duplicate runtimes or sidecar processes are spawned.

