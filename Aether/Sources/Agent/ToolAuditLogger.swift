import Foundation
import os

/// A structured entry in the tool execution audit log.
public struct ToolAuditEntry: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let conversationId: UUID
    public let toolName: String
    public let parameters: [String: String]
    public let permissionLevel: ToolPermissionLevel
    public let status: ToolExecutionStatus
    public let durationSeconds: Double
    public let outputSnippet: String
    public let errorDescription: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        toolName: String,
        parameters: [String: String],
        permissionLevel: ToolPermissionLevel,
        status: ToolExecutionStatus,
        durationSeconds: Double,
        outputSnippet: String,
        errorDescription: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.toolName = toolName
        self.parameters = parameters
        self.permissionLevel = permissionLevel
        self.status = status
        self.durationSeconds = durationSeconds
        self.outputSnippet = outputSnippet
        self.errorDescription = errorDescription
        self.timestamp = timestamp
    }
}

/// Actor managing structured execution auditing and telemetry for all agent tool invocations.
public actor ToolAuditLogger {
    private var entries: [ToolAuditEntry] = []
    private let maxEntries: Int = 1000
    private let logger = Logger(subsystem: "com.aether.Aether", category: "ToolAudit")

    public init() {}

    /// Records a completed or aborted tool invocation in memory and the system log.
    public func record(
        conversationId: UUID,
        tool: ToolDefinition,
        parameters: [String: String],
        result: ToolExecutionResult
    ) {
        // Redact any parameters that might contain passwords, tokens, or auth headers
        var sanitizedParams: [String: String] = [:]
        for (k, v) in parameters {
            let lowerK = k.lowercased()
            if lowerK.contains("token") || lowerK.contains("key") || lowerK.contains("secret") || lowerK.contains("password") {
                sanitizedParams[k] = "[REDACTED]"
            } else {
                sanitizedParams[k] = v
            }
        }

        let snippet = String(result.output.prefix(256))
        let entry = ToolAuditEntry(
            conversationId: conversationId,
            toolName: tool.name,
            parameters: sanitizedParams,
            permissionLevel: tool.permissionLevel,
            status: result.status,
            durationSeconds: result.durationSeconds,
            outputSnippet: snippet,
            errorDescription: result.errorDescription,
            timestamp: Date()
        )

        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Unified os_log
        if result.isSuccess {
            logger.info("Tool executed: \(tool.name, privacy: .public) in \(result.durationSeconds, privacy: .public)s [status=\(result.status.rawValue, privacy: .public)]")
        } else {
            let err = result.errorDescription ?? "unknown error"
            logger.error("Tool failed: \(tool.name, privacy: .public) [status=\(result.status.rawValue, privacy: .public)]: \(err, privacy: .public)")
        }
    }

    /// Fetches audit entries for a given conversation.
    public func fetchEntries(for conversationId: UUID) -> [ToolAuditEntry] {
        entries.filter { $0.conversationId == conversationId }
    }

    /// Fetches the most recent audit entries across all conversations.
    public func fetchRecent(limit: Int = 50) -> [ToolAuditEntry] {
        Array(entries.suffix(limit).reversed())
    }

    /// Clears the in-memory audit log.
    public func clear() {
        entries.removeAll()
    }
}

