"""
Aether Multi-Agent Sidecar - Middleware Pipeline
Implements official Microsoft Agent Framework middleware for security, policy enforcement,
prompt-injection protection, and execution auditing.
"""

from typing import Any, Callable, Coroutine, Dict, List, Optional
import logging
import re
from agent_framework import (
    AgentContext,
    AgentMiddleware,
    ChatContext,
    ChatMiddleware,
    FunctionInvocationContext,
    FunctionMiddleware,
    Message,
)
from observability import global_metrics, sanitize_string

logger = logging.getLogger("AetherMiddleware")

# High-risk prompt injection keywords and evasion patterns
PROMPT_INJECTION_PATTERNS = [
    re.compile(r"ignore\s+(all\s+)?(previous|prior|above)\s+instructions", re.IGNORECASE),
    re.compile(r"(disregard|forget)\s+(all\s+)?(previous|system)\s+rules", re.IGNORECASE),
    re.compile(r"you\s+are\s+now\s+in\s+developer\s+mode", re.IGNORECASE),
    re.compile(r"you\s+are\s+now\s+in\s+bypass\s+mode", re.IGNORECASE),
    re.compile(r"system\s+(prompt\s+)?override\s*:", re.IGNORECASE),
    re.compile(r"bypass\s+all\s+(security|safety|restrictions|checks)", re.IGNORECASE),
    re.compile(r"<\s*/?system_prompt_override\s*>", re.IGNORECASE),
]

class PromptInjectionScreeningMiddleware(ChatMiddleware):
    """
    Inspects messages for known prompt-injection and jailbreak vectors.
    Fails closed if a malicious instruction override pattern is detected.
    """
    def __init__(self, fail_closed: bool = True):
        self.fail_closed = fail_closed

    def screen_text(self, text_content: str):
        """Screens text for prompt-injection attacks. Raises PermissionError or ValueError when found."""
        for pattern in PROMPT_INJECTION_PATTERNS:
            if pattern.search(text_content):
                matched = pattern.pattern
                logger.warning(f"Prompt injection pattern detected: '{matched}' in input.")
                if self.fail_closed:
                    raise PermissionError(f"Execution blocked: Potential prompt injection detected matching pattern '{matched}'.")

    async def process(self, context: ChatContext, call_next: Callable[[], Coroutine[Any, Any, None]]):
        for msg in context.messages:
            if str(msg.role).lower() in ("user", "human"):
                text_content = ""
                if msg.contents:
                    for c in msg.contents:
                        if isinstance(c, str):
                            text_content += c
                        elif hasattr(c, "text"):
                            text_content += c.text

                self.screen_text(text_content)

        await call_next()

class SecretScrubbingMiddleware(ChatMiddleware):
    """
    Inspects assistant output messages and scrubs credentials, API keys, and bearer tokens.
    """
    def scrub(self, text: str) -> str:
        """Helper to scrub secrets directly from a string."""
        return sanitize_string(text)

    async def process(self, context: ChatContext, call_next: Callable[[], Coroutine[Any, Any, None]]):
        await call_next()
        # After completion, sanitize output contents if present
        if hasattr(context, "response") and context.response and hasattr(context.response, "messages"):
            for resp_msg in context.response.messages:
                if resp_msg.contents:
                    cleaned_contents = []
                    for c in resp_msg.contents:
                        if isinstance(c, str):
                            cleaned_contents.append(self.scrub(c))
                        elif hasattr(c, "text"):
                            c.text = self.scrub(c.text)
                            cleaned_contents.append(c)
                        else:
                            cleaned_contents.append(c)
                    resp_msg.contents = cleaned_contents

class ToolExecutionGuardMiddleware(FunctionMiddleware):
    """
    Enforces security boundaries on tool arguments before dispatching to Swift.
    Blocks directory traversal strings ('..') and records tool execution telemetry.
    """
    def validate_arguments(self, func_name: str, args: Dict[str, Any]):
        """Validates tool parameters against path-traversal attacks."""
        for key, val in args.items():
            if isinstance(val, str) and ("path" in key.lower() or "file" in key.lower() or "dir" in key.lower()):
                if ".." in val or "%2e%2e" in val.lower():
                    logger.warning(f"Path traversal detected in argument '{key}': '{val}' for tool '{func_name}'.")
                    raise PermissionError(f"Security violation: Path traversal sequence '..' detected in parameter '{key}'.")

    async def process(self, context: FunctionInvocationContext, call_next: Callable[[], Coroutine[Any, Any, None]]):
        func_name = getattr(context.function, "name", "unknown")
        args = context.arguments or {}

        self.validate_arguments(func_name, args)

        global_metrics.tool_calls_count += 1
        await call_next()

class ExecutionBudgetMiddleware(AgentMiddleware):
    """
    Enforces maximum delegation step limits and retries to prevent runaway execution loops.
    """
    def __init__(self, max_retries: int = 2, max_steps: int = 25, timeout_seconds: float = 60.0):
        self.max_retries = max_retries
        self.max_steps = max_steps
        self.timeout_seconds = timeout_seconds
        self.current_steps = 0

    async def record_step(self):
        """Increments and checks step budget."""
        self.current_steps += 1
        if self.current_steps > self.max_steps:
            raise RuntimeError(f"Execution budget exceeded: step count {self.current_steps} > limit {self.max_steps}")

    async def process(self, context: AgentContext, call_next: Callable[[], Coroutine[Any, Any, None]]):
        attempt = 0
        while attempt <= self.max_retries:
            try:
                await call_next()
                break
            except Exception as e:
                attempt += 1
                global_metrics.retries_count += 1
                if attempt > self.max_retries:
                    logger.error(f"Agent execution exceeded max retries ({self.max_retries}): {e}")
                    raise
                logger.warning(f"Agent execution attempt {attempt} failed: {e}. Retrying...")
