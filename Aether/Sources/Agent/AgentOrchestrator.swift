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
        maxSteps: Int = 5
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
        let prefix = base.isEmpty ? "You are Aether, an intelligent, privacy-first personal AI assistant engineered natively for Apple Silicon." : base

        return """
        \(prefix)

        You have access to the following local agent tools:
        \(toolsDocumentation)

        TOOL USAGE RULES:
        1. When you need information to answer a user's question, call an available tool.
        2. To invoke a tool, enclose the thought process in <thought>...</thought> and the tool invocation in <tool_call>...</tool_call>.
        Example format:
        <thought>
        I need to inspect the system hardware specifications.
        </thought>
        <tool_call>
        <name>system_info</name>
        <parameters>
        </parameters>
        </tool_call>

        3. When a tool has parameters:
        <tool_call>
        <name>calculator</name>
        <parameters>
        <expression>(15 * 4) + 12</expression>
        </parameters>
        </tool_call>

        4. After receiving a <tool_response>, analyze the result and provide a clear, helpful response to the user.
        5. If you do not need any tools, respond directly to the user without emitting <tool_call>.
        """
    }

    // MARK: - Tool Call Parsing

    /// Deterministically extracts `<thought>` and `<tool_call>` blocks from generated text.
    public static func parseToolCall(from text: String) -> ToolCallInvocation? {
        // 1. Extract thought if present
        var thought: String? = nil
        if let thoughtStart = text.range(of: "<thought>"),
           let thoughtEnd = text.range(of: "</thought>", range: thoughtStart.upperBound..<text.endIndex) {
            thought = String(text[thoughtStart.upperBound..<thoughtEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Extract <tool_call>...</tool_call>
        guard let callStart = text.range(of: "<tool_call>"),
              let callEnd = text.range(of: "</tool_call>", range: callStart.upperBound..<text.endIndex) else {
            return parseJSONToolCall(from: text, thought: thought)
        }

        let body = String(text[callStart.upperBound..<callEnd.lowerBound])

        // Extract <name>...</name>
        guard let nameStart = body.range(of: "<name>"),
              let nameEnd = body.range(of: "</name>", range: nameStart.upperBound..<body.endIndex) else {
            return nil
        }
        let toolName = String(body[nameStart.upperBound..<nameEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract parameters inside <parameters>...</parameters>
        var params: [String: String] = [:]
        if let paramBlockStart = body.range(of: "<parameters>"),
           let paramBlockEnd = body.range(of: "</parameters>", range: paramBlockStart.upperBound..<body.endIndex) {
            let paramSection = String(body[paramBlockStart.upperBound..<paramBlockEnd.lowerBound])
            params = parseXMLTags(from: paramSection)
        }

        return ToolCallInvocation(toolName: toolName, parameters: params, rawThought: thought)
    }

    private static func parseXMLTags(from text: String) -> [String: String] {
        var results: [String: String] = [:]
        var scanner = text

        while let openStart = scanner.range(of: "<") {
            let rest = scanner[openStart.upperBound...]
            guard let openEnd = rest.range(of: ">") else { break }
            let tagName = String(rest[..<openEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Ignore parameter tags with attributes or comments
            let cleanTag = tagName.components(separatedBy: .whitespaces).first ?? tagName
            guard !cleanTag.isEmpty, !cleanTag.hasPrefix("/") else {
                scanner = String(rest[openEnd.upperBound...])
                continue
            }

            let closeTag = "</\(cleanTag)>"
            let afterOpen = rest[openEnd.upperBound...]
            guard let closeRange = afterOpen.range(of: closeTag) else {
                scanner = String(afterOpen)
                continue
            }

            let value = String(afterOpen[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            results[cleanTag] = value
            scanner = String(afterOpen[closeRange.upperBound...])
        }

        return results
    }

    private static func parseJSONToolCall(from text: String, thought: String?) -> ToolCallInvocation? {
        // Fallback for models emitting markdown JSON blocks: ```json { "name": "tool", "parameters": { ... } } ```
        guard let jsonBlockStart = text.range(of: "```json"),
              let jsonBlockEnd = text.range(of: "```", range: jsonBlockStart.upperBound..<text.endIndex) else {
            return nil
        }

        let jsonString = String(text[jsonBlockStart.upperBound..<jsonBlockEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = (dict["name"] as? String) ?? (dict["tool"] as? String) else {
            return nil
        }

        var params: [String: String] = [:]
        if let pDict = dict["parameters"] as? [String: Any] {
            for (k, v) in pDict {
                params[k] = "\(v)"
            }
        }

        return ToolCallInvocation(toolName: name, parameters: params, rawThought: thought)
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

    // MARK: - Multi-Step Execution Session

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
}

