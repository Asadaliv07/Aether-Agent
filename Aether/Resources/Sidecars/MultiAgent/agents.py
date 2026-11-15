"""
Aether Multi-Agent Sidecar - Specialist Agents & Agent Registry
Defines the core specialist roles and provides a centralized, extensible Agent Registry
under the Microsoft Agent Framework.
"""

from typing import Any, Dict, List, Optional
import time
from agent_framework import Agent, FunctionTool
from middleware import (
    ExecutionBudgetMiddleware,
    PromptInjectionScreeningMiddleware,
    SecretScrubbingMiddleware,
)
from model_client import AetherChatClient
from protocol import AgentMetadata, AgentRoleType

SUPERVISOR_INSTRUCTIONS = """You are the Aether Multi-Agent Supervisor.
Your responsibility is to analyze user tasks, determine whether to delegate to specialist agents,
coordinate their execution, synthesize their outputs, and produce a unified, comprehensive final answer.
Avoid unnecessary delegation for trivial queries.
When delegating, decompose the task into distinct steps for Planner, Researcher, Coder, Analyst, and Reviewer.
"""

PLANNER_INSTRUCTIONS = """You are the Aether Specialist Planner.
Your role is to decompose complex goals into discrete, dependency-ordered subtasks.
Identify dependencies between tasks, mark which tasks can run in parallel, and define clear completion criteria.
Always output a structured, step-by-step execution plan.
"""

RESEARCHER_INSTRUCTIONS = """You are the Aether Specialist Researcher.
Your role is to gather information, inspect documentation, search files, and discover relevant context.
Cite evidence, identify ambiguities, and return structured, factual findings without speculation.
"""

CODER_INSTRUCTIONS = """You are the Aether Specialist Software Engineer.
Your role is to inspect source code, propose or perform authorized modifications, run tests, and report changes.
Never bypass Swift authorization. All file and terminal operations must use authorized tools.
"""

ANALYST_INSTRUCTIONS = """You are the Aether Specialist Analyst.
Your role is to analyze research and implementation results, compare alternatives, identify contradictions,
and evaluate technical trade-offs. Provide evidence-based conclusions.
"""

REVIEWER_INSTRUCTIONS = """You are the Aether Specialist Quality Reviewer.
Your role is to verify that the generated results satisfy the user's requirements and quality standards.
Check task completion criteria, flag unsupported claims or bugs, and approve or request revision.
"""

ASSISTANT_INSTRUCTIONS = """You are the Aether Intelligent Assistant.
Your role is to help the user directly with questions, explanations, and lightweight tasks
without requiring multi-agent delegation or complex workflow overhead.
"""

BUILTIN_AGENTS: Dict[str, Dict[str, Any]] = {
    "supervisor": {
        "id": "builtin-supervisor",
        "name": "Supervisor",
        "role": AgentRoleType.SUPERVISOR,
        "description": "Orchestrates multi-agent workflows, task decomposition, and output synthesis.",
        "instructions": SUPERVISOR_INSTRUCTIONS,
        "capabilities": ["planning", "orchestration", "synthesis"],
        "version": "1.0.0",
        "allowed_tools": ["system_info"],
    },
    "planner": {
        "id": "builtin-planner",
        "name": "Planner",
        "role": AgentRoleType.PLANNER,
        "description": "Decomposes complex goals into dependency-ordered subtasks and execution plans.",
        "instructions": PLANNER_INSTRUCTIONS,
        "capabilities": ["planning", "decomposition", "scheduling"],
        "version": "1.0.0",
        "allowed_tools": ["calculator", "system_info"],
    },
    "researcher": {
        "id": "builtin-researcher",
        "name": "Researcher",
        "role": AgentRoleType.RESEARCHER,
        "description": "Gathers domain context, inspects files, and produces evidence-backed summaries.",
        "instructions": RESEARCHER_INSTRUCTIONS,
        "capabilities": ["research", "file_inspection", "fact_checking"],
        "version": "1.0.0",
        "allowed_tools": ["sandboxed_file_reader", "document_text_extractor"],
    },
    "coder": {
        "id": "builtin-coder",
        "name": "Coder",
        "role": AgentRoleType.CODER,
        "description": "Specialized software engineer for code inspection, refactoring, and execution.",
        "instructions": CODER_INSTRUCTIONS,
        "capabilities": ["software_engineering", "code_generation", "refactoring"],
        "version": "1.0.0",
        "allowed_tools": ["sandboxed_file_reader", "calculator"],
    },
    "analyst": {
        "id": "builtin-analyst",
        "name": "Analyst",
        "role": AgentRoleType.ANALYST,
        "description": "Analyzes complex tradeoffs, benchmarks metrics, and resolves contradictions.",
        "instructions": ANALYST_INSTRUCTIONS,
        "capabilities": ["data_analysis", "tradeoff_evaluation", "metric_verification"],
        "version": "1.0.0",
        "allowed_tools": ["calculator"],
    },
    "reviewer": {
        "id": "builtin-reviewer",
        "name": "Reviewer",
        "role": AgentRoleType.REVIEWER,
        "description": "Audits generated solutions against requirements, acceptance criteria, and security.",
        "instructions": REVIEWER_INSTRUCTIONS,
        "capabilities": ["code_review", "security_audit", "acceptance_testing"],
        "version": "1.0.0",
        "allowed_tools": ["sandboxed_file_reader"],
    },
    "assistant": {
        "id": "builtin-assistant",
        "name": "Assistant",
        "role": AgentRoleType.ASSISTANT,
        "description": "General-purpose interactive assistant for direct responses and single-turn queries.",
        "instructions": ASSISTANT_INSTRUCTIONS,
        "capabilities": ["conversation", "general_assistance", "qa"],
        "version": "1.0.0",
        "allowed_tools": ["calculator", "system_info", "sandboxed_file_reader"],
    },
}

class SpecialistRegistry:
    """
    Centralized Agent Registry managing built-in specialist roles, dynamic custom agents,
    versioning, lifecycle states (active/inactive), and capability definitions.
    """

    def __init__(self, chat_client_factory, tool_bridge=None):
        self.chat_client_factory = chat_client_factory
        self.tool_bridge = tool_bridge
        self.agents: Dict[str, AgentMetadata] = {}

        # Initialize registry with built-in specialists
        for key, meta in BUILTIN_AGENTS.items():
            self.agents[key] = AgentMetadata(
                id=meta["id"],
                name=meta["name"],
                role=meta["role"],
                description=meta["description"],
                instructions=meta["instructions"],
                version=meta["version"],
                is_active=True,
                capabilities=meta["capabilities"],
                allowed_tools=meta["allowed_tools"],
            )

    def register_custom_role(
        self,
        name: str,
        instructions: str,
        description: Optional[str] = None,
        role: AgentRoleType = AgentRoleType.CUSTOM,
        capabilities: Optional[List[str]] = None,
        allowed_tools: Optional[List[str]] = None,
        model_id: Optional[str] = None,
        version: str = "1.0.0",
    ) -> AgentMetadata:
        """
        Registers a dynamic custom specialist role with defined capability boundaries.
        """
        key = name.lower()
        metadata = AgentMetadata(
            id=f"custom-{key}",
            name=name,
            role=role,
            description=description or f"Custom specialist agent: {name}",
            instructions=instructions,
            version=version,
            is_active=True,
            capabilities=capabilities or ["custom"],
            allowed_tools=allowed_tools or [],
            model_id=model_id,
            created_at=time.time(),
            updated_at=time.time(),
        )
        self.agents[key] = metadata
        return metadata

    def update_agent_status(self, key: str, is_active: bool) -> bool:
        """Activates or deactivates an agent."""
        k = key.lower()
        if k in self.agents:
            self.agents[k].is_active = is_active
            self.agents[k].updated_at = time.time()
            return True
        return False

    def delete_custom_agent(self, key: str) -> bool:
        """Deletes a custom agent from the registry (built-ins cannot be deleted)."""
        k = key.lower()
        if k in self.agents and k not in BUILTIN_AGENTS:
            del self.agents[k]
            return True
        return False

    def get_agent_metadata(self, key: str) -> Optional[AgentMetadata]:
        return self.agents.get(key.lower())

    def list_agents(
        self,
        role: Optional[str] = None,
        capability: Optional[str] = None,
        active_only: bool = False,
    ) -> List[AgentMetadata]:
        """Discovers agents matching query criteria."""
        results = []
        for meta in self.agents.values():
            if active_only and not meta.is_active:
                continue
            if role and meta.role.value != role.lower():
                continue
            if capability and capability.lower() not in [c.lower() for c in meta.capabilities]:
                continue
            results.append(meta)
        return results

    def create_agent(
        self,
        role: AgentRoleType | str,
        tools: Optional[List[FunctionTool]] = None,
        task_id: str = "default_task",
    ) -> Agent:
        """
        Instantiates a Microsoft Agent Framework Agent for the given role,
        attaching security and validation middleware automatically.
        """
        role_key = str(role).lower()
        meta = self.get_agent_metadata(role_key)

        if meta:
            instructions = meta.instructions
            name = meta.name
        else:
            instructions = f"You are a specialized Aether assistant for {role}."
            name = role_key

        client = self.chat_client_factory(role_name=name)
        agent_tools = tools or []

        # Configure standard MAF middleware for security and governance
        middleware_stack = [
            PromptInjectionScreeningMiddleware(fail_closed=True),
            SecretScrubbingMiddleware(),
            ExecutionBudgetMiddleware(max_retries=2),
        ]

        return Agent(
            client=client,
            name=name,
            instructions=instructions,
            tools=agent_tools if agent_tools else None,
            middleware=middleware_stack,
        )
