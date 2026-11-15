import Foundation
import CryptoKit

/// Protocol constants for the Aether <-> Microsoft Agent Framework / LangGraph IPC boundary.
public enum MultiAgentConstants {
    public static let protocolVersion: String = "1.0.0"
    public static let frameworkName: String = "Microsoft Agent Framework + LangGraph"
    public static let frameworkVersion: String = "1.24.0 / 1.2.20"
    public static let maxMessageSizeBytes: Int = 16 * 1024 * 1024 // 16 MB max frame size
    public static let supportedFrameworks: [String] = [
        "Microsoft Agent Framework (agent-framework-core)",
        "LangGraph (langgraph)"
    ]
}

/// The multi-agent orchestration backend framework for workflow execution.
public enum OrchestrationFramework: String, Codable, Sendable, CaseIterable {
    case maf = "maf"
    case langgraph = "langgraph"
}

/// Specialist agent roles supported in Aether's multi-agent architecture.
public enum AgentRoleType: String, Codable, Sendable, CaseIterable {
    case supervisor = "supervisor"
    case planner = "planner"
    case researcher = "researcher"
    case coder = "coder"
    case analyst = "analyst"
    case reviewer = "reviewer"
    case assistant = "assistant"
    case custom = "custom"
}

/// Execution status of an agent task in the delegation graph.
public enum TaskExecutionStatus: String, Codable, Sendable {
    case pending = "pending"
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// Structured multi-agent telemetry events emitted from the sidecar.
public enum MultiAgentEventType: String, Codable, Sendable {
    case sessionStarted = "sessionStarted"
    case taskCreated = "taskCreated"
    case agentAssigned = "agentAssigned"
    case agentStarted = "agentStarted"
    case agentProgress = "agentProgress"
    case agentHandoff = "agentHandoff"
    case toolRequested = "toolRequested"
    case approvalRequired = "approvalRequired"
    case agentCompleted = "agentCompleted"
    case agentFailed = "agentFailed"
    case taskCompleted = "taskCompleted"
    case sessionPaused = "sessionPaused"
    case sessionResumed = "sessionResumed"
    case sessionCancelled = "sessionCancelled"
    case tokenStreamed = "tokenStreamed"
    case checkpointSaved = "checkpointSaved"
    case checkpointRestored = "checkpointRestored"
    case runtimeCrashed = "runtimeCrashed"
    case runtimeRecovered = "runtimeRecovered"
}

/// An immutable, cryptographically-bound approval token authorizing a specific tool execution.
/// Enforces single-use status, argument hashing (SHA-256), TTL expiration, and process generation binding.
public struct ApprovalToken: Codable, Sendable, Equatable {
    public let tokenId: UUID
    public let toolName: String
    public let argumentHash: String
    public let executionId: String
    public let conversationId: UUID
    public let expiresAt: Double
    public let generationId: UUID
    public var isConsumed: Bool

    public init(
        tokenId: UUID = UUID(),
        toolName: String,
        argumentHash: String,
        executionId: String,
        conversationId: UUID,
        expiresAt: Double = Date().addingTimeInterval(300).timeIntervalSince1970, // 5 minute TTL
        generationId: UUID = UUID(),
        isConsumed: Bool = false
    ) {
        self.tokenId = tokenId
        self.toolName = toolName
        self.argumentHash = argumentHash
        self.executionId = executionId
        self.conversationId = conversationId
        self.expiresAt = expiresAt
        self.generationId = generationId
        self.isConsumed = isConsumed
    }

    /// Computes deterministic SHA-256 hash of sorted key-value pairs to prevent parameter tampering.
    public static func computeArgumentHash(parameters: [String: String]) -> String {
        let sortedPairs = parameters.sorted { $0.key < $1.key }
        let canonical = sortedPairs.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        guard let data = canonical.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case toolName = "tool_name"
        case argumentHash = "argument_hash"
        case executionId = "execution_id"
        case conversationId = "conversation_id"
        case expiresAt = "expires_at"
        case generationId = "generation_id"
        case isConsumed = "is_consumed"
    }
}

/// Metadata describing a registered Microsoft Agent Framework agent in Aether.
public struct AgentMetadata: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let role: AgentRoleType
    public let description: String
    public let instructions: String
    public let version: String
    public let isActive: Bool
    public let capabilities: [String]
    public let allowedTools: [String]
    public let modelId: String?
    public let createdAt: Double
    public let updatedAt: Double

    public init(
        id: String,
        name: String,
        role: AgentRoleType,
        description: String,
        instructions: String,
        version: String = "1.0.0",
        isActive: Bool = true,
        capabilities: [String] = [],
        allowedTools: [String] = [],
        modelId: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.description = description
        self.instructions = instructions
        self.version = version
        self.isActive = isActive
        self.capabilities = capabilities
        self.allowedTools = allowedTools
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case role
        case description
        case instructions
        case version
        case isActive = "is_active"
        case capabilities
        case allowedTools = "allowed_tools"
        case modelId = "model_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// A saved execution checkpoint for workflow state persistence and resumption.
public struct CheckpointRecord: Codable, Sendable, Identifiable {
    public var id: String { "\(sessionId)_\(stepIndex)" }
    public let sessionId: String
    public let stepIndex: Int
    public let activeAgent: String
    public let statePayload: [String: AnyCodableSendable]
    public let timestamp: Double

    public init(
        sessionId: String,
        stepIndex: Int,
        activeAgent: String,
        statePayload: [String: AnyCodableSendable] = [:],
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.sessionId = sessionId
        self.stepIndex = stepIndex
        self.activeAgent = activeAgent
        self.statePayload = statePayload
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case stepIndex = "step_index"
        case activeAgent = "active_agent"
        case statePayload = "state_payload"
        case timestamp
    }
}

/// The result of directly invoking a single agent.
public struct AgentInvocationResult: Codable, Sendable {
    public let output: String
    public let elapsedSeconds: Double
    public let agentRole: String

    public init(output: String, elapsedSeconds: Double, agentRole: String) {
        self.output = output
        self.elapsedSeconds = elapsedSeconds
        self.agentRole = agentRole
    }

    enum CodingKeys: String, CodingKey {
        case output
        case elapsedSeconds = "elapsed_seconds"
        case agentRole = "agent_role"
    }
}

/// OpenTelemetry-backed metrics record for multi-agent observability.
public struct ExecutionMetricsRecord: Codable, Sendable {
    public let totalInvocations: Int
    public let successfulInvocations: Int
    public let failedInvocations: Int
    public let averageLatencySeconds: Double
    public let toolCallsCount: Int
    public let approvalRequestsCount: Int
    public let retriesCount: Int

    public init(
        totalInvocations: Int = 0,
        successfulInvocations: Int = 0,
        failedInvocations: Int = 0,
        averageLatencySeconds: Double = 0.0,
        toolCallsCount: Int = 0,
        approvalRequestsCount: Int = 0,
        retriesCount: Int = 0
    ) {
        self.totalInvocations = totalInvocations
        self.successfulInvocations = successfulInvocations
        self.failedInvocations = failedInvocations
        self.averageLatencySeconds = averageLatencySeconds
        self.toolCallsCount = toolCallsCount
        self.approvalRequestsCount = approvalRequestsCount
        self.retriesCount = retriesCount
    }

    enum CodingKeys: String, CodingKey {
        case totalInvocations = "total_invocations"
        case successfulInvocations = "successful_invocations"
        case failedInvocations = "failed_invocations"
        case averageLatencySeconds = "average_latency_seconds"
        case toolCallsCount = "tool_calls_count"
        case approvalRequestsCount = "approval_requests_count"
        case retriesCount = "retries_count"
    }
}

/// Configurable limits and boundaries for multi-agent delegation.
public struct MultiAgentLimits: Codable, Sendable, Equatable {
    public var maxConcurrentAgents: Int
    public var maxDelegationDepth: Int
    public var maxRetries: Int
    public var timeoutSeconds: Double
    public var maxContextTokens: Int

    public init(
        maxConcurrentAgents: Int = 4,
        maxDelegationDepth: Int = 3,
        maxRetries: Int = 2,
        timeoutSeconds: Double = 60.0,
        maxContextTokens: Int = 4096
    ) {
        self.maxConcurrentAgents = maxConcurrentAgents
        self.maxDelegationDepth = maxDelegationDepth
        self.maxRetries = maxRetries
        self.timeoutSeconds = timeoutSeconds
        self.maxContextTokens = maxContextTokens
    }

    enum CodingKeys: String, CodingKey {
        case maxConcurrentAgents = "max_concurrent_agents"
        case maxDelegationDepth = "max_delegation_depth"
        case maxRetries = "max_retries"
        case timeoutSeconds = "timeout_seconds"
        case maxContextTokens = "max_context_tokens"
    }
}

/// A structured task representation in the multi-agent delegation tree.
public struct AgentTask: Codable, Sendable, Identifiable {
    public var id: String { taskId }
    public let taskId: String
    public let parentTaskId: String?
    public let assignedAgent: AgentRoleType
    public let description: String
    public let inputContext: String
    public let expectedOutputSchema: String?
    public let dependencies: [String]
    public var status: TaskExecutionStatus
    public var retryCount: Int
    public let maxRetries: Int
    public var outputResult: String?
    public var errorMessage: String?
    public let createdAt: Double
    public var completedAt: Double?

    public init(
        taskId: String = UUID().uuidString,
        parentTaskId: String? = nil,
        assignedAgent: AgentRoleType,
        description: String,
        inputContext: String = "",
        expectedOutputSchema: String? = nil,
        dependencies: [String] = [],
        status: TaskExecutionStatus = .pending,
        retryCount: Int = 0,
        maxRetries: Int = 2,
        outputResult: String? = nil,
        errorMessage: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        completedAt: Double? = nil
    ) {
        self.taskId = taskId
        self.parentTaskId = parentTaskId
        self.assignedAgent = assignedAgent
        self.description = description
        self.inputContext = inputContext
        self.expectedOutputSchema = expectedOutputSchema
        self.dependencies = dependencies
        self.status = status
        self.retryCount = retryCount
        self.maxRetries = maxRetries
        self.outputResult = outputResult
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case parentTaskId = "parent_task_id"
        case assignedAgent = "assigned_agent"
        case description
        case inputContext = "input_context"
        case expectedOutputSchema = "expected_output_schema"
        case dependencies
        case status
        case retryCount = "retry_count"
        case maxRetries = "max_retries"
        case outputResult = "output_result"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

/// Request sent from Swift to the Python multi-agent sidecar.
public struct SidecarRequest: Codable, Sendable {
    public let protocolVersion: String
    public let requestId: String
    public let sessionId: String
    public let taskId: String?
    public let generationId: UUID?
    public let correlationId: String?
    public let operation: String
    public let payload: [String: AnyCodableSendable]

    public init(
        protocolVersion: String = MultiAgentConstants.protocolVersion,
        requestId: String = UUID().uuidString,
        sessionId: String,
        taskId: String? = nil,
        generationId: UUID? = nil,
        correlationId: String? = nil,
        operation: String,
        payload: [String: AnyCodableSendable] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.sessionId = sessionId
        self.taskId = taskId
        self.generationId = generationId
        self.correlationId = correlationId
        self.operation = operation
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case sessionId = "session_id"
        case taskId = "task_id"
        case generationId = "generation_id"
        case correlationId = "correlation_id"
        case operation
        case payload
    }
}

/// Response returned from the Python sidecar to Swift.
public struct SidecarResponse: Codable, Sendable {
    public let protocolVersion: String
    public let requestId: String
    public let generationId: UUID?
    public let success: boolValue_bridge?
    public let payload: [String: AnyCodableSendable]
    public let error: String?

    public var isSuccess: Bool {
        return success?.value ?? false
    }

    public init(
        protocolVersion: String = MultiAgentConstants.protocolVersion,
        requestId: String,
        generationId: UUID? = nil,
        success: Bool,
        payload: [String: AnyCodableSendable] = [:],
        error: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.generationId = generationId
        self.success = boolValue_bridge(value: success)
        self.payload = payload
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case generationId = "generation_id"
        case success
        case payload
        case error
    }
}

/// Helper for Darwin-safe decoding of boolean fields.
public struct boolValue_bridge: Codable, Sendable {
    public let value: Bool

    public init(value: Bool) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let num = try? container.decode(Int.self) {
            self.value = (num != 0)
        } else {
            self.value = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Streaming event emitted by the sidecar during workflow execution.
public struct SidecarEvent: Codable, Sendable {
    public let protocolVersion: String
    public let sessionId: String
    public let eventType: MultiAgentEventType
    public let agentRole: String?
    public let taskId: String?
    public let timestamp: Double
    public let data: [String: AnyCodableSendable]

    public init(
        protocolVersion: String = MultiAgentConstants.protocolVersion,
        sessionId: String,
        eventType: MultiAgentEventType,
        agentRole: String? = nil,
        taskId: String? = nil,
        timestamp: Double = Date().timeIntervalSince1970,
        data: [String: AnyCodableSendable] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.sessionId = sessionId
        self.eventType = eventType
        self.agentRole = agentRole
        self.taskId = taskId
        self.timestamp = timestamp
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case eventType = "event_type"
        case agentRole = "agent_role"
        case taskId = "task_id"
        case timestamp
        case data
    }
}

/// Tool execution request emitted by a specialist agent to the Swift parent process.
public struct SidecarToolRequest: Codable, Sendable {
    public let callId: String
    public let toolName: String
    public let parameters: [String: String]
    public let agentRole: String
    public let taskId: String

    public init(
        callId: String,
        toolName: String,
        parameters: [String: String],
        agentRole: String,
        taskId: String
    ) {
        self.callId = callId
        self.toolName = toolName
        self.parameters = parameters
        self.agentRole = agentRole
        self.taskId = taskId
    }

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case toolName = "tool_name"
        case parameters
        case agentRole = "agent_role"
        case taskId = "task_id"
    }
}

/// Tool execution result returned from Swift to the Python sidecar.
public struct SidecarToolResponse: Codable, Sendable {
    public let callId: String
    public let isSuccess: Bool
    public let result: String
    public let error: String?

    public init(
        callId: String,
        isSuccess: Bool,
        result: String,
        error: String? = nil
    ) {
        self.callId = callId
        self.isSuccess = isSuccess
        self.result = result
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case isSuccess = "is_success"
        case result
        case error
    }
}

