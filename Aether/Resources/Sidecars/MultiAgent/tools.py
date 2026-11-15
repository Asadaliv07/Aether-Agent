"""
Aether Multi-Agent Sidecar - Tool Bridge
Wraps Aether native tools and Model Context Protocol (MCP) tools into Microsoft Agent Framework FunctionTools.
Every tool execution request is forwarded to Swift for ToolSecurityGuard authorization and auditing.
"""

from typing import Any, Callable, Coroutine, Dict, List, Optional
import asyncio
import logging
from agent_framework import FunctionTool

logger = logging.getLogger("SwiftToolBridge")

class SwiftToolBridge:
    """
    Coordinates tool execution requests between Python agents and the Swift parent process.
    Never executes tools locally; all calls are routed to Swift through ToolSecurityGuard.
    """

    def __init__(
        self,
        dispatch_to_swift: Callable[[str, Dict[str, str], str, str], Coroutine[Any, Any, str]],
    ):
        self.dispatch_to_swift = dispatch_to_swift
        self._registered_tool_metadata: Dict[str, Dict[str, Any]] = {}

    def register_tool_metadata(self, tools: List[Dict[str, Any]]):
        """Caches metadata and schemas for available tools discovered from Swift."""
        for t in tools:
            name = t.get("name")
            if name:
                self._registered_tool_metadata[name] = t

    def get_registered_tools(self) -> List[Dict[str, Any]]:
        return list(self._registered_tool_metadata.values())

    def create_function_tool(
        self,
        tool_name: str,
        description: str,
        agent_role: str,
        task_id: str = "default_task",
    ) -> FunctionTool:
        """
        Creates a FunctionTool whose invocation routes through the Swift authorization boundary.
        """
        async def tool_runner(**kwargs: Any) -> str:
            str_params = {k: str(v) for k, v in kwargs.items()}
            logger.info(f"Agent '{agent_role}' requested tool '{tool_name}' with params: {str_params}")
            try:
                result = await self.dispatch_to_swift(tool_name, str_params, agent_role, task_id)
                return result
            except Exception as e:
                logger.error(f"Error executing tool '{tool_name}': {e}")
                return f"Tool execution failed: {str(e)}"

        return FunctionTool(
            name=tool_name,
            description=description,
            func=tool_runner,
        )

    def create_tools_for_agent(
        self,
        agent_role: str,
        available_tools: List[Dict[str, Any]],
        task_id: str = "default_task",
        allowed_tool_names: Optional[List[str]] = None,
    ) -> List[FunctionTool]:
        """
        Wraps a list of registered tool definitions into FunctionTools authorized for this agent.
        If allowed_tool_names is specified, restricts tools to only those allowed.
        """
        function_tools = []
        allowed_set = set(allowed_tool_names) if allowed_tool_names else None

        for tool_meta in available_tools:
            name = tool_meta.get("name", "")
            desc = tool_meta.get("description", "")
            if name:
                if allowed_set is not None and name not in allowed_set:
                    continue
                f_tool = self.create_function_tool(
                    tool_name=name,
                    description=desc,
                    agent_role=agent_role,
                    task_id=task_id,
                )
                function_tools.append(f_tool)
        return function_tools
