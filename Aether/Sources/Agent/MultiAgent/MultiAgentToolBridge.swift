import Foundation
import os

/// Bridges tool execution requests from the Python multi-agent sidecar back into
/// Aether's authoritative ToolSecurityGuard and ToolRegistry.
public actor MultiAgentToolBridge {
    private let securityGuard: ToolSecurityGuard
    private let toolRegistry: ToolRegistry
    private let logger = Logger(subsystem: "com.aether.Aether", category: "MultiAgentToolBridge")

    // State tracking to prevent duplicate dispatch and stale execution
    private var inFlightCalls: Set<String> = []
    private var isCancelled: Bool = false
    private var isPaused: Bool = false

    // Interactive confirmation callback if human approval is needed
    public var confirmationHandler: (@Sendable (ToolConfirmationRequest) async -> Bool)?

    public func setConfirmationHandler(_ handler: (@Sendable (ToolConfirmationRequest) async -> Bool)?) {
        self.confirmationHandler = handler
    }

    public init(securityGuard: ToolSecurityGuard, toolRegistry: ToolRegistry) {
        self.securityGuard = securityGuard
        self.toolRegistry = toolRegistry
    }

    public func setCancelled(_ cancelled: Bool) {
        self.isCancelled = cancelled
    }

    public func setPaused(_ paused: Bool) {
        self.isPaused = paused
    }

    /// Processes an incoming tool request from the Python sidecar through Aether's security pipeline.
    public func handleToolRequest(
        _ request: SidecarToolRequest,
        conversationId: UUID = UUID(),
        timeoutSeconds: Double = 30.0
    ) async -> SidecarToolResponse {
        let callId = request.callId
        let toolName = request.toolName
        let params = request.parameters
        let agentRole = request.agentRole

        logger.info("[ToolBridge] Handling tool request '\(toolName)' from agent '\(agentRole)' [callId: \(callId)]")

        // 1. Check for duplicate dispatch
        if inFlightCalls.contains(callId) {
            logger.warning("[ToolBridge] Duplicate tool dispatch rejected for callId: \(callId)")
            return SidecarToolResponse(
                callId: callId,
                isSuccess: false,
                result: "",
                error: "Duplicate tool call identifier rejected."
            )
        }
        inFlightCalls.insert(callId)
        defer { inFlightCalls.remove(callId) }

        // 2. Cancellation and Pause checks prior to evaluation
        if isCancelled {
            logger.warning("[ToolBridge] Tool request rejected: Session is cancelled.")
            return SidecarToolResponse(
                callId: callId,
                isSuccess: false,
                result: "",
                error: "Execution cancelled by user."
            )
        }
        if isPaused {
            logger.warning("[ToolBridge] Tool request rejected: Session is currently paused.")
            return SidecarToolResponse(
                callId: callId,
                isSuccess: false,
                result: "",
                error: "Execution is paused."
            )
        }

        // 3. Lookup tool in ToolRegistry
        guard let tool = await toolRegistry.tool(named: toolName) else {
            logger.error("[ToolBridge] Tool '\(toolName)' is not registered in ToolRegistry.")
            return SidecarToolResponse(
                callId: callId,
                isSuccess: false,
                result: "",
                error: "Tool '\(toolName)' is not registered."
            )
        }

        let def = tool.definition

        // 4. Construct execution context
        var isApproved = false
        var approvalToken: ApprovalToken? = nil
        let context = ToolExecutionContext(
            conversationId: conversationId,
            timeoutSeconds: timeoutSeconds,
            isInteractiveApprovalGranted: false
        )

        // 5. Authorize through authoritative ToolSecurityGuard
        let authDecision = await securityGuard.authorize(tool: def, parameters: params, context: context)

        switch authDecision {
        case .denied(let reason):
            logger.warning("[ToolBridge] Tool '\(toolName)' denied by ToolSecurityGuard: \(reason)")
            return SidecarToolResponse(
                callId: callId,
                isSuccess: false,
                result: "",
                error: "Permission denied: \(reason)"
            )

        case .requiresUserConfirmation(let confReq):
            logger.info("[ToolBridge] Tool '\(toolName)' requires user confirmation: \(confReq.riskSummary)")
            if let handler = confirmationHandler {
                let approved = await handler(confReq)
                if !approved {
                    return SidecarToolResponse(
                        callId: callId,
                        isSuccess: false,
                        result: "",
                        error: "User rejected confirmation for tool '\(toolName)'."
                    )
                }
                // Mint a cryptographically bound single-use approval token
                let argHash = ApprovalToken.computeArgumentHash(parameters: params)
                approvalToken = ApprovalToken(
                    toolName: toolName,
                    argumentHash: argHash,
                    executionId: callId,
                    conversationId: conversationId
                )
                isApproved = true
            } else {
                return SidecarToolResponse(
                    callId: callId,
                    isSuccess: false,
                    result: "",
                    error: "Requires interactive user confirmation: \(confReq.riskSummary)"
                )
            }

        case .authorized:
            isApproved = true
        }

        // 6. Post-authorization cancellation and pause check
        if isCancelled {
            return SidecarToolResponse(callId: callId, isSuccess: false, result: "", error: "Execution cancelled.")
        }
        if isPaused {
            return SidecarToolResponse(callId: callId, isSuccess: false, result: "", error: "Execution paused.")
        }

        // 7. Commit dispatch and execute via ToolRegistry
        let execContext = ToolExecutionContext(
            conversationId: conversationId,
            timeoutSeconds: timeoutSeconds,
            isInteractiveApprovalGranted: isApproved,
            approvalToken: approvalToken
        )

        let result = await toolRegistry.execute(toolName: toolName, parameters: params, context: execContext)

        if result.isSuccess {
            logger.info("[ToolBridge] Tool '\(toolName)' executed successfully.")
            return SidecarToolResponse(callId: callId, isSuccess: true, result: result.output, error: nil)
        } else {
            logger.warning("[ToolBridge] Tool '\(toolName)' failed: \(result.errorDescription ?? "unknown")")
            return SidecarToolResponse(callId: callId, isSuccess: false, result: result.output, error: result.errorDescription)
        }
    }
}
