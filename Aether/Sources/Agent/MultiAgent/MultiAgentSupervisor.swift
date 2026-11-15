import Foundation
import os

/// The result of a multi-agent workflow execution session.
public struct MultiAgentWorkflowResult: Sendable {
    public let sessionId: String
    public let isSuccess: Bool
    public let finalAnswer: String
    public let elapsedSeconds: Double
    public let error: String?

    public init(
        sessionId: String,
        isSuccess: Bool,
        finalAnswer: String,
        elapsedSeconds: Double,
        error: String? = nil
    ) {
        self.sessionId = sessionId
        self.isSuccess = isSuccess
        self.finalAnswer = finalAnswer
        self.elapsedSeconds = elapsedSeconds
        self.error = error
    }
}

/// The top-level Swift coordinator for Aether Multi-Agent orchestration.
/// Serves as the authoritative bridge between Aether's core engine and the Python sidecar.
public actor MultiAgentSupervisor {
    public let sidecarManager: MultiAgentSidecarManager
    public let toolBridge: MultiAgentToolBridge
    public var defaultFramework: OrchestrationFramework = .maf
    private let logger = Logger(subsystem: "com.aether.Aether", category: "MultiAgentSupervisor")

    public init(
        sidecarManager: MultiAgentSidecarManager,
        toolBridge: MultiAgentToolBridge,
        defaultFramework: OrchestrationFramework = .maf
    ) {
        self.sidecarManager = sidecarManager
        self.toolBridge = toolBridge
        self.defaultFramework = defaultFramework
    }

    /// Updates the default orchestration framework (MAF vs LangGraph).
    public func setDefaultFramework(_ framework: OrchestrationFramework) {
        self.defaultFramework = framework
    }

    /// Convenience factory launching the production Python sidecar with the bundled virtualenv.
    public static func createWithSubprocess(
        pythonPath: String? = nil,
        scriptPath: String? = nil,
        securityGuard: ToolSecurityGuard,
        toolRegistry: ToolRegistry
    ) async throws -> MultiAgentSupervisor {
        let runtime = try SidecarRuntimeLocator.resolve(customPython: pythonPath, customScript: scriptPath)

        let transport = MultiAgentSubprocessTransport()
        try await transport.start(pythonPath: runtime.pythonPath, scriptPath: runtime.scriptPath)

        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: transport, toolBridge: bridge)

        return MultiAgentSupervisor(sidecarManager: manager, toolBridge: bridge)
    }

    /// Computes hardware-adaptive delegation and memory limits based on host Apple Silicon unified RAM.
    private func adaptiveLimits() -> MultiAgentLimits {
        let ramGB = DeviceCapabilityEngine.getProfile().physicalRAMGigabytes
        let maxParallel = ramGB <= 8 ? 2 : (ramGB <= 16 ? 3 : 4)
        let maxConcurrent = ramGB <= 8 ? 1 : 2
        return MultiAgentLimits(
            maxConcurrentAgents: maxConcurrent,
            maxDelegationDepth: 3,
            maxRetries: 2,
            timeoutSeconds: ramGB <= 8 ? 45.0 : 60.0,
            maxContextTokens: ramGB <= 8 ? 2048 : 4096
        )
    }

    /// Convenience factory creating an in-memory testable supervisor without external sub-processes.
    public static func createInMemory(
        securityGuard: ToolSecurityGuard,
        toolRegistry: ToolRegistry
    ) -> (supervisor: MultiAgentSupervisor, peerTransport: MultiAgentInMemoryTransport) {
        let (client, server) = MultiAgentInMemoryTransport.createPair()
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: client, toolBridge: bridge)
        let supervisor = MultiAgentSupervisor(sidecarManager: manager, toolBridge: bridge)
        return (supervisor, server)
    }

    /// Executes a sequential multi-agent workflow with cancellation monitoring.
    public func executeSequential(
        goal: String,
        roles: [AgentRoleType] = [.planner, .coder, .reviewer],
        sessionId: String = UUID().uuidString,
        framework: OrchestrationFramework? = nil,
        timeoutSeconds: Double = 60.0,
        cancellationSignal: CancellationSignal? = nil
    ) async throws -> MultiAgentWorkflowResult {
        // Ensure handshake is complete
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }

        // Setup session with hardware-adaptive limits
        _ = try await sidecarManager.createSession(sessionId: sessionId, limits: adaptiveLimits())

        // Observe cancellation signal
        if let signal = cancellationSignal {
            if signal.isCancelled {
                _ = try? await sidecarManager.cancelSession(sessionId: sessionId)
                return MultiAgentWorkflowResult(
                    sessionId: sessionId,
                    isSuccess: false,
                    finalAnswer: "",
                    elapsedSeconds: 0,
                    error: "Execution cancelled before start."
                )
            }
        }

        let chosenFramework = framework ?? defaultFramework
        let resp = try await sidecarManager.runSequential(
            goal: goal,
            roles: roles,
            sessionId: sessionId,
            framework: chosenFramework,
            timeoutSeconds: timeoutSeconds
        )

        let ans = resp.payload["final_answer"]?.stringValue ?? ""
        let elapsed = resp.payload["elapsed_seconds"]?.doubleValue ?? 0.0

        return MultiAgentWorkflowResult(
            sessionId: sessionId,
            isSuccess: resp.isSuccess,
            finalAnswer: ans,
            elapsedSeconds: elapsed,
            error: resp.error
        )
    }

    /// Executes a parallel fan-out/fan-in multi-agent workflow with cancellation monitoring.
    public func executeParallel(
        goal: String,
        plannerRole: AgentRoleType = .planner,
        parallelRoles: [AgentRoleType] = [.researcher, .coder],
        reviewerRole: AgentRoleType = .reviewer,
        sessionId: String = UUID().uuidString,
        framework: OrchestrationFramework? = nil,
        timeoutSeconds: Double = 60.0,
        cancellationSignal: CancellationSignal? = nil
    ) async throws -> MultiAgentWorkflowResult {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }

        _ = try await sidecarManager.createSession(sessionId: sessionId, limits: adaptiveLimits())

        if let signal = cancellationSignal {
            if signal.isCancelled {
                _ = try? await sidecarManager.cancelSession(sessionId: sessionId)
                return MultiAgentWorkflowResult(
                    sessionId: sessionId,
                    isSuccess: false,
                    finalAnswer: "",
                    elapsedSeconds: 0,
                    error: "Execution cancelled before start."
                )
            }
        }

        let chosenFramework = framework ?? defaultFramework
        let resp = try await sidecarManager.runParallel(
            goal: goal,
            plannerRole: plannerRole,
            parallelRoles: parallelRoles,
            reviewerRole: reviewerRole,
            sessionId: sessionId,
            framework: chosenFramework,
            timeoutSeconds: timeoutSeconds
        )

        let ans = resp.payload["final_answer"]?.stringValue ?? ""
        let elapsed = resp.payload["elapsed_seconds"]?.doubleValue ?? 0.0

        return MultiAgentWorkflowResult(
            sessionId: sessionId,
            isSuccess: resp.isSuccess,
            finalAnswer: ans,
            elapsedSeconds: elapsed,
            error: resp.error
        )
    }

    /// Executes a dynamic agent handoff workflow with cancellation monitoring.
    public func executeHandoff(
        goal: String,
        triageRole: AgentRoleType = .supervisor,
        targetRole: AgentRoleType = .coder,
        sessionId: String = UUID().uuidString,
        framework: OrchestrationFramework? = nil,
        timeoutSeconds: Double = 60.0,
        cancellationSignal: CancellationSignal? = nil
    ) async throws -> MultiAgentWorkflowResult {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }

        _ = try await sidecarManager.createSession(sessionId: sessionId, limits: adaptiveLimits())

        if let signal = cancellationSignal, signal.isCancelled {
            _ = try? await sidecarManager.cancelSession(sessionId: sessionId)
            return MultiAgentWorkflowResult(
                sessionId: sessionId,
                isSuccess: false,
                finalAnswer: "",
                elapsedSeconds: 0,
                error: "Execution cancelled before start."
            )
        }

        let chosenFramework = framework ?? defaultFramework
        let resp = try await sidecarManager.runHandoff(
            goal: goal,
            triageRole: triageRole,
            targetRole: targetRole,
            sessionId: sessionId,
            framework: chosenFramework,
            timeoutSeconds: timeoutSeconds
        )

        let ans = resp.payload["final_answer"]?.stringValue ?? ""
        let elapsed = resp.payload["elapsed_seconds"]?.doubleValue ?? 0.0

        return MultiAgentWorkflowResult(
            sessionId: sessionId,
            isSuccess: resp.isSuccess,
            finalAnswer: ans,
            elapsedSeconds: elapsed,
            error: resp.error
        )
    }

    /// Resumes an interrupted LangGraph workflow session with human approval decision.
    public func resumeGraph(
        sessionId: String,
        approvalData: [String: AnyCodableSendable] = [:],
        timeoutSeconds: Double = 60.0
    ) async throws -> MultiAgentWorkflowResult {
        let resp = try await sidecarManager.resumeGraph(
            sessionId: sessionId,
            approvalData: approvalData,
            timeoutSeconds: timeoutSeconds
        )

        let ans = resp.payload["final_answer"]?.stringValue ?? ""
        let elapsed = resp.payload["elapsed_seconds"]?.doubleValue ?? 0.0

        return MultiAgentWorkflowResult(
            sessionId: sessionId,
            isSuccess: resp.isSuccess,
            finalAnswer: ans,
            elapsedSeconds: elapsed,
            error: resp.error
        )
    }

    /// Directly invokes a single registered agent without multi-agent workflow overhead.
    public func invokeAgent(
        agentRole: String,
        input: String,
        sessionId: String = UUID().uuidString,
        timeoutSeconds: Double = 60.0
    ) async throws -> AgentInvocationResult {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }
        return try await sidecarManager.invokeAgent(
            agentRole: agentRole,
            input: input,
            sessionId: sessionId,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Discovers all available agents registered in the Microsoft Agent Framework sidecar.
    public func listAgents(
        role: String? = nil,
        capability: String? = nil,
        activeOnly: Bool = false
    ) async throws -> [AgentMetadata] {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }
        return try await sidecarManager.listAgents(role: role, capability: capability, activeOnly: activeOnly)
    }

    /// Retrieves metadata for a specific agent.
    public func getAgent(name: String) async throws -> AgentMetadata? {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }
        return try await sidecarManager.getAgent(name: name)
    }

    /// Registers a custom specialist agent with defined capabilities and boundaries.
    public func registerAgent(
        name: String,
        instructions: String,
        description: String? = nil,
        capabilities: [String] = [],
        allowedTools: [String] = []
    ) async throws -> AgentMetadata {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }
        return try await sidecarManager.registerAgent(
            name: name,
            instructions: instructions,
            description: description,
            capabilities: capabilities,
            allowedTools: allowedTools
        )
    }

    /// Activates or deactivates an agent.
    public func updateAgent(name: String, isActive: Bool) async throws -> Bool {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }
        return try await sidecarManager.updateAgent(name: name, isActive: isActive)
    }

    /// Deletes a custom agent.
    public func deleteAgent(name: String) async throws -> Bool {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }
        return try await sidecarManager.deleteAgent(name: name)
    }

    /// Saves a session checkpoint for state persistence.
    public func checkpointSession(
        sessionId: String,
        stepIndex: Int,
        activeAgent: String,
        statePayload: [String: AnyCodableSendable] = [:]
    ) async throws -> CheckpointRecord {
        return try await sidecarManager.checkpointSession(
            sessionId: sessionId,
            stepIndex: stepIndex,
            activeAgent: activeAgent,
            statePayload: statePayload
        )
    }

    /// Restores a session from its latest checkpoint.
    public func restoreSession(sessionId: String) async throws -> CheckpointRecord? {
        return try await sidecarManager.restoreSession(sessionId: sessionId)
    }

    /// Retrieves aggregate OpenTelemetry-backed metrics.
    public func getMetrics() async throws -> ExecutionMetricsRecord {
        if await !sidecarManager.isInitialized {
            _ = try await sidecarManager.initialize()
        }
        return try await sidecarManager.getMetrics()
    }

    public func cancel(sessionId: String) async throws {
        _ = try await sidecarManager.cancelSession(sessionId: sessionId)
    }

    public func pause(sessionId: String) async throws {
        _ = try await sidecarManager.pauseSession(sessionId: sessionId)
    }

    public func resume(sessionId: String) async throws {
        _ = try await sidecarManager.resumeSession(sessionId: sessionId)
    }
}
