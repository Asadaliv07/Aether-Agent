import Foundation
import os

/// Thread-safe registry and execution dispatcher for agent tools.
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]
    public let securityGuard: ToolSecurityGuard
    public let auditLogger: ToolAuditLogger

    public init(
        securityGuard: ToolSecurityGuard = ToolSecurityGuard(),
        auditLogger: ToolAuditLogger = ToolAuditLogger()
    ) {
        self.securityGuard = securityGuard
        self.auditLogger = auditLogger
    }

    // MARK: - Registration & Discovery

    /// Registers a tool in the registry.
    public func register(_ tool: any Tool) {
        tools[tool.definition.name] = tool
    }

    /// Unregisters a tool by name.
    public func unregister(named name: String) {
        tools.removeValue(forKey: name)
    }

    /// Looks up a registered tool by name.
    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    /// All registered tool definitions.
    public var definitions: [ToolDefinition] {
        Array(tools.values.map { $0.definition }).sorted { $0.name < $1.name }
    }

    /// Filtered definitions by category.
    public func definitions(in category: ToolCategory) -> [ToolDefinition] {
        definitions.filter { $0.category == category }
    }

    // MARK: - Prompt Formatting for LLMs

    /// Formats all registered tools as a structured JSON array for model system prompts.
    public func formatToolsForPrompt(style: PromptToolStyle = .xmlTags) -> String {
        switch style {
        case .jsonSchema:
            let schemas = definitions.map { $0.toJSONSchema() }
            if let data = try? JSONSerialization.data(withJSONObject: schemas, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[]"

        case .xmlTags:
            var output = "<tools>\n"
            for def in definitions {
                output.append("  <tool>\n")
                output.append("    <name>\(def.name)</name>\n")
                output.append("    <description>\(def.description)</description>\n")
                output.append("    <permission>\(def.permissionLevel.rawValue)</permission>\n")
                output.append("    <parameters>\n")
                for param in def.parameters {
                    let req = param.isRequired ? "required" : "optional"
                    var extra = ""
                    if let allowed = param.allowedValues {
                        extra = " [allowed: \(allowed.joined(separator: ", "))]"
                    }
                    output.append("      <parameter name=\"\(param.name)\" type=\"\(param.type.rawValue)\" presence=\"\(req)\">\(param.description)\(extra)</parameter>\n")
                }
                output.append("    </parameters>\n")
                output.append("  </tool>\n")
            }
            output.append("</tools>")
            return output

        case .markdown:
            var output = "### Available Agent Tools\n\n"
            for def in definitions {
                output.append("#### `\(def.name)` (\(def.permissionLevel.rawValue))\n")
                output.append("\(def.description)\n")
                if !def.parameters.isEmpty {
                    output.append("- Parameters:\n")
                    for p in def.parameters {
                        let req = p.isRequired ? "(Required)" : "(Optional)"
                        output.append("  - `\(p.name)` (\(p.type.rawValue), \(req)): \(p.description)\n")
                    }
                }
                output.append("\n")
            }
            return output
        }
    }

    // MARK: - Asynchronous Execution with Timeout & Cancellation

    /// Executes a tool with parameter validation, permission checks, structured timeout handling, and audit logging.
    public func execute(
        toolName: String,
        parameters: [String: String],
        context: ToolExecutionContext
    ) async -> ToolExecutionResult {
        guard let tool = tools[toolName] else {
            let res = ToolExecutionResult.failure(toolName: toolName, error: "Tool '\(toolName)' is not registered.")
            await auditLogger.record(
                conversationId: context.conversationId,
                tool: ToolDefinition(name: toolName, description: "Unknown tool"),
                parameters: parameters,
                result: res
            )
            return res
        }

        let def = tool.definition

        // 1. Authorize via Security Guard
        let authDecision = await securityGuard.authorize(tool: def, parameters: parameters, context: context)
        switch authDecision {
        case .denied(let reason):
            let res = ToolExecutionResult.denied(toolName: toolName, reason: reason)
            await auditLogger.record(conversationId: context.conversationId, tool: def, parameters: parameters, result: res)
            return res

        case .requiresUserConfirmation(let request):
            let res = ToolExecutionResult.rejected(toolName: toolName, reason: "Requires interactive user confirmation: \(request.riskSummary)")
            await auditLogger.record(conversationId: context.conversationId, tool: def, parameters: parameters, result: res)
            return res

        case .authorized:
            break
        }

        // 2. Execute with timeout race
        let startTime = ContinuousClock.now
        let timeoutSec = context.timeoutSeconds

        do {
            let result: ToolExecutionResult = try await withThrowingTaskGroup(of: ToolExecutionResult.self) { group in
                // Worker task
                group.addTask {
                    try Task.checkCancellation()
                    return try await tool.execute(parameters: parameters, context: context)
                }

                // Timeout watchdog task
                group.addTask {
                    let nanos = UInt64(timeoutSec * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                    return ToolExecutionResult.timedOut(toolName: toolName, timeoutSeconds: timeoutSec)
                }

                // First to finish wins
                guard let firstResult = try await group.next() else {
                    return ToolExecutionResult.failure(toolName: toolName, error: "Execution task terminated unexpectedly.")
                }
                group.cancelAll()
                return firstResult
            }

            let elapsed = startTime.duration(to: .now)
            let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let timedResult = ToolExecutionResult(
                toolName: toolName,
                status: result.status,
                output: result.output,
                errorDescription: result.errorDescription,
                durationSeconds: secs,
                metadata: result.metadata
            )

            await auditLogger.record(conversationId: context.conversationId, tool: def, parameters: parameters, result: timedResult)
            return timedResult

        } catch is CancellationError {
            let cancelledRes = ToolExecutionResult.cancelled(toolName: toolName)
            await auditLogger.record(conversationId: context.conversationId, tool: def, parameters: parameters, result: cancelledRes)
            return cancelledRes
        } catch {
            let elapsed = startTime.duration(to: .now)
            let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let failRes = ToolExecutionResult.failure(toolName: toolName, error: error.localizedDescription, duration: secs)
            await auditLogger.record(conversationId: context.conversationId, tool: def, parameters: parameters, result: failRes)
            return failRes
        }
    }
}

/// Prompt formatting styles for tool export to LLMs.
public enum PromptToolStyle: Sendable {
    case xmlTags
    case jsonSchema
    case markdown
}

