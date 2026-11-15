"""
Aether Multi-Agent Sidecar - Session & Memory Management
Maintains conversational continuity, session context isolation, and durable workflow checkpoint persistence.
Uses Microsoft Agent Framework's FileCheckpointStorage for disk persistence and crash recovery.
Integrates with Aether's SQLite database boundaries.
"""

from typing import Any, Dict, List, Optional
import asyncio
import logging
import os
from pathlib import Path
import re
import time
from agent_framework import FileCheckpointStorage, InMemoryCheckpointStorage, WorkflowCheckpoint
from protocol import CheckpointRecord, MultiAgentLimits

logger = logging.getLogger("AetherSessionManager")

def sanitize_checkpoint_id(raw_id: str) -> str:
    """Sanitizes an ID to be safe for filesystem storage without path traversal."""
    return re.sub(r"[^a-zA-Z0-9_\-]", "_", raw_id)

class SessionState:
    def __init__(self, session_id: str, limits: Optional[MultiAgentLimits] = None):
        self.session_id = session_id
        self.limits = limits or MultiAgentLimits()
        self.messages: List[Dict[str, str]] = []
        self.created_at = time.time()
        self.updated_at = time.time()
        self.is_executing = False
        self.execution_lock = asyncio.Lock()
        self.checkpoints: List[CheckpointRecord] = []
        self.variables: Dict[str, Any] = {}

class AetherSessionManager:
    """
    Coordinates session lifecycle, conversational turns, execution isolation,
    and workflow checkpoint persistence using MAF's durable FileCheckpointStorage.
    """
    def __init__(self, storage_dir: Optional[str] = None):
        self._sessions: Dict[str, SessionState] = {}
        target_dir = storage_dir or os.environ.get(
            "AETHER_CHECKPOINT_DIR",
            str(Path.home() / ".aether" / "checkpoints")
        )
        self.storage_dir = Path(target_dir)
        try:
            self.storage_dir.mkdir(parents=True, exist_ok=True)
            self.file_storage = FileCheckpointStorage(self.storage_dir)
            logger.info(f"Initialized durable FileCheckpointStorage at: {self.storage_dir}")
        except Exception as e:
            logger.warning(f"Could not initialize FileCheckpointStorage at {self.storage_dir}: {e}. Falling back to in-memory.")
            self.file_storage = None

        self.in_memory_storage = InMemoryCheckpointStorage()

    def configure_storage_dir(self, target_dir: str):
        """Dynamically configures checkpoint storage to the sandboxed Application Support directory."""
        self.storage_dir = Path(target_dir)
        try:
            self.storage_dir.mkdir(parents=True, exist_ok=True)
            self.file_storage = FileCheckpointStorage(self.storage_dir)
            logger.info(f"Reconfigured durable FileCheckpointStorage at: {self.storage_dir}")
        except Exception as e:
            logger.warning(f"Could not reconfigure FileCheckpointStorage at {self.storage_dir}: {e}")

    def get_or_create_session(
        self,
        session_id: str,
        limits: Optional[MultiAgentLimits] = None,
        initial_history: Optional[List[Dict[str, str]]] = None,
    ) -> SessionState:
        if session_id not in self._sessions:
            state = SessionState(session_id, limits)
            if initial_history:
                state.messages.extend(initial_history)
            self._sessions[session_id] = state
            logger.info(f"Created new session '{session_id}' with {len(state.messages)} initial messages.")
        return self._sessions[session_id]

    def get_session(self, session_id: str) -> Optional[SessionState]:
        return self._sessions.get(session_id)

    def add_message(self, session_id: str, role: str, content: str):
        session = self.get_or_create_session(session_id)
        session.messages.append({"role": role, "content": content})
        session.updated_at = time.time()

        # Enforce context window trimming if turns exceed limit
        max_messages = 50
        if len(session.messages) > max_messages:
            session.messages = session.messages[-max_messages:]

    def get_messages(self, session_id: str) -> List[Dict[str, str]]:
        session = self.get_session(session_id)
        return list(session.messages) if session else []

    async def save_checkpoint(
        self,
        session_id: str,
        step_index: int,
        active_agent: str,
        state_payload: Dict[str, Any],
    ) -> CheckpointRecord:
        session = self.get_or_create_session(session_id)
        record = CheckpointRecord(
            session_id=session_id,
            step_index=step_index,
            active_agent=active_agent,
            state_payload=state_payload,
            timestamp=time.time(),
        )
        session.checkpoints.append(record)
        session.updated_at = time.time()

        # Save to durable FileCheckpointStorage if available
        if self.file_storage:
            safe_session_name = sanitize_checkpoint_id(session_id)
            chk_id = sanitize_checkpoint_id(f"chk_{session_id}_{step_index}_{int(time.time() * 1000)}")
            # Enforce schema versioning
            enriched_payload = dict(state_payload)
            if "schema_version" not in enriched_payload:
                enriched_payload["schema_version"] = "1.1.0"

            try:
                workflow_cp = WorkflowCheckpoint(
                    workflow_name=safe_session_name,
                    graph_signature_hash=f"hash_{safe_session_name}",
                    checkpoint_id=chk_id,
                    state={
                        "session_id": session_id,
                        "step_index": step_index,
                        "active_agent": active_agent,
                        "state_payload": enriched_payload,
                        "timestamp": record.timestamp,
                    }
                )
                await self.file_storage.save(workflow_cp)
                logger.info(f"Durable FileCheckpointStorage saved checkpoint '{chk_id}' for session '{session_id}'.")

                # Bounded retention: prune checkpoints beyond 20 files
                cp_files = sorted(self.storage_dir.glob("*.json"), key=os.path.getmtime)
                if len(cp_files) > 20:
                    for old_file in cp_files[:-20]:
                        old_file.unlink(missing_ok=True)
            except Exception as e:
                logger.warning(f"Failed to persist checkpoint to disk for session '{session_id}': {e}")

        logger.info(f"Saved checkpoint for session '{session_id}' at step {step_index} ({active_agent}).")
        return record

    async def get_latest_checkpoint(self, session_id: str) -> Optional[CheckpointRecord]:
        session = self.get_session(session_id)
        if session and session.checkpoints:
            return session.checkpoints[-1]

        # Attempt recovery from durable FileCheckpointStorage (useful across restarts)
        if self.file_storage:
            safe_session_name = sanitize_checkpoint_id(session_id)
            try:
                latest_wf = await self.file_storage.get_latest(workflow_name=safe_session_name)
                if latest_wf and latest_wf.state:
                    st = latest_wf.state
                    rec = CheckpointRecord(
                        session_id=st.get("session_id", session_id),
                        step_index=st.get("step_index", 0),
                        active_agent=st.get("active_agent", "supervisor"),
                        state_payload=st.get("state_payload", {}),
                        timestamp=st.get("timestamp", time.time()),
                    )
                    session = self.get_or_create_session(session_id)
                    session.checkpoints.append(rec)
                    logger.info(f"Restored checkpoint from FileCheckpointStorage for session '{session_id}'.")
                    return rec
            except Exception as e:
                logger.warning(f"Failed to read from FileCheckpointStorage for session '{session_id}': {e}")

        return None

    def delete_session(self, session_id: str) -> bool:
        if session_id in self._sessions:
            del self._sessions[session_id]
            logger.info(f"Deleted session '{session_id}'.")
            return True
        return False

    def list_sessions(self) -> List[str]:
        return list(self._sessions.keys())
