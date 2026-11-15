"""
Aether Multi-Agent Sidecar - Main Server Entrypoint
Provides JSON-RPC/line-delimited IPC protocol between Swift parent process and Microsoft Agent Framework.
"""

from typing import Any, Dict, List, Optional
import asyncio
import json
import logging
import sys
import time

from agents import SpecialistRegistry
from langgraph_backend import LangGraphWorkflowEngine, PersistentAetherCheckpointer
from model_client import AetherChatClient
from observability import global_metrics, trace_agent_execution
from protocol import (
    PROTOCOL_VERSION,
    AgentRoleType,
    MultiAgentEventType,
    SidecarEvent,
    SidecarRequest,
    SidecarResponse,
)
from session import AetherSessionManager
from tools import SwiftToolBridge
from workflow import WorkflowOrchestrator

# Configure logging to stderr so stdout remains pure JSON-RPC stream
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
)
logger = logging.getLogger("AetherSidecarServer")

class MultiAgentServer:
    def __init__(self):
        self.running = True
        self.pending_tool_calls: Dict[str, asyncio.Future] = {}
        self.pending_model_calls: Dict[str, asyncio.Future] = {}
        self.session_cancelled: Dict[str, bool] = {}
        self.session_paused: Dict[str, bool] = {}
        self.enable_live_inference = False

        # Initialize session manager
        self.session_manager = AetherSessionManager()

        # Initialize tool bridge
        self.tool_bridge = SwiftToolBridge(dispatch_to_swift=self._request_tool_from_swift)

        # Initialize specialist agent registry
        self.specialist_registry = SpecialistRegistry(
            chat_client_factory=self._chat_client_factory,
            tool_bridge=self.tool_bridge,
        )

        # Initialize LangGraph workflow engine
        self.langgraph_engine = LangGraphWorkflowEngine(
            specialist_registry=self.specialist_registry,
            session_manager=self.session_manager,
            on_event=lambda sid, et, ar, ti, d: self.emit_event(sid, et, ar, ti, d),
            cancellation_check=lambda sid: self.session_cancelled.get(sid, False),
        )

    def _chat_client_factory(self, role_name: str) -> AetherChatClient:
        return AetherChatClient(
            role_name=role_name,
            inference_delegate=self._request_model_from_swift if self.enable_live_inference else None,
            mock_generator=self._mock_generator,
        )

    def _mock_generator(self, role_name: str, input_text: str) -> str:
        """Deterministic mock generator for tests when no live LLM model is attached."""
        role_lower = role_name.lower()
        if "plan" in role_lower:
            return "1. Inspect requirements\n2. Research codebase\n3. Implement changes\n4. Review and test"
        elif "research" in role_lower:
            return f"Research findings for '{input_text}': Verified relevant structures and dependencies."
        elif "code" in role_lower:
            return f"Code modifications for '{input_text}': Implemented changes and verified syntax."
        elif "analyst" in role_lower:
            return f"Analysis of '{input_text}': No contradictions detected; solution is viable."
        elif "review" in role_lower:
            return f"Review verdict for '{input_text}': APPROVED. All acceptance criteria met."
        elif "assistant" in role_lower:
            return f"Assistant response for '{input_text}': Task processed accurately."
        else:
            return f"Specialist [{role_name}] completed task: '{input_text}'."

    def _send_line(self, data: Dict[str, Any]):
        try:
            line = json.dumps(data) + "\n"
            sys.stdout.write(line)
            sys.stdout.flush()
        except Exception as e:
            logger.error(f"Failed to write to stdout: {e}")

    def emit_event(
        self,
        session_id: str,
        event_type: MultiAgentEventType,
        agent_role: Optional[str] = None,
        task_id: Optional[str] = None,
        data: Optional[Dict[str, Any]] = None,
    ):
        event = SidecarEvent(
            protocol_version=PROTOCOL_VERSION,
            session_id=session_id,
            event_type=event_type,
            agent_role=agent_role,
            task_id=task_id,
            timestamp=time.time(),
            data=data or {},
        )
        self._send_line({"type": "event", "event": event.model_dump()})

    async def _request_tool_from_swift(
        self,
        tool_name: str,
        parameters: Dict[str, str],
        agent_role: str,
        task_id: str,
    ) -> str:
        """
        Sends a tool execution request to Swift and suspends until Swift responds.
        """
        call_id = f"tool_call_{int(time.time() * 1000)}_{len(self.pending_tool_calls)}"
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self.pending_tool_calls[call_id] = fut

        req_payload = {
            "type": "tool_request",
            "call_id": call_id,
            "tool_name": tool_name,
            "parameters": parameters,
            "agent_role": agent_role,
            "task_id": task_id,
        }
        self._send_line(req_payload)

        try:
            result = await fut
            return result
        finally:
            self.pending_tool_calls.pop(call_id, None)

    async def _request_model_from_swift(
        self,
        role_name: str,
        messages: list,
    ) -> str:
        """
        Sends an LLM generation request to Swift's InferenceService if enabled.
        """
        call_id = f"model_call_{int(time.time() * 1000)}_{len(self.pending_model_calls)}"
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self.pending_model_calls[call_id] = fut

        req_payload = {
            "type": "model_request",
            "call_id": call_id,
            "role_name": role_name,
            "messages": messages,
        }
        self._send_line(req_payload)

        try:
            result = await asyncio.wait_for(fut, timeout=15.0)
            return result
        except asyncio.TimeoutError:
            logger.warning(f"Model generation timed out from Swift for {role_name}; falling back to mock.")
            return self._mock_generator(role_name, messages[-1].get("content", "") if messages else "")
        finally:
            self.pending_model_calls.pop(call_id, None)

    async def handle_request(self, req: SidecarRequest):
        op = req.operation
        req_id = req.request_id
        session_id = req.session_id
        payload = req.payload

        if op == "ping":
            self._send_response(req_id, True, {"status": "pong", "time": time.time()})
            return

        if op == "initialize":
            self.enable_live_inference = bool(payload.get("enable_live_inference", False))
            checkpoint_dir = payload.get("checkpoint_dir")
            if checkpoint_dir:
                self.session_manager.configure_storage_dir(checkpoint_dir)
                self.langgraph_engine.checkpointer.configure_storage_dir(checkpoint_dir)

            tools_from_swift = payload.get("tools", [])
            if tools_from_swift:
                self.tool_bridge.register_tool_metadata(tools_from_swift)

            agents = self.specialist_registry.list_agents()
            self._send_response(
                req_id,
                True,
                {
                    "protocol_version": PROTOCOL_VERSION,
                    "framework": "Microsoft Agent Framework + LangGraph",
                    "framework_version": "1.24.0",
                    "langgraph_version": "1.2.20",
                    "supported_frameworks": ["microsoft_agent_framework", "langgraph"],
                    "status": "ready",
                    "supported_roles": [r.value for r in AgentRoleType],
                    "agent_count": len(agents),
                },
            )
            return

        if op == "create_session":
            self.session_cancelled[session_id] = False
            self.session_paused[session_id] = False
            initial_history = payload.get("initial_history", [])
            self.session_manager.get_or_create_session(session_id, initial_history=initial_history)

            custom_agents = payload.get("custom_agents", [])
            for ca in custom_agents:
                self.specialist_registry.register_custom_role(
                    name=ca["name"],
                    instructions=ca["instructions"],
                    description=ca.get("description"),
                    capabilities=ca.get("capabilities"),
                    allowed_tools=ca.get("allowed_tools", []),
                )

            self.emit_event(session_id, MultiAgentEventType.SESSION_STARTED, data={"status": "created"})
            self._send_response(req_id, True, {"session_id": session_id, "status": "active"})
            return

        if op == "list_agents":
            role_filter = payload.get("role")
            cap_filter = payload.get("capability")
            active_only = payload.get("active_only", False)
            agents = self.specialist_registry.list_agents(role=role_filter, capability=cap_filter, active_only=active_only)
            self._send_response(req_id, True, {"agents": [a.model_dump() for a in agents]})
            return

        if op == "get_agent":
            name = payload.get("name", "")
            meta = self.specialist_registry.get_agent_metadata(name)
            if meta:
                self._send_response(req_id, True, {"agent": meta.model_dump()})
            else:
                self._send_response(req_id, False, {}, f"Agent '{name}' not found.")
            return

        if op == "register_agent":
            try:
                name = payload["name"]
                instructions = payload["instructions"]
                desc = payload.get("description")
                caps = payload.get("capabilities", [])
                tools = payload.get("allowed_tools", [])
                meta = self.specialist_registry.register_custom_role(
                    name=name,
                    instructions=instructions,
                    description=desc,
                    capabilities=caps,
                    allowed_tools=tools,
                )
                self._send_response(req_id, True, {"agent": meta.model_dump()})
            except Exception as e:
                self._send_response(req_id, False, {}, str(e))
            return

        if op == "update_agent":
            name = payload.get("name", "")
            is_active = payload.get("is_active", True)
            ok = self.specialist_registry.update_agent_status(name, is_active)
            self._send_response(req_id, ok, {"name": name, "is_active": is_active})
            return

        if op == "delete_agent":
            name = payload.get("name", "")
            ok = self.specialist_registry.delete_custom_agent(name)
            self._send_response(req_id, ok, {"deleted": ok, "name": name})
            return

        if op == "invoke_agent":
            agent_role = payload.get("agent_role", "assistant")
            user_input = payload.get("input", "")
            session = self.session_manager.get_or_create_session(session_id)

            if session.execution_lock.locked():
                self._send_response(req_id, False, {}, "Concurrent execution rejected: session is currently busy.")
                return

            async with session.execution_lock:
                self.emit_event(session_id, MultiAgentEventType.AGENT_STARTED, agent_role=agent_role)
                self.session_manager.add_message(session_id, "user", user_input)

                # Create MAF agent
                agent = self.specialist_registry.create_agent(role=agent_role, task_id=f"invoke_{agent_role}")
                start_t = time.time()
                try:
                    async with trace_agent_execution(f"maf.agent.invoke.{agent_role}", {"session_id": session_id}):
                        response = await agent.run(user_input)
                    res_text = getattr(response, "text", str(response))
                    elapsed = time.time() - start_t

                    self.session_manager.add_message(session_id, "assistant", res_text)
                    self.emit_event(
                        session_id,
                        MultiAgentEventType.AGENT_COMPLETED,
                        agent_role=agent_role,
                        data={"output": res_text, "elapsed_seconds": elapsed},
                    )
                    self._send_response(
                        req_id,
                        True,
                        {"output": res_text, "elapsed_seconds": elapsed, "agent_role": agent_role},
                    )
                except Exception as e:
                    self.emit_event(session_id, MultiAgentEventType.AGENT_FAILED, agent_role=agent_role, data={"error": str(e)})
                    self._send_response(req_id, False, {}, str(e))
            return

        if op == "cancel":
            self.session_cancelled[session_id] = True
            self.emit_event(session_id, MultiAgentEventType.SESSION_CANCELLED, data={"reason": "Cancellation requested."})
            self._send_response(req_id, True, {"session_id": session_id, "status": "cancelled"})
            return

        if op == "pause":
            self.session_paused[session_id] = True
            self.emit_event(session_id, MultiAgentEventType.SESSION_PAUSED, data={"reason": "Pause requested."})
            self._send_response(req_id, True, {"session_id": session_id, "status": "paused"})
            return

        if op == "resume":
            self.session_paused[session_id] = False
            self.emit_event(session_id, MultiAgentEventType.SESSION_RESUMED, data={"reason": "Resume requested."})
            self._send_response(req_id, True, {"session_id": session_id, "status": "resumed"})
            return

        if op == "run_sequential":
            goal = payload.get("goal", "")
            raw_roles = payload.get("roles", ["planner", "coder", "reviewer"])
            framework = str(payload.get("framework", "maf")).lower()
            roles = []
            for r in raw_roles:
                try:
                    roles.append(AgentRoleType(r.lower()))
                except ValueError:
                    roles.append(AgentRoleType.CUSTOM)

            if "langgraph" in framework:
                result = await self.langgraph_engine.execute_sequential_workflow(
                    goal=goal,
                    roles=roles,
                    session_id=session_id,
                    timeout_seconds=payload.get("timeout_seconds", 60.0),
                )
            else:
                orchestrator = WorkflowOrchestrator(
                    specialist_registry=self.specialist_registry,
                    session_manager=self.session_manager,
                    on_event=lambda et, ar, ti, d: self.emit_event(session_id, et, ar, ti, d),
                    cancellation_check=lambda: self.session_cancelled.get(session_id, False),
                )
                result = await orchestrator.execute_sequential_workflow(
                    goal=goal,
                    roles=roles,
                    session_id=session_id,
                    timeout_seconds=payload.get("timeout_seconds", 60.0),
                )
            self._send_response(req_id, result["success"], result, result.get("error"))
            return

        if op == "run_parallel":
            goal = payload.get("goal", "")
            planner = AgentRoleType(payload.get("planner_role", "planner"))
            raw_parallels = payload.get("parallel_roles", ["researcher", "coder"])
            parallels = [AgentRoleType(r) for r in raw_parallels]
            reviewer = AgentRoleType(payload.get("reviewer_role", "reviewer"))
            framework = str(payload.get("framework", "maf")).lower()

            if "langgraph" in framework:
                result = await self.langgraph_engine.execute_parallel_workflow(
                    goal=goal,
                    planner_role=planner,
                    parallel_roles=parallels,
                    reviewer_role=reviewer,
                    session_id=session_id,
                    timeout_seconds=payload.get("timeout_seconds", 60.0),
                )
            else:
                orchestrator = WorkflowOrchestrator(
                    specialist_registry=self.specialist_registry,
                    session_manager=self.session_manager,
                    on_event=lambda et, ar, ti, d: self.emit_event(session_id, et, ar, ti, d),
                    cancellation_check=lambda: self.session_cancelled.get(session_id, False),
                )
                result = await orchestrator.execute_parallel_workflow(
                    goal=goal,
                    planner_role=planner,
                    parallel_roles=parallels,
                    reviewer_role=reviewer,
                    session_id=session_id,
                    timeout_seconds=payload.get("timeout_seconds", 60.0),
                )
            self._send_response(req_id, result["success"], result, result.get("error"))
            return

        if op == "run_handoff":
            goal = payload.get("goal", "")
            triage_role = AgentRoleType(payload.get("triage_role", "supervisor"))
            target_role = AgentRoleType(payload.get("target_role", "coder"))
            framework = str(payload.get("framework", "maf")).lower()

            if "langgraph" in framework:
                result = await self.langgraph_engine.execute_handoff_workflow(
                    goal=goal,
                    triage_role=triage_role,
                    target_role=target_role,
                    session_id=session_id,
                    timeout_seconds=payload.get("timeout_seconds", 60.0),
                )
            else:
                orchestrator = WorkflowOrchestrator(
                    specialist_registry=self.specialist_registry,
                    session_manager=self.session_manager,
                    on_event=lambda et, ar, ti, d: self.emit_event(session_id, et, ar, ti, d),
                    cancellation_check=lambda: self.session_cancelled.get(session_id, False),
                )
                result = await orchestrator.execute_handoff_workflow(
                    goal=goal,
                    triage_role=triage_role,
                    target_role=target_role,
                    session_id=session_id,
                    timeout_seconds=payload.get("timeout_seconds", 60.0),
                )
            self._send_response(req_id, result["success"], result, result.get("error"))
            return

        if op == "resume_graph":
            approval_data = payload.get("approval_data", {})
            timeout_sec = payload.get("timeout_seconds", 60.0)
            result = await self.langgraph_engine.resume_graph(session_id, approval_data, timeout_sec)
            self._send_response(req_id, result["success"], result, result.get("error"))
            return

        if op == "checkpoint_session":
            step = payload.get("step_index", 0)
            agent = payload.get("active_agent", "supervisor")
            data = payload.get("state_payload", {})
            chk = await self.session_manager.save_checkpoint(session_id, step, agent, data)
            self._send_response(req_id, True, {"checkpoint": chk.model_dump()})
            return

        if op == "restore_session":
            chk = await self.session_manager.get_latest_checkpoint(session_id)
            if chk:
                self.emit_event(session_id, MultiAgentEventType.CHECKPOINT_RESTORED, data=chk.model_dump())
                self._send_response(req_id, True, {"checkpoint": chk.model_dump()})
            else:
                self._send_response(req_id, False, {}, "No checkpoint found for session.")
            return

        if op == "get_metrics":
            self._send_response(req_id, True, {"metrics": global_metrics.to_dict()})
            return

        if op == "shutdown":
            self.running = False
            self._send_response(req_id, True, {"status": "shutting_down"})
            return

        self._send_response(req_id, False, {}, f"Unknown operation '{op}'")

    def _send_response(self, request_id: str, success: bool, payload: Dict[str, Any], error: Optional[str] = None):
        resp = SidecarResponse(
            protocol_version=PROTOCOL_VERSION,
            request_id=request_id,
            success=success,
            payload=payload,
            error=error,
        )
        self._send_line({"type": "response", "response": resp.model_dump()})

    def handle_tool_response(self, data: Dict[str, Any]):
        call_id = data.get("call_id")
        if call_id and call_id in self.pending_tool_calls:
            fut = self.pending_tool_calls[call_id]
            if not fut.done():
                fut.set_result(data.get("result", ""))

    def handle_model_response(self, data: Dict[str, Any]):
        call_id = data.get("call_id")
        if call_id and call_id in self.pending_model_calls:
            fut = self.pending_model_calls[call_id]
            if not fut.done():
                fut.set_result(data.get("text", ""))

    async def run(self):
        loop = asyncio.get_running_loop()
        reader = asyncio.StreamReader()
        protocol = asyncio.StreamReaderProtocol(reader)
        await loop.connect_read_pipe(lambda: protocol, sys.stdin)

        logger.info("Aether Multi-Agent Sidecar Server started and listening on stdin.")

        while self.running:
            line_bytes = await reader.readline()
            if not line_bytes:
                # EOF reached
                break
            line_str = line_bytes.decode("utf-8").strip()
            if not line_str:
                continue

            try:
                msg = json.loads(line_str)
            except json.JSONDecodeError as e:
                logger.error(f"Malformed JSON on stdin: {e}")
                continue

            msg_type = msg.get("type", "request")
            if msg_type == "request":
                try:
                    req = SidecarRequest(**msg["request"])
                    asyncio.create_task(self.handle_request(req))
                except Exception as e:
                    logger.error(f"Invalid SidecarRequest: {e}")
            elif msg_type == "tool_response":
                self.handle_tool_response(msg)
            elif msg_type == "model_response":
                self.handle_model_response(msg)
            else:
                logger.warning(f"Unknown message type: {msg_type}")

        logger.info("Aether Multi-Agent Sidecar Server exiting cleanly.")

if __name__ == "__main__":
    server = MultiAgentServer()
    asyncio.run(server.run())
