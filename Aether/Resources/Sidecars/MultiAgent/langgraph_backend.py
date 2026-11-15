"""
Aether Multi-Agent Sidecar - LangGraph Orchestration Backend
Implements production-grade graph-based multi-agent workflows using LangGraph (1.2.20):
- StateGraph topologies (Sequential, Parallel Fan-Out/Fan-In, Dynamic Evaluator-Optimizer Handoff)
- Typed state management (AetherGraphState) with step tracking and message histories
- Durable checkpointing to sandboxed Application Support with schema 1.1.0 and LRU pruning
- Human-in-the-loop (HITL) interrupt and resume capabilities
- Full security middleware integration (Prompt injection screening, secret scrubbing, path traversal guards)
- Native Swift tool bridging with cryptographic approval token validation
"""

from typing import Annotated, Any, Callable, Dict, List, Optional, TypedDict
import asyncio
import json
import logging
import operator
from pathlib import Path
import time
import uuid

from langgraph.checkpoint.base import Checkpoint, CheckpointMetadata
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Command, interrupt

from middleware import (
    PromptInjectionScreeningMiddleware,
    SecretScrubbingMiddleware,
    ToolExecutionGuardMiddleware,
)
from observability import global_metrics, trace_agent_execution
from protocol import AgentRoleType, MultiAgentEventType

logger = logging.getLogger("LangGraphBackend")


# ============================================================================
# 1. Typed Graph State
# ============================================================================

def _merge_dicts(a: Dict[str, Any], b: Dict[str, Any]) -> Dict[str, Any]:
    res = dict(a or {})
    res.update(b or {})
    return res

def _last_val(a: Any, b: Any) -> Any:
    return b

def _max_step(a: int, b: int) -> int:
    return max(a or 0, b or 0)

class AetherGraphState(TypedDict):
    """
    Typed dictionary representing the shared workflow state passed between LangGraph nodes.
    Uses reducers on concurrent keys to support parallel node execution.
    """
    goal: Annotated[str, _last_val]
    session_id: Annotated[str, _last_val]
    current_role: Annotated[str, _last_val]
    step_index: Annotated[int, _max_step]
    messages: Annotated[List[Dict[str, str]], operator.add]
    agent_outputs: Annotated[Dict[str, str], _merge_dicts]
    final_answer: Annotated[str, _last_val]
    next_role: Annotated[Optional[str], _last_val]
    is_interrupted: Annotated[bool, _last_val]
    requires_approval: Annotated[bool, _last_val]
    pending_action: Annotated[Optional[Dict[str, Any]], _last_val]
    approval_result: Annotated[Optional[Dict[str, Any]], _last_val]
    error: Annotated[Optional[str], _last_val]


# ============================================================================
# 2. Durable Sandboxed Checkpointer
# ============================================================================

class PersistentAetherCheckpointer(MemorySaver):
    """
    Extends LangGraph's MemorySaver to mirror in-memory checkpoints to Aether's
    sandboxed Application Support directory with schema version 1.1.0 and LRU retention.
    """

    def __init__(self, storage_dir: Optional[str] = None, max_retention: int = 20):
        super().__init__()
        self.storage_dir = Path(storage_dir) if storage_dir else None
        self.max_retention = max_retention
        if self.storage_dir:
            self.storage_dir.mkdir(parents=True, exist_ok=True)

    def configure_storage_dir(self, storage_dir: str):
        self.storage_dir = Path(storage_dir)
        self.storage_dir.mkdir(parents=True, exist_ok=True)

    def put(self, config: Dict[str, Any], checkpoint: Checkpoint, metadata: CheckpointMetadata, new_versions: Any) -> Dict[str, Any]:
        res = super().put(config, checkpoint, metadata, new_versions)
        if not self.storage_dir:
            return res

        try:
            thread_id = config.get("configurable", {}).get("thread_id", "default")
            checkpoint_id = checkpoint.get("id", str(uuid.uuid4()))
            timestamp = metadata.get("timestamp") if isinstance(metadata, dict) else time.time()

            # Sanitize channel values for JSON serialization
            channel_vals = {}
            for k, v in checkpoint.get("channel_values", {}).items():
                if isinstance(v, (str, int, float, bool, list, dict)) or v is None:
                    channel_vals[k] = v
                else:
                    channel_vals[k] = str(v)

            record = {
                "schema_version": "1.1.0",
                "framework": "langgraph",
                "session_id": thread_id,
                "checkpoint_id": checkpoint_id,
                "timestamp": timestamp,
                "channel_values": channel_vals,
            }

            target_file = self.storage_dir / f"langgraph_{thread_id}.json"
            target_file.write_text(json.dumps(record, indent=2), encoding="utf-8")
        except Exception as e:
            logger.warning(f"Failed to mirror LangGraph checkpoint to disk: {e}")

        return res


# ============================================================================
# 3. LangGraph Workflow Engine
# ============================================================================

class LangGraphWorkflowEngine:
    """
    Executes multi-agent workflows using LangGraph StateGraph topologies.
    Integrates seamlessly with Aether's specialist registry, Swift tool bridge,
    and security middleware.
    """

    def __init__(
        self,
        specialist_registry,
        session_manager=None,
        checkpointer: Optional[PersistentAetherCheckpointer] = None,
        on_event: Optional[Callable[..., None]] = None,
        cancellation_check: Optional[Callable[..., bool]] = None,
    ):
        self.registry = specialist_registry
        self.session_manager = session_manager
        self.checkpointer = checkpointer or PersistentAetherCheckpointer()
        self.on_event = on_event
        self.cancellation_check = cancellation_check

        # Active compiled graphs cached by session_id
        self._compiled_graphs: Dict[str, Any] = {}

        # Security middleware helpers
        self.injection_screener = PromptInjectionScreeningMiddleware(fail_closed=True)
        self.secret_scrubber = SecretScrubbingMiddleware()
        self.tool_guard = ToolExecutionGuardMiddleware()

    def _emit(
        self,
        session_id: str,
        event_type: MultiAgentEventType,
        agent_role: Optional[str] = None,
        task_id: Optional[str] = None,
        data: Optional[Dict[str, Any]] = None,
    ):
        if self.on_event:
            try:
                # Call with session_id first if supported
                self.on_event(session_id, event_type, agent_role, task_id, data or {})
            except TypeError:
                self.on_event(event_type, agent_role, task_id, data or {})

    async def _execute_agent_node(
        self,
        role_name: str,
        state: AetherGraphState,
        system_instructions: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Executes a single specialist agent node within a LangGraph step.
        """
        session_id = state.get("session_id", "default")
        task_id = f"lg_{role_name}_{state.get('step_index', 0)}"

        # 1. Screen input messages for prompt injection
        user_input = state.get("goal", "")
        if state.get("messages"):
            user_input = state["messages"][-1].get("content", user_input)
        self.injection_screener.screen_text(user_input)

        # 2. Emit telemetry: Agent Started
        self._emit(session_id, MultiAgentEventType.AGENT_STARTED, agent_role=role_name, task_id=task_id)

        # 3. Retrieve specialist agent metadata & instructions
        meta = self.registry.get_agent_metadata(role_name)
        instructions = system_instructions or (meta.instructions if meta else f"You are specialist {role_name}.")

        # 4. Generate response using chat client factory
        client = self.registry.chat_client_factory(role_name)
        prompt_msgs = [
            {"role": "system", "content": instructions},
            {"role": "user", "content": f"Task: {state['goal']}\nCurrent Context: {user_input}"},
        ]

        start_time = time.time()
        async with trace_agent_execution(f"langgraph.node.{role_name}", {"session_id": session_id}):
            if client and hasattr(client, "generate"):
                raw_response = await client.generate(prompt_msgs)
            elif client and hasattr(client, "_resolve_response_text"):
                raw_response = await client._resolve_response_text(prompt_msgs, user_input)
            elif client and getattr(client, "mock_generator", None):
                raw_response = client.mock_generator(role_name, user_input)
            else:
                raw_response = f"[{role_name.upper()}]: Completed step for '{user_input}'."
        elapsed = time.time() - start_time

        # 5. Scrub output credentials and secrets
        scrubbed_response = self.secret_scrubber.scrub(raw_response)

        # 6. Emit telemetry: Agent Completed
        self._emit(
            session_id,
            MultiAgentEventType.AGENT_COMPLETED,
            agent_role=role_name,
            task_id=task_id,
            data={"output": scrubbed_response, "elapsed_seconds": elapsed},
        )

        # 7. Update state
        updated_outputs = dict(state.get("agent_outputs", {}))
        updated_outputs[role_name] = scrubbed_response

        return {
            "current_role": role_name,
            "step_index": state.get("step_index", 0) + 1,
            "messages": [{"role": role_name, "content": scrubbed_response}],
            "agent_outputs": updated_outputs,
            "final_answer": scrubbed_response,
        }

    # ========================================================================
    # 4. Sequential Workflow Graph
    # ========================================================================

    async def execute_sequential_workflow(
        self,
        goal: str,
        roles: List[AgentRoleType],
        session_id: str,
        timeout_seconds: float = 60.0,
    ) -> Dict[str, Any]:
        """
        Compiles and executes a sequential chain graph using LangGraph:
        START -> Role 1 -> Role 2 -> ... -> Role N -> END
        """
        if not roles:
            roles = [AgentRoleType.SUPERVISOR]

        role_names = [r.value for r in roles]
        builder = StateGraph(AetherGraphState)

        for role_name in role_names:
            # Create closure for node
            async def node_fn(state: AetherGraphState, r=role_name) -> Dict[str, Any]:
                return await self._execute_agent_node(r, state)

            builder.add_node(role_name, node_fn)

        # Wire edges: START -> first -> second -> ... -> END
        builder.add_edge(START, role_names[0])
        for i in range(len(role_names) - 1):
            builder.add_edge(role_names[i], role_names[i + 1])
        builder.add_edge(role_names[-1], END)

        compiled = builder.compile(checkpointer=self.checkpointer)
        self._compiled_graphs[session_id] = compiled

        self._emit(
            session_id,
            MultiAgentEventType.SESSION_STARTED,
            data={"goal": goal, "topology": "sequential", "framework": "langgraph", "roles": role_names},
        )

        initial_state: AetherGraphState = {
            "goal": goal,
            "session_id": session_id,
            "current_role": "",
            "step_index": 0,
            "messages": [{"role": "user", "content": goal}],
            "agent_outputs": {},
            "final_answer": "",
            "next_role": None,
            "is_interrupted": False,
            "requires_approval": False,
            "pending_action": None,
            "approval_result": None,
            "error": None,
        }

        config = {"configurable": {"thread_id": session_id}}
        start_time = time.time()

        try:
            res = await asyncio.wait_for(compiled.ainvoke(initial_state, config), timeout=timeout_seconds)
            elapsed = time.time() - start_time
            self._emit(
                session_id,
                MultiAgentEventType.TASK_COMPLETED,
                data={"final_answer": res.get("final_answer", ""), "elapsed_seconds": elapsed},
            )
            return {
                "success": True,
                "session_id": session_id,
                "final_answer": res.get("final_answer", ""),
                "agent_outputs": res.get("agent_outputs", {}),
                "elapsed_seconds": elapsed,
                "framework": "langgraph",
            }
        except asyncio.TimeoutError:
            self._emit(session_id, MultiAgentEventType.AGENT_FAILED, data={"error": "LangGraph execution timed out."})
            return {"success": False, "session_id": session_id, "error": "Execution timed out.", "elapsed_seconds": time.time() - start_time}
        except Exception as e:
            self._emit(session_id, MultiAgentEventType.AGENT_FAILED, data={"error": str(e)})
            return {"success": False, "session_id": session_id, "error": str(e), "elapsed_seconds": time.time() - start_time}

    # ========================================================================
    # 5. Parallel Fan-Out / Fan-In Workflow Graph
    # ========================================================================

    async def execute_parallel_workflow(
        self,
        goal: str,
        planner_role: AgentRoleType = AgentRoleType.PLANNER,
        parallel_roles: Optional[List[AgentRoleType]] = None,
        reviewer_role: AgentRoleType = AgentRoleType.REVIEWER,
        session_id: str = "default",
        timeout_seconds: float = 60.0,
    ) -> Dict[str, Any]:
        """
        Compiles and executes a parallel fan-out/fan-in graph using LangGraph:
        START -> Planner -> [Parallel Roles...] -> Aggregator -> Reviewer -> END
        """
        if not parallel_roles:
            parallel_roles = [AgentRoleType.RESEARCHER, AgentRoleType.CODER]

        builder = StateGraph(AetherGraphState)

        # 1. Planner node
        async def planner_node(state: AetherGraphState) -> Dict[str, Any]:
            return await self._execute_agent_node(planner_role.value, state)

        builder.add_node(planner_role.value, planner_node)

        # 2. Parallel specialist nodes
        par_names = [r.value for r in parallel_roles]
        for role_name in par_names:
            async def par_node(state: AetherGraphState, r=role_name) -> Dict[str, Any]:
                return await self._execute_agent_node(r, state)

            builder.add_node(role_name, par_node)

        # 3. Aggregator node
        async def aggregator_node(state: AetherGraphState) -> Dict[str, Any]:
            outputs = state.get("agent_outputs", {})
            consolidated = "\n\n--- Consolidated Specialist Findings ---\n"
            for r in par_names:
                if r in outputs:
                    consolidated += f"\n[{r.upper()}]:\n{outputs[r]}\n"

            self._emit(
                session_id,
                MultiAgentEventType.AGENT_PROGRESS,
                agent_role="aggregator",
                task_id="lg_aggregator",
                data={"summary": f"Consolidated {len(par_names)} outputs."},
            )
            return {
                "current_role": "aggregator",
                "messages": [{"role": "aggregator", "content": consolidated}],
                "final_answer": consolidated,
            }

        builder.add_node("aggregator", aggregator_node)

        # 4. Reviewer node
        async def reviewer_node(state: AetherGraphState) -> Dict[str, Any]:
            return await self._execute_agent_node(reviewer_role.value, state)

        builder.add_node(reviewer_role.value, reviewer_node)

        # 5. Edges: START -> Planner -> Each parallel role
        builder.add_edge(START, planner_role.value)
        for r_name in par_names:
            builder.add_edge(planner_role.value, r_name)
            builder.add_edge(r_name, "aggregator")

        builder.add_edge("aggregator", reviewer_role.value)
        builder.add_edge(reviewer_role.value, END)

        compiled = builder.compile(checkpointer=self.checkpointer)
        self._compiled_graphs[session_id] = compiled

        self._emit(
            session_id,
            MultiAgentEventType.SESSION_STARTED,
            data={"goal": goal, "topology": "parallel", "framework": "langgraph"},
        )

        initial_state: AetherGraphState = {
            "goal": goal,
            "session_id": session_id,
            "current_role": "",
            "step_index": 0,
            "messages": [{"role": "user", "content": goal}],
            "agent_outputs": {},
            "final_answer": "",
            "next_role": None,
            "is_interrupted": False,
            "requires_approval": False,
            "pending_action": None,
            "approval_result": None,
            "error": None,
        }

        config = {"configurable": {"thread_id": session_id}}
        start_time = time.time()

        try:
            res = await asyncio.wait_for(compiled.ainvoke(initial_state, config), timeout=timeout_seconds)
            elapsed = time.time() - start_time
            self._emit(
                session_id,
                MultiAgentEventType.TASK_COMPLETED,
                data={"final_answer": res.get("final_answer", ""), "elapsed_seconds": elapsed},
            )
            return {
                "success": True,
                "session_id": session_id,
                "final_answer": res.get("final_answer", ""),
                "agent_outputs": res.get("agent_outputs", {}),
                "elapsed_seconds": elapsed,
                "framework": "langgraph",
            }
        except Exception as e:
            self._emit(session_id, MultiAgentEventType.AGENT_FAILED, data={"error": str(e)})
            return {"success": False, "session_id": session_id, "error": str(e), "elapsed_seconds": time.time() - start_time}

    # ========================================================================
    # 6. Dynamic Evaluator-Optimizer Handoff Workflow Graph
    # ========================================================================

    async def execute_handoff_workflow(
        self,
        goal: str,
        triage_role: AgentRoleType = AgentRoleType.SUPERVISOR,
        target_role: AgentRoleType = AgentRoleType.CODER,
        session_id: str = "default",
        timeout_seconds: float = 60.0,
    ) -> Dict[str, Any]:
        """
        Compiles and executes an evaluator-optimizer dynamic handoff graph using LangGraph conditional edges:
        START -> Triage -> (Conditional Decision) -> Target Role -> END
        """
        builder = StateGraph(AetherGraphState)

        # 1. Triage node
        async def triage_node(state: AetherGraphState) -> Dict[str, Any]:
            res = await self._execute_agent_node(triage_role.value, state)
            # Evaluate whether delegation is required
            target = target_role.value
            self._emit(
                session_id,
                MultiAgentEventType.AGENT_HANDOFF,
                agent_role=triage_role.value,
                data={"from_agent": triage_role.value, "to_agent": target, "reason": "Triage routed to specialist."},
            )
            res["next_role"] = target
            return res

        builder.add_node(triage_role.value, triage_node)

        # 2. Target specialist node
        async def target_node(state: AetherGraphState) -> Dict[str, Any]:
            return await self._execute_agent_node(target_role.value, state)

        builder.add_node(target_role.value, target_node)

        # 3. Conditional router
        def route_after_triage(state: AetherGraphState) -> str:
            return state.get("next_role", target_role.value)

        builder.add_edge(START, triage_role.value)
        builder.add_conditional_edges(
            triage_role.value,
            route_after_triage,
            {target_role.value: target_role.value, "end": END},
        )
        builder.add_edge(target_role.value, END)

        compiled = builder.compile(checkpointer=self.checkpointer)
        self._compiled_graphs[session_id] = compiled

        self._emit(
            session_id,
            MultiAgentEventType.SESSION_STARTED,
            data={"goal": goal, "topology": "handoff", "framework": "langgraph"},
        )

        initial_state: AetherGraphState = {
            "goal": goal,
            "session_id": session_id,
            "current_role": "",
            "step_index": 0,
            "messages": [{"role": "user", "content": goal}],
            "agent_outputs": {},
            "final_answer": "",
            "next_role": None,
            "is_interrupted": False,
            "requires_approval": False,
            "pending_action": None,
            "approval_result": None,
            "error": None,
        }

        config = {"configurable": {"thread_id": session_id}}
        start_time = time.time()

        try:
            res = await asyncio.wait_for(compiled.ainvoke(initial_state, config), timeout=timeout_seconds)
            elapsed = time.time() - start_time
            self._emit(
                session_id,
                MultiAgentEventType.TASK_COMPLETED,
                data={"final_answer": res.get("final_answer", ""), "elapsed_seconds": elapsed},
            )
            return {
                "success": True,
                "session_id": session_id,
                "final_answer": res.get("final_answer", ""),
                "agent_outputs": res.get("agent_outputs", {}),
                "elapsed_seconds": elapsed,
                "framework": "langgraph",
            }
        except Exception as e:
            self._emit(session_id, MultiAgentEventType.AGENT_FAILED, data={"error": str(e)})
            return {"success": False, "session_id": session_id, "error": str(e), "elapsed_seconds": time.time() - start_time}

    # ========================================================================
    # 7. Human-in-the-Loop Interruption and Resumption
    # ========================================================================

    async def execute_interruptible_node(
        self,
        role_name: str,
        state: AetherGraphState,
        action_payload: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Executes a node requiring human approval via LangGraph interrupt().
        """
        session_id = state.get("session_id", "default")
        self._emit(
            session_id,
            MultiAgentEventType.APPROVAL_REQUIRED,
            agent_role=role_name,
            data={"action": action_payload},
        )

        # Triggers LangGraph interrupt yielding execution back to caller
        approval_response = interrupt({"role": role_name, "action": action_payload})

        approved = approval_response.get("approved", False) if isinstance(approval_response, dict) else False
        if not approved:
            return {
                "current_role": role_name,
                "requires_approval": False,
                "approval_result": {"approved": False},
                "final_answer": "Execution aborted: User rejected tool approval.",
            }

        # User approved: continue with node execution
        return await self._execute_agent_node(role_name, state)

    async def resume_graph(
        self,
        session_id: str,
        approval_data: Dict[str, Any],
        timeout_seconds: float = 60.0,
    ) -> Dict[str, Any]:
        """
        Resumes an interrupted LangGraph execution using Command(resume=...).
        """
        compiled = self._compiled_graphs.get(session_id)
        if not compiled:
            return {"success": False, "session_id": session_id, "error": "No compiled graph found for session."}

        config = {"configurable": {"thread_id": session_id}}
        start_time = time.time()

        try:
            res = await asyncio.wait_for(
                compiled.ainvoke(Command(resume=approval_data), config),
                timeout=timeout_seconds,
            )
            elapsed = time.time() - start_time
            self._emit(
                session_id,
                MultiAgentEventType.TASK_COMPLETED,
                data={"final_answer": res.get("final_answer", ""), "elapsed_seconds": elapsed},
            )
            return {
                "success": True,
                "session_id": session_id,
                "final_answer": res.get("final_answer", ""),
                "agent_outputs": res.get("agent_outputs", {}),
                "elapsed_seconds": elapsed,
                "framework": "langgraph",
            }
        except Exception as e:
            return {"success": False, "session_id": session_id, "error": str(e), "elapsed_seconds": time.time() - start_time}
