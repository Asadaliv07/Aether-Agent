"""
Aether Multi-Agent Sidecar - Protocol Models
Defines the strict JSON-RPC and message schemas matching the Swift MultiAgentProtocol.
"""

from enum import Enum
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field
import time

PROTOCOL_VERSION = "1.0.0"

class AgentRoleType(str, Enum):
    SUPERVISOR = "supervisor"
    PLANNER = "planner"
    RESEARCHER = "researcher"
    CODER = "coder"
    ANALYST = "analyst"
    REVIEWER = "reviewer"
    ASSISTANT = "assistant"
    CUSTOM = "custom"

class TaskExecutionStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    PAUSED = "paused"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"

class WorkflowType(str, Enum):
    SEQUENTIAL = "sequential"
    PARALLEL = "parallel"
    HANDOFF = "handoff"
    GROUP_CHAT = "group_chat"

class MultiAgentEventType(str, Enum):
    SESSION_STARTED = "sessionStarted"
    TASK_CREATED = "taskCreated"
    AGENT_ASSIGNED = "agentAssigned"
    AGENT_STARTED = "agentStarted"
    AGENT_PROGRESS = "agentProgress"
    AGENT_HANDOFF = "agentHandoff"
    TOOL_REQUESTED = "toolRequested"
    APPROVAL_REQUIRED = "approvalRequired"
    AGENT_COMPLETED = "agentCompleted"
    AGENT_FAILED = "agentFailed"
    TASK_COMPLETED = "taskCompleted"
    SESSION_PAUSED = "sessionPaused"
    SESSION_RESUMED = "sessionResumed"
    SESSION_CANCELLED = "sessionCancelled"
    TOKEN_STREAMED = "tokenStreamed"
    CHECKPOINT_SAVED = "checkpointSaved"
    CHECKPOINT_RESTORED = "checkpointRestored"

class MultiAgentLimits(BaseModel):
    max_concurrent_agents: int = Field(default=4, ge=1, le=16)
    max_delegation_depth: int = Field(default=3, ge=1, le=8)
    max_retries: int = Field(default=2, ge=0, le=5)
    timeout_seconds: float = Field(default=60.0, ge=1.0)
    max_context_tokens: int = Field(default=4096, ge=512)

class AgentMetadata(BaseModel):
    id: str
    name: str
    role: AgentRoleType
    description: str
    instructions: str
    version: str = "1.0.0"
    is_active: bool = True
    capabilities: List[str] = Field(default_factory=list)
    allowed_tools: List[str] = Field(default_factory=list)
    model_id: Optional[str] = None
    created_at: float = Field(default_factory=time.time)
    updated_at: float = Field(default_factory=time.time)

class CheckpointRecord(BaseModel):
    session_id: str
    step_index: int
    active_agent: str
    state_payload: Dict[str, Any] = Field(default_factory=dict)
    timestamp: float = Field(default_factory=time.time)

class AgentTask(BaseModel):
    task_id: str
    parent_task_id: Optional[str] = None
    assigned_agent: AgentRoleType
    description: str
    input_context: str = ""
    expected_output_schema: Optional[str] = None
    dependencies: List[str] = Field(default_factory=list)
    status: TaskExecutionStatus = TaskExecutionStatus.PENDING
    retry_count: int = 0
    max_retries: int = 2
    output_result: Optional[str] = None
    error_message: Optional[str] = None
    created_at: float = Field(default_factory=time.time)
    completed_at: Optional[float] = None

class SidecarRequest(BaseModel):
    protocol_version: str = PROTOCOL_VERSION
    request_id: str
    session_id: str
    task_id: Optional[str] = None
    operation: str
    payload: Dict[str, Any] = Field(default_factory=dict)

class SidecarResponse(BaseModel):
    protocol_version: str = PROTOCOL_VERSION
    request_id: str
    success: bool
    payload: Dict[str, Any] = Field(default_factory=dict)
    error: Optional[str] = None

class SidecarEvent(BaseModel):
    protocol_version: str = PROTOCOL_VERSION
    session_id: str
    event_type: MultiAgentEventType
    agent_role: Optional[str] = None
    task_id: Optional[str] = None
    timestamp: float = Field(default_factory=time.time)
    data: Dict[str, Any] = Field(default_factory=dict)

class ToolRequestPayload(BaseModel):
    tool_name: str
    parameters: Dict[str, str] = Field(default_factory=dict)
    agent_role: str
    task_id: str

class ToolResultPayload(BaseModel):
    tool_name: str
    is_success: bool
    result: str
    error: Optional[str] = None
