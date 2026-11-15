"""
Aether Multi-Agent Sidecar - Observability and OpenTelemetry Integration
Provides structured tracing, performance metrics, and privacy-preserving audit logging.
"""

from typing import Any, Dict, Optional
from contextlib import asynccontextmanager
import logging
import re
import time

try:
    from opentelemetry import trace
    from opentelemetry.trace import Status, StatusCode
    tracer = trace.get_tracer("aether.maf", "1.24.0")
    OTEL_AVAILABLE = True
except ImportError:
    tracer = None
    OTEL_AVAILABLE = False

logger = logging.getLogger("AetherObservability")

# Secret redaction patterns
SECRET_PATTERNS = [
    re.compile(r"sk-[A-Za-z0-9_\-]{20,}", re.IGNORECASE),
    re.compile(r"ghp_[A-Za-z0-9]{20,}", re.IGNORECASE),
    re.compile(r"Bearer\s+[A-Za-z0-9\-\._~\+\/]+=*", re.IGNORECASE),
    re.compile(r"(api[_-]?key|password|secret|token)\s*[:=]\s*['\"]?([A-Za-z0-9_\-\.]{8,})['\"]?", re.IGNORECASE),
]

def sanitize_string(text: str) -> str:
    """Removes sensitive credentials, API keys, and authorization tokens from text."""
    if not text:
        return ""
    sanitized = text
    for pattern in SECRET_PATTERNS:
        sanitized = pattern.sub("[REDACTED_SECRET]", sanitized)
    return sanitized

def sanitize_dict(data: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively sanitizes dictionary values."""
    clean: Dict[str, Any] = {}
    for k, v in data.items():
        k_lower = str(k).lower()
        if any(sec in k_lower for sec in ("key", "password", "secret", "token", "auth")):
            clean[k] = "[REDACTED]"
        elif isinstance(v, str):
            clean[k] = sanitize_string(v)
        elif isinstance(v, dict):
            clean[k] = sanitize_dict(v)
        elif isinstance(v, list):
            clean[k] = [sanitize_string(item) if isinstance(item, str) else item for item in v]
        else:
            clean[k] = v
    return clean

class ExecutionMetrics:
    """In-memory metrics tracker for multi-agent runs."""
    def __init__(self):
        self.total_invocations = 0
        self.successful_invocations = 0
        self.failed_invocations = 0
        self.total_latency_seconds = 0.0
        self.tool_calls_count = 0
        self.approval_requests_count = 0
        self.retries_count = 0

    def record_success(self, duration: float):
        self.total_invocations += 1
        self.successful_invocations += 1
        self.total_latency_seconds += duration

    def record_failure(self, duration: float):
        self.total_invocations += 1
        self.failed_invocations += 1
        self.total_latency_seconds += duration

    def to_dict(self) -> Dict[str, Any]:
        avg_latency = (self.total_latency_seconds / self.total_invocations) if self.total_invocations > 0 else 0.0
        return {
            "total_invocations": self.total_invocations,
            "successful_invocations": self.successful_invocations,
            "failed_invocations": self.failed_invocations,
            "average_latency_seconds": round(avg_latency, 4),
            "tool_calls_count": self.tool_calls_count,
            "approval_requests_count": self.approval_requests_count,
            "retries_count": self.retries_count,
        }

global_metrics = ExecutionMetrics()

@asynccontextmanager
async def trace_agent_execution(name: str, attributes: Optional[Dict[str, Any]] = None):
    """
    Context manager that starts an OpenTelemetry span and records execution duration and errors.
    """
    start_time = time.time()
    clean_attrs = sanitize_dict(attributes or {})

    if OTEL_AVAILABLE and tracer is not None:
        with tracer.start_as_current_span(name, attributes=clean_attrs) as span:
            try:
                yield span
                duration = time.time() - start_time
                global_metrics.record_success(duration)
                span.set_attribute("execution.duration_seconds", duration)
                span.set_status(Status(StatusCode.OK))
            except Exception as e:
                duration = time.time() - start_time
                global_metrics.record_failure(duration)
                span.set_attribute("execution.duration_seconds", duration)
                span.set_attribute("execution.error", str(e))
                span.set_status(Status(StatusCode.ERROR, str(e)))
                raise
    else:
        try:
            yield None
            duration = time.time() - start_time
            global_metrics.record_success(duration)
        except Exception as e:
            duration = time.time() - start_time
            global_metrics.record_failure(duration)
            raise

