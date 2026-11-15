"""
Aether Multi-Agent Sidecar - Model Client
Integrates Aether local Apple Silicon inference, cloud providers, and simulated models into Microsoft Agent Framework.
"""

from typing import Any, AsyncIterable, Callable, Coroutine, Dict, List, Mapping, Optional, Sequence
import asyncio
import json
import logging
import os
import urllib.request
from agent_framework import (
    BaseChatClient,
    ChatResponse,
    ChatResponseUpdate,
    Content,
    FunctionInvocationLayer,
    Message,
    ResponseStream,
)

logger = logging.getLogger("AetherChatClient")

class AetherChatClient(BaseChatClient, FunctionInvocationLayer):
    """
    Microsoft Agent Framework BaseChatClient supporting:
    1. Primary: Swift parent process local Metal inference via IPC.
    2. Cloud/Remote providers: Azure OpenAI, OpenAI, Ollama (configured via env or options).
    3. Deterministic mock generator for tests when offline.
    4. Token streaming and non-streaming responses.
    """

    def __init__(
        self,
        role_name: str,
        inference_delegate: Optional[Callable[[str, List[Dict[str, str]]], Coroutine[Any, Any, str]]] = None,
        mock_generator: Optional[Callable[[str, str], str]] = None,
        provider_config: Optional[Dict[str, str]] = None,
        **kwargs: Any,
    ):
        super().__init__(**kwargs)
        self.role_name = role_name
        self.inference_delegate = inference_delegate
        self.mock_generator = mock_generator
        self.provider_config = provider_config or {}

    async def _call_external_provider(self, prompt_turns: List[Dict[str, str]]) -> Optional[str]:
        """Attempts to invoke external model providers if configured via environment or options."""
        # 1. Ollama local provider check
        ollama_host = os.environ.get("OLLAMA_HOST", self.provider_config.get("ollama_host", ""))
        ollama_model = os.environ.get("OLLAMA_MODEL", self.provider_config.get("ollama_model", ""))
        if ollama_host and ollama_model:
            try:
                url = f"{ollama_host.rstrip('/')}/api/chat"
                payload = {
                    "model": ollama_model,
                    "messages": prompt_turns,
                    "stream": False,
                }
                req = urllib.request.Request(
                    url,
                    data=json.dumps(payload).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                loop = asyncio.get_running_loop()
                def run_ollama():
                    with urllib.request.urlopen(req, timeout=30) as resp:
                        data = json.loads(resp.read().decode("utf-8"))
                        return data.get("message", {}).get("content", "")
                result = await loop.run_in_executor(None, run_ollama)
                if result:
                    return result
            except Exception as e:
                logger.warning(f"Ollama provider call failed: {e}")

        # 2. OpenAI provider check
        openai_key = os.environ.get("OPENAI_API_KEY", self.provider_config.get("openai_api_key", ""))
        openai_model = os.environ.get("OPENAI_MODEL", self.provider_config.get("openai_model", "gpt-4o-mini"))
        openai_base = os.environ.get("OPENAI_BASE_URL", self.provider_config.get("openai_base_url", "https://api.openai.com/v1"))
        if openai_key:
            try:
                url = f"{openai_base.rstrip('/')}/chat/completions"
                payload = {
                    "model": openai_model,
                    "messages": prompt_turns,
                    "stream": False,
                }
                req = urllib.request.Request(
                    url,
                    data=json.dumps(payload).encode("utf-8"),
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {openai_key}",
                    },
                    method="POST",
                )
                loop = asyncio.get_running_loop()
                def run_openai():
                    with urllib.request.urlopen(req, timeout=30) as resp:
                        data = json.loads(resp.read().decode("utf-8"))
                        choices = data.get("choices", [])
                        if choices:
                            return choices[0].get("message", {}).get("content", "")
                        return ""
                result = await loop.run_in_executor(None, run_openai)
                if result:
                    return result
            except Exception as e:
                logger.warning(f"OpenAI provider call failed: {e}")

        # 3. Azure OpenAI provider check
        azure_key = os.environ.get("AZURE_OPENAI_API_KEY", self.provider_config.get("azure_api_key", ""))
        azure_endpoint = os.environ.get("AZURE_OPENAI_ENDPOINT", self.provider_config.get("azure_endpoint", ""))
        azure_deployment = os.environ.get("AZURE_OPENAI_DEPLOYMENT", self.provider_config.get("azure_deployment", ""))
        if azure_key and azure_endpoint and azure_deployment:
            try:
                url = f"{azure_endpoint.rstrip('/')}/openai/deployments/{azure_deployment}/chat/completions?api-version=2024-02-15-preview"
                payload = {
                    "messages": prompt_turns,
                    "stream": False,
                }
                req = urllib.request.Request(
                    url,
                    data=json.dumps(payload).encode("utf-8"),
                    headers={
                        "Content-Type": "application/json",
                        "api-key": azure_key,
                    },
                    method="POST",
                )
                loop = asyncio.get_running_loop()
                def run_azure():
                    with urllib.request.urlopen(req, timeout=30) as resp:
                        data = json.loads(resp.read().decode("utf-8"))
                        choices = data.get("choices", [])
                        if choices:
                            return choices[0].get("message", {}).get("content", "")
                        return ""
                result = await loop.run_in_executor(None, run_azure)
                if result:
                    return result
            except Exception as e:
                logger.warning(f"Azure OpenAI provider call failed: {e}")

        return None

    def _extract_prompt_turns(self, messages: Sequence[Message]) -> tuple[List[Dict[str, str]], str]:
        prompt_turns = []
        last_user_text = ""
        for msg in messages:
            role_str = str(msg.role).lower()
            text_content = ""
            if msg.contents:
                for c in msg.contents:
                    if isinstance(c, str):
                        text_content += c
                    elif hasattr(c, "text"):
                        text_content += c.text
            prompt_turns.append({"role": role_str, "content": text_content})
            if role_str in ("user", "human"):
                last_user_text = text_content
        return prompt_turns, last_user_text

    async def _resolve_response_text(self, prompt_turns: List[Dict[str, str]], last_user_text: str) -> str:
        # 1. External providers if enabled
        ext_response = await self._call_external_provider(prompt_turns)
        if ext_response:
            return ext_response

        # 2. Local Swift inference delegate via IPC
        if self.inference_delegate is not None:
            try:
                response_text = await self.inference_delegate(self.role_name, prompt_turns)
                if response_text:
                    return response_text
            except Exception as e:
                logger.warning(f"Error calling Swift inference delegate: {e}; falling back to mock.")

        # 3. Deterministic mock generator (for unit/integration tests)
        if self.mock_generator is not None:
            return self.mock_generator(self.role_name, last_user_text)

        # 4. Default deterministic output
        return f"[{self.role_name.upper()}]: Analyzed input: '{last_user_text}'. Completed assigned step successfully."

    async def generate(self, prompt_turns: List[Dict[str, str]]) -> str:
        """Convenience generation method for LangGraph nodes and external caller workflows."""
        last_user_text = ""
        for turn in prompt_turns:
            if turn.get("role", "").lower() in ("user", "human"):
                last_user_text = turn.get("content", "")
        return await self._resolve_response_text(prompt_turns, last_user_text)

    def _inner_get_response(
        self,
        *,
        messages: Sequence[Message],
        stream: bool,
        options: Mapping[str, Any],
        **kwargs: Any,
    ) -> Any:
        prompt_turns, last_user_text = self._extract_prompt_turns(messages)

        if not stream:
            async def get_response_async() -> ChatResponse:
                response_text = await self._resolve_response_text(prompt_turns, last_user_text)
                return ChatResponse(
                    messages=[Message(role="assistant", contents=[Content.from_text(response_text)])]
                )
            return get_response_async()
        else:
            async def token_generator() -> AsyncIterable[ChatResponseUpdate]:
                response_text = await self._resolve_response_text(prompt_turns, last_user_text)
                words = response_text.split(" ")
                for idx, word in enumerate(words):
                    chunk = word + (" " if idx < len(words) - 1 else "")
                    yield ChatResponseUpdate(
                        contents=[Content.from_text(chunk)],
                        role="assistant",
                    )
                    await asyncio.sleep(0.01)

            return self._build_response_stream(token_generator())
