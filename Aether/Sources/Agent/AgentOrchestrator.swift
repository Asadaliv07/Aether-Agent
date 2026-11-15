import Foundation
import os

/// Structured representation of a tool call emitted by an LLM during multi-step reasoning.
public struct ToolCallInvocation: Sendable, Equatable {
    public let toolName: String
    public let parameters: [String: String]
    public let rawThought: String?

    public init(toolName: String, parameters: [String: String], rawThought: String? = nil) {
        self.toolName = toolName
        self.parameters = parameters
        self.rawThought = rawThought
    }
}

/// Events emitted during the lifecycle of an agent multi-step orchestration session.
public enum AgentOrchestrationEvent: Sendable, Equatable {
    case thinking(thought: String)
    case toolCallProposed(invocation: ToolCallInvocation)
    case waitingForUserConfirmation(request: ToolConfirmationRequest)
    case toolExecuting(toolName: String)
    case toolCompleted(result: ToolExecutionResult)
    case answerToken(String)
    case completed(finalAnswer: String, totalSteps: Int)
    case failed(errorDescription: String)
}

/// Orchestrator coordinating multi-step agent reasoning, tool selection, interactive security approval,
/// and response generation.
public actor AgentOrchestrator {
    public let registry: ToolRegistry
    public let securityGuard: ToolSecurityGuard
    public let maxSteps: Int

    private let logger = Logger(subsystem: "com.aether.Aether", category: "AgentOrchestrator")

    public init(
        registry: ToolRegistry,
        securityGuard: ToolSecurityGuard? = nil,
        maxSteps: Int = 10
    ) {
        self.registry = registry
        self.securityGuard = securityGuard ?? registry.securityGuard
        self.maxSteps = maxSteps
    }

    // MARK: - Prompt Augmentation

    /// Builds the system prompt injecting tool definitions and instruction boundaries.
    public func buildSystemPrompt(baseSystemPrompt: String? = nil) async -> String {
        let toolsDocumentation = await registry.formatToolsForPrompt(style: .xmlTags)

        let base = baseSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = base.isEmpty ? "You are Aether, an intelligent personal AI assistant." : base

        return """
        \(prefix)

        Available tools:
        \(toolsDocumentation)

        TOOL USAGE RULES:
        1. When you need information or external actions, call an available tool.
        2. To invoke a tool:
        XML format:
        <thought>Reasoning</thought>
        <tool_call>
        <name>create_folder</name>
        <parameters>
          <path>Desktop/AetherTest</path>
        </parameters>
        </tool_call>

        JSON format:
        <thought>Reasoning</thought>
        <tool_call>
        {"name": "create_folder", "arguments": {"path": "Desktop/AetherTest"}}
        </tool_call>

        CRITICAL PARAMETER RULES:
        - NEVER use generic <param> or <parameter> tags. Parameter XML tags MUST match the exact parameter name (e.g. <path>Desktop/AetherTest</path>).
        - NEVER use placeholder paths like '/path/to/new/folder' or 'path/to/...'. Always provide the real requested destination path.
        - If a required parameter is missing or ambiguous, ask the user for clarification instead of calling a tool with invented values.
        3. Never claim you cannot interact with the filesystem when tools are available. Always call the corresponding tool.
        4. If you do not need any tools, respond directly to the user without emitting <tool_call>.
        """
    }

    // MARK: - Tool Call Parsing

    /// Deterministically extracts `<thought>` and `<tool_call>` blocks from generated text.
    public static func parseToolCall(from text: String, availableTools: [ToolDefinition] = []) -> ToolCallInvocation? {
        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(from: text, availableTools: availableTools)
        switch action {
        case .callTool(let toolName, let parameters, _):
            return ToolCallInvocation(toolName: toolName, parameters: parameters, rawThought: thought)
        case .requestConfirmation(let toolName, let parameters, _):
            return ToolCallInvocation(toolName: toolName, parameters: parameters, rawThought: thought)
        default:
            return nil
        }
    }


    // MARK: - Format Tool Response Back to Model

    public static func formatToolResponse(result: ToolExecutionResult) -> String {
        let statusStr = result.isSuccess ? "success" : "error"
        let outputContent = result.isSuccess ? result.output : (result.errorDescription ?? "Operation failed.")

        return """
        <tool_response name="\(result.toolName)" status="\(statusStr)">
        \(outputContent)
        </tool_response>
        """
    }

    // MARK: - Single Step Tool Execution (Backward-Compatible Interface)

    /// Executes a single step of tool dispatch, evaluating permissions and delegating to the registry.
    public func executeToolStep(
        invocation: ToolCallInvocation,
        conversationId: UUID,
        isInteractiveApprovalGranted: Bool = false,
        timeoutSeconds: Double = 15.0
    ) async -> (decision: ToolAuthorizationDecision, result: ToolExecutionResult?) {
        guard let tool = await registry.tool(named: invocation.toolName) else {
            let res = ToolExecutionResult.failure(toolName: invocation.toolName, error: "Tool '\(invocation.toolName)' is not registered.")
            return (.authorized, res)
        }

        let context = ToolExecutionContext(
            conversationId: conversationId,
            executionId: UUID(),
            timeoutSeconds: timeoutSeconds,
            isInteractiveApprovalGranted: isInteractiveApprovalGranted
        )

        // Check authorization
        let decision = await securityGuard.authorize(
            tool: tool.definition,
            parameters: invocation.parameters,
            context: context
        )

        switch decision {
        case .authorized:
            let result = await registry.execute(
                toolName: invocation.toolName,
                parameters: invocation.parameters,
                context: context
            )
            return (.authorized, result)

        case .requiresUserConfirmation(let request):
            return (.requiresUserConfirmation(request), nil)

        case .denied(let reason):
            let res = ToolExecutionResult.denied(toolName: invocation.toolName, reason: reason)
            return (.denied(reason: reason), res)
        }
    }

    // MARK: - Multi-Step Execution Loop Integration (Sub-Phase 1.1)

    /// Creates an actor-isolated cyclic execution loop initialized with the given goal and inference provider.
    public func createExecutionLoop(
        goal: String,
        conversationId: UUID,
        inferenceProvider: AgentInferenceProvider,
        maxSteps: Int? = nil,
        timeoutSeconds: Double = 30.0
    ) -> AgentExecutionLoopActor {
        let initialState = AgentState(
            sessionId: UUID(),
            conversationId: conversationId,
            phase: .idle,
            stepIndex: 0,
            maxSteps: maxSteps ?? self.maxSteps,
            goal: goal
        )

        return AgentExecutionLoopActor(
            initialState: initialState,
            registry: self.registry,
            securityGuard: self.securityGuard,
            inferenceProvider: inferenceProvider,
            maxSteps: maxSteps ?? self.maxSteps,
            toolTimeoutSeconds: timeoutSeconds
        )
    }

    /// Convenience runner that executes an end-to-end multi-step agent loop.
    public func runLoop(
        goal: String,
        conversationId: UUID,
        inferenceProvider: AgentInferenceProvider,
        maxSteps: Int? = nil
    ) async -> AgentState {
        let loop = createExecutionLoop(
            goal: goal,
            conversationId: conversationId,
            inferenceProvider: inferenceProvider,
            maxSteps: maxSteps
        )
        return await loop.run()
    }

    // MARK: - Multi-Step Production Reasoning Engine (Sub-Phase 1.2)

    /// Deterministically parses model thoughts and actions supporting `<thought>`, `<tool_call>`,
    /// `<final_answer>`, `<action>`, and `<confirm_tool>` tags.
    public static func parseAction(from text: String, availableTools: [ToolDefinition] = []) -> (thought: String?, action: AgentAction) {
        return ProductionAgentInferenceProvider.parseModelOutput(from: text, availableTools: availableTools)
    }

    /// Creates a production cyclic execution loop wired to `ProductionAgentInferenceProvider`,
    /// `InferenceService`, and `AgentCyclicController`.
    public func createProductionLoop(
        goal: String,
        conversationId: UUID,
        inferenceService: InferenceService,
        modelArchitecture: String? = nil,
        configuration: GenerationConfiguration? = nil,
        maxSteps: Int? = nil,
        timeoutSeconds: Double = 30.0,
        cyclicController: AgentCyclicController = AgentCyclicController()
    ) -> AgentExecutionLoopActor {
        let provider = ProductionAgentInferenceProvider(
            inferenceService: inferenceService,
            cyclicController: cyclicController,
            configuration: configuration ?? GenerationConfiguration(
                contextLength: 8192,
                maxTokens: 512,
                temperature: 0.1,
                topK: 40,
                topP: 0.95
            ),
            modelArchitecture: modelArchitecture
        )

        return createExecutionLoop(
            goal: goal,
            conversationId: conversationId,
            inferenceProvider: provider,
            maxSteps: maxSteps,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Convenience runner executing a full production cyclic reasoning session with local LLM inference.
    public func runProductionLoop(
        goal: String,
        conversationId: UUID,
        inferenceService: InferenceService,
        modelArchitecture: String? = nil,
        configuration: GenerationConfiguration? = nil,
        maxSteps: Int? = nil,
        timeoutSeconds: Double = 30.0,
        cyclicController: AgentCyclicController = AgentCyclicController()
    ) async -> AgentState {
        let loop = createProductionLoop(
            goal: goal,
            conversationId: conversationId,
            inferenceService: inferenceService,
            modelArchitecture: modelArchitecture,
            configuration: configuration,
            maxSteps: maxSteps,
            timeoutSeconds: timeoutSeconds,
            cyclicController: cyclicController
        )
        return await loop.run()
    }

    // MARK: - Multi-Agent Framework Integration

    /// Lazily initialized MultiAgentSupervisor
    private var _multiAgentSupervisor: MultiAgentSupervisor?

    public func getOrCreateMultiAgentSupervisor() async throws -> MultiAgentSupervisor {
        if let existing = _multiAgentSupervisor {
            return existing
        }
        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            securityGuard: self.securityGuard,
            toolRegistry: self.registry
        )
        self._multiAgentSupervisor = supervisor
        return supervisor
    }

    public func setMultiAgentSupervisor(_ supervisor: MultiAgentSupervisor) {
        self._multiAgentSupervisor = supervisor
    }

    /// Executes a sequential multi-agent workflow delegating to the Python sidecar.
    public func runMultiAgentSequential(
        goal: String,
        roles: [AgentRoleType] = [.planner, .coder, .reviewer],
        sessionId: String = UUID().uuidString,
        timeoutSeconds: Double = 60.0,
        cancellationSignal: CancellationSignal? = nil
    ) async throws -> MultiAgentWorkflowResult {
        let supervisor = try await getOrCreateMultiAgentSupervisor()
        return try await supervisor.executeSequential(
            goal: goal,
            roles: roles,
            sessionId: sessionId,
            timeoutSeconds: timeoutSeconds,
            cancellationSignal: cancellationSignal
        )
    }

    /// Executes a parallel fan-out/fan-in multi-agent workflow delegating to the Python sidecar.
    public func runMultiAgentParallel(
        goal: String,
        plannerRole: AgentRoleType = .planner,
        parallelRoles: [AgentRoleType] = [.researcher, .coder],
        reviewerRole: AgentRoleType = .reviewer,
        sessionId: String = UUID().uuidString,
        timeoutSeconds: Double = 60.0,
        cancellationSignal: CancellationSignal? = nil
    ) async throws -> MultiAgentWorkflowResult {
        let supervisor = try await getOrCreateMultiAgentSupervisor()
        return try await supervisor.executeParallel(
            goal: goal,
            plannerRole: plannerRole,
            parallelRoles: parallelRoles,
            reviewerRole: reviewerRole,
            sessionId: sessionId,
            timeoutSeconds: timeoutSeconds,
            cancellationSignal: cancellationSignal
        )
    }

    /// Executes an agent handoff workflow delegating to the Python sidecar.
    public func runMultiAgentHandoff(
        goal: String,
        triageRole: AgentRoleType = .supervisor,
        targetRole: AgentRoleType = .coder,
        sessionId: String = UUID().uuidString,
        timeoutSeconds: Double = 60.0,
        cancellationSignal: CancellationSignal? = nil
    ) async throws -> MultiAgentWorkflowResult {
        let supervisor = try await getOrCreateMultiAgentSupervisor()
        return try await supervisor.executeHandoff(
            goal: goal,
            triageRole: triageRole,
            targetRole: targetRole,
            sessionId: sessionId,
            timeoutSeconds: timeoutSeconds,
            cancellationSignal: cancellationSignal
        )
    }

    /// Invokes a single Microsoft Agent Framework specialist directly.
    public func invokeSingleAgent(
        agentRole: String,
        input: String,
        sessionId: String = UUID().uuidString,
        timeoutSeconds: Double = 60.0
    ) async throws -> AgentInvocationResult {
        let supervisor = try await getOrCreateMultiAgentSupervisor()
        return try await supervisor.invokeAgent(
            agentRole: agentRole,
            input: input,
            sessionId: sessionId,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Lists all agents discovered in the Microsoft Agent Framework registry.
    public func listAvailableAgents(activeOnly: Bool = true) async throws -> [AgentMetadata] {
        let supervisor = try await getOrCreateMultiAgentSupervisor()
        return try await supervisor.listAgents(activeOnly: activeOnly)
    }

    /// Registers a custom specialist agent in the Microsoft Agent Framework registry.
    public func registerCustomAgent(
        name: String,
        instructions: String,
        description: String? = nil,
        capabilities: [String] = [],
        allowedTools: [String] = []
    ) async throws -> AgentMetadata {
        let supervisor = try await getOrCreateMultiAgentSupervisor()
        return try await supervisor.registerAgent(
            name: name,
            instructions: instructions,
            description: description,
            capabilities: capabilities,
            allowedTools: allowedTools
        )
    }
}
