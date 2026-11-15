"""
Aether Multi-Agent Sidecar - Workflow Orchestration
Builds and executes multi-agent topologies using Microsoft Agent Framework's WorkflowBuilder,
Executors, and checkpointing mechanisms.
"""

from typing import Any, Callable, Dict, List, Optional
import asyncio
import logging
import time
from agent_framework import Agent, Executor, WorkflowBuilder, handler
from observability import trace_agent_execution
from protocol import AgentRoleType, MultiAgentEventType

logger = logging.getLogger("MultiAgentWorkflow")

class ResultAggregator(Executor):
    """
    Fan-in aggregation executor that consolidates outputs from concurrent specialist agents.
    """

    def __init__(self, id: str = "result_aggregator", on_event: Optional[Callable] = None):
        super().__init__(id=id)
        self.on_event = on_event

    @handler(input=list, output=str)
    async def aggregate(self, results: list, ctx) -> None:
        logger.info(f"Aggregating {len(results)} specialist outputs.")
        items = []
        for r in results:
            if hasattr(r, "agent_response") and hasattr(r.agent_response, "text"):
                items.append(r.agent_response.text)
            elif hasattr(r, "text"):
                items.append(r.text)
            elif isinstance(r, str):
                items.append(r)
            else:
                items.append(str(r))

        consolidated = "\n\n--- Consolidated Specialist Findings ---\n" + "\n\n".join(items)
        if self.on_event:
            self.on_event(
                MultiAgentEventType.AGENT_PROGRESS,
                agent_role="aggregator",
                task_id=self.id,
                data={"summary": f"Consolidated {len(results)} outputs.", "length": len(consolidated)},
            )
        await ctx.send_message(consolidated)

class WorkflowOrchestrator:
    """
    Constructs and executes multi-agent workflows matching user requirements.
    Supports sequential chains, concurrent fan-out/fan-in, agent handoffs,
    group collaboration, and checkpoint persistence.
    """

    def __init__(
        self,
        specialist_registry,
        session_manager=None,
        on_event: Optional[Callable[[MultiAgentEventType, Optional[str], Optional[str], Dict[str, Any]], None]] = None,
        cancellation_check: Optional[Callable[[], bool]] = None,
    ):
        self.registry = specialist_registry
        self.session_manager = session_manager
        self.on_event = on_event
        self.cancellation_check = cancellation_check

    def _emit(
        self,
        event_type: MultiAgentEventType,
        agent_role: Optional[str] = None,
        task_id: Optional[str] = None,
        data: Optional[Dict[str, Any]] = None,
    ):
        if self.on_event:
            self.on_event(event_type, agent_role, task_id, data or {})

    async def _save_step_checkpoint(self, session_id: str, step_index: int, active_agent: str, payload: Dict[str, Any]):
        if self.session_manager:
            chk = await self.session_manager.save_checkpoint(session_id, step_index, active_agent, payload)
            self._emit(
                MultiAgentEventType.CHECKPOINT_SAVED,
                agent_role=active_agent,
                task_id=f"step_{step_index}",
                data={"step_index": step_index, "timestamp": chk.timestamp},
            )

    async def execute_sequential_workflow(
        self,
        goal: str,
        roles: List[AgentRoleType],
        session_id: str,
        timeout_seconds: float = 60.0,
    ) -> Dict[str, Any]:
        """
        Executes a sequential chain of specialist agents (e.g. Planner -> Coder -> Reviewer).
        """
        if not roles:
            roles = [AgentRoleType.SUPERVISOR]

        agents = []
        for role in roles:
            agent = self.registry.create_agent(role=role, task_id=f"seq_{role.value}")
            agents.append(agent)

        builder = WorkflowBuilder(start_executor=agents[0])
        if len(agents) > 1:
            builder.add_chain(agents)
        workflow = builder.build()

        self._emit(
            MultiAgentEventType.SESSION_STARTED,
            data={"goal": goal, "topology": "sequential", "roles": [r.value for r in roles]},
        )

        start_time = time.time()
        for idx, role in enumerate(roles):
            if self.cancellation_check and self.cancellation_check():
                self._emit(MultiAgentEventType.SESSION_CANCELLED, data={"reason": "User cancelled session."})
                return {"success": False, "error": "Session cancelled by user."}

            task_id = f"task_{idx+1}"
            self._emit(MultiAgentEventType.AGENT_ASSIGNED, agent_role=role.value, task_id=task_id, data={"step": idx + 1})
            self._emit(MultiAgentEventType.AGENT_STARTED, agent_role=role.value, task_id=task_id)

        try:
            async with trace_agent_execution("maf.workflow.sequential", {"session_id": session_id, "roles_count": len(roles)}):
                workflow_task = asyncio.create_task(workflow.run(goal))
                while not workflow_task.done():
                    if self.cancellation_check and self.cancellation_check():
                        workflow_task.cancel()
                        self._emit(MultiAgentEventType.SESSION_CANCELLED, data={"reason": "Cancelled during execution."})
                        return {"success": False, "error": "Execution cancelled."}
                    await asyncio.sleep(0.05)

                result = await workflow_task
        except asyncio.CancelledError:
            self._emit(MultiAgentEventType.SESSION_CANCELLED, data={"reason": "Cancelled by task signal."})
            return {"success": False, "error": "Execution cancelled."}
        except Exception as e:
            self._emit(MultiAgentEventType.AGENT_FAILED, data={"error": str(e)})
            return {"success": False, "error": str(e)}

        outputs = result.get_outputs()
        final_text = ""
        if outputs:
            last_output = outputs[-1]
            final_text = getattr(last_output, "text", str(last_output))
        elif hasattr(result, "text"):
            final_text = result.text
        else:
            final_text = str(result)

        elapsed = time.time() - start_time
        await self._save_step_checkpoint(session_id, len(roles), roles[-1].value, {"final_answer": final_text})
        self._emit(MultiAgentEventType.TASK_COMPLETED, data={"elapsed_seconds": elapsed, "final_answer": final_text})

        return {
            "success": True,
            "final_answer": final_text,
            "elapsed_seconds": elapsed,
            "steps_completed": len(roles),
        }

    async def execute_parallel_workflow(
        self,
        goal: str,
        planner_role: AgentRoleType = AgentRoleType.PLANNER,
        parallel_roles: Optional[List[AgentRoleType]] = None,
        reviewer_role: AgentRoleType = AgentRoleType.REVIEWER,
        session_id: str = "default_session",
        timeout_seconds: float = 60.0,
    ) -> Dict[str, Any]:
        """
        Executes a parallel fan-out/fan-in workflow:
        Start Agent (Planner) -> Fan Out to Parallel Agents -> Fan In to Aggregator -> Reviewer.
        """
        if not parallel_roles:
            parallel_roles = [AgentRoleType.RESEARCHER, AgentRoleType.CODER]

        planner = self.registry.create_agent(role=planner_role, task_id="parallel_planner")
        parallel_agents = [
            self.registry.create_agent(role=r, task_id=f"parallel_{r.value}")
            for r in parallel_roles
        ]
        aggregator = ResultAggregator("parallel_aggregator", on_event=self._emit)
        reviewer = self.registry.create_agent(role=reviewer_role, task_id="parallel_reviewer")

        builder = WorkflowBuilder(start_executor=planner)
        builder.add_fan_out_edges(planner, parallel_agents)
        builder.add_fan_in_edges(parallel_agents, aggregator)
        builder.add_edge(aggregator, reviewer)
        workflow = builder.build()

        self._emit(
            MultiAgentEventType.SESSION_STARTED,
            data={
                "goal": goal,
                "topology": "fan_out_fan_in",
                "parallel_roles": [r.value for r in parallel_roles],
            },
        )

        start_time = time.time()
        self._emit(MultiAgentEventType.AGENT_ASSIGNED, agent_role=planner_role.value, task_id="task_planner")
        self._emit(MultiAgentEventType.AGENT_STARTED, agent_role=planner_role.value, task_id="task_planner")

        for r in parallel_roles:
            self._emit(MultiAgentEventType.AGENT_ASSIGNED, agent_role=r.value, task_id=f"task_{r.value}")

        try:
            async with trace_agent_execution("maf.workflow.parallel", {"session_id": session_id, "parallel_count": len(parallel_roles)}):
                workflow_task = asyncio.create_task(workflow.run(goal))
                while not workflow_task.done():
                    if self.cancellation_check and self.cancellation_check():
                        workflow_task.cancel()
                        self._emit(MultiAgentEventType.SESSION_CANCELLED, data={"reason": "Cancelled during execution."})
                        return {"success": False, "error": "Execution cancelled."}
                    await asyncio.sleep(0.05)

                result = await workflow_task
        except asyncio.CancelledError:
            self._emit(MultiAgentEventType.SESSION_CANCELLED, data={"reason": "Cancelled by task signal."})
            return {"success": False, "error": "Execution cancelled."}
        except Exception as e:
            self._emit(MultiAgentEventType.AGENT_FAILED, data={"error": str(e)})
            return {"success": False, "error": str(e)}

        outputs = result.get_outputs()
        final_text = ""
        if outputs:
            last_output = outputs[-1]
            final_text = getattr(last_output, "text", str(last_output))
        elif hasattr(result, "text"):
            final_text = result.text
        else:
            final_text = str(result)

        elapsed = time.time() - start_time
        await self._save_step_checkpoint(session_id, len(parallel_roles) + 2, reviewer_role.value, {"final_answer": final_text})
        self._emit(MultiAgentEventType.TASK_COMPLETED, data={"elapsed_seconds": elapsed, "final_answer": final_text})

        return {
            "success": True,
            "final_answer": final_text,
            "elapsed_seconds": elapsed,
            "parallel_count": len(parallel_roles),
        }

    async def execute_handoff_workflow(
        self,
        goal: str,
        triage_role: AgentRoleType = AgentRoleType.SUPERVISOR,
        target_role: AgentRoleType = AgentRoleType.CODER,
        session_id: str = "default_session",
        timeout_seconds: float = 60.0,
    ) -> Dict[str, Any]:
        """
        Executes a dynamic agent handoff:
        Triage Agent analyzes requirement -> Hands off directly to Target Specialist Agent.
        """
        triage_agent = self.registry.create_agent(role=triage_role, task_id="handoff_triage")
        target_agent = self.registry.create_agent(role=target_role, task_id=f"handoff_{target_role.value}")

        builder = WorkflowBuilder(start_executor=triage_agent)
        builder.add_edge(triage_agent, target_agent)
        workflow = builder.build()

        self._emit(
            MultiAgentEventType.SESSION_STARTED,
            data={"goal": goal, "topology": "handoff", "from": triage_role.value, "to": target_role.value},
        )
        self._emit(MultiAgentEventType.AGENT_ASSIGNED, agent_role=triage_role.value, task_id="triage_step")
        self._emit(MultiAgentEventType.AGENT_STARTED, agent_role=triage_role.value, task_id="triage_step")

        start_time = time.time()
        try:
            async with trace_agent_execution("maf.workflow.handoff", {"session_id": session_id, "target": target_role.value}):
                workflow_task = asyncio.create_task(workflow.run(goal))
                while not workflow_task.done():
                    if self.cancellation_check and self.cancellation_check():
                        workflow_task.cancel()
                        self._emit(MultiAgentEventType.SESSION_CANCELLED, data={"reason": "Cancelled during execution."})
                        return {"success": False, "error": "Execution cancelled."}
                    await asyncio.sleep(0.05)

                result = await workflow_task
        except Exception as e:
            self._emit(MultiAgentEventType.AGENT_FAILED, data={"error": str(e)})
            return {"success": False, "error": str(e)}

        self._emit(
            MultiAgentEventType.AGENT_HANDOFF,
            agent_role=triage_role.value,
            data={"handed_off_to": target_role.value, "reason": "Triage analysis complete"},
        )

        outputs = result.get_outputs()
        final_text = getattr(outputs[-1], "text", str(outputs[-1])) if outputs else str(result)
        elapsed = time.time() - start_time

        await self._save_step_checkpoint(session_id, 2, target_role.value, {"final_answer": final_text})
        self._emit(MultiAgentEventType.TASK_COMPLETED, data={"elapsed_seconds": elapsed, "final_answer": final_text})

        return {
            "success": True,
            "final_answer": final_text,
            "elapsed_seconds": elapsed,
            "triage_agent": triage_role.value,
            "executed_by": target_role.value,
        }
