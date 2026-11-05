import Foundation

/// Defines the data type of a tool parameter for schema generation and validation.
public enum ToolParameterType: String, Sendable, Codable, Equatable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
}

/// Metadata describing a single parameter expected by a tool.
public struct ToolParameter: Sendable, Codable, Equatable {
    public let name: String
    public let type: ToolParameterType
    public let description: String
    public let isRequired: Bool
    public let defaultValue: String?
    public let allowedValues: [String]?

    public init(
        name: String,
        type: ToolParameterType,
        description: String,
        isRequired: Bool = true,
        defaultValue: String? = nil,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.defaultValue = defaultValue
        self.allowedValues = allowedValues
    }
}

/// Functional category of an agent tool.
public enum ToolCategory: String, Sendable, Codable, CaseIterable, Equatable {
    case systemInfo = "System Information"
    case filesystem = "Filesystem & Documents"
    case computation = "Computation & Logic"
    case notification = "Notifications"
    case developer = "Developer & Diagnostics"
    case custom = "Custom Extensions"
}

/// The security classification and authorization requirement of a tool.
public enum ToolPermissionLevel: String, Sendable, Codable, Comparable, Equatable {
    /// Safe, read-only operations with zero side effects. May execute autonomously without interactive prompting.
    case safeReadOnly = "Safe Read-Only"
    /// Actions that access user documents, environment details, or dispatch notifications. Requires explicit user authorization.
    case userConfirmationRequired = "Confirmation Required"
    /// High-sensitivity or mutating operations. Must always be confirmed by the user and is never auto-granted.
    case restricted = "Restricted"

    private var rank: Int {
        switch self {
        case .safeReadOnly: return 0
        case .userConfirmationRequired: return 1
        case .restricted: return 2
        }
    }

    public static func < (lhs: ToolPermissionLevel, rhs: ToolPermissionLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Canonical schema definition of a tool, exported to LLMs for function calling.
public struct ToolDefinition: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]
    public let category: ToolCategory
    public let permissionLevel: ToolPermissionLevel

    public init(
        name: String,
        description: String,
        parameters: [ToolParameter] = [],
        category: ToolCategory = .custom,
        permissionLevel: ToolPermissionLevel = .safeReadOnly
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.category = category
        self.permissionLevel = permissionLevel
    }

    /// Generates a standard OpenAI / JSON-Schema compliant dictionary representation.
    public func toJSONSchema() -> [String: Any] {
        var propertiesDict: [String: Any] = [:]
        var requiredList: [String] = []

        for param in parameters {
            var pDict: [String: Any] = [
                "type": param.type.rawValue,
                "description": param.description
            ]
            if let allowed = param.allowedValues, !allowed.isEmpty {
                pDict["enum"] = allowed
            }
            if let defVal = param.defaultValue {
                pDict["default"] = defVal
            }
            propertiesDict[param.name] = pDict

            if param.isRequired {
                requiredList.append(param.name)
            }
        }

        var schema: [String: Any] = [
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": propertiesDict,
                "required": requiredList
            ]
        ]
        return schema
    }
}

/// Execution status of an evaluated tool call.
public enum ToolExecutionStatus: String, Sendable, Codable, Equatable {
    case success
    case failure
    case permissionDenied
    case userRejected
    case timedOut
    case cancelled
}

/// Structured result returned from executing a tool.
public struct ToolExecutionResult: Sendable, Equatable {
    public let toolName: String
    public let status: ToolExecutionStatus
    public let output: String
    public let errorDescription: String?
    public let durationSeconds: Double
    public let metadata: [String: String]

    public var isSuccess: Bool {
        status == .success
    }

    public init(
        toolName: String,
        status: ToolExecutionStatus,
        output: String,
        errorDescription: String? = nil,
        durationSeconds: Double = 0.0,
        metadata: [String: String] = [:]
    ) {
        self.toolName = toolName
        self.status = status
        self.output = output
        self.errorDescription = errorDescription
        self.durationSeconds = durationSeconds
        self.metadata = metadata
    }

    public static func success(toolName: String, output: String, duration: Double = 0.0, metadata: [String: String] = [:]) -> ToolExecutionResult {
        ToolExecutionResult(toolName: toolName, status: .success, output: output, durationSeconds: duration, metadata: metadata)
    }

    public static func failure(toolName: String, error: String, duration: Double = 0.0, metadata: [String: String] = [:]) -> ToolExecutionResult {
        ToolExecutionResult(toolName: toolName, status: .failure, output: "", errorDescription: error, durationSeconds: duration, metadata: metadata)
    }

    public static func denied(toolName: String, reason: String) -> ToolExecutionResult {
        ToolExecutionResult(toolName: toolName, status: .permissionDenied, output: "", errorDescription: reason)
    }

    public static func rejected(toolName: String, reason: String = "User declined operation.") -> ToolExecutionResult {
        ToolExecutionResult(toolName: toolName, status: .userRejected, output: "", errorDescription: reason)
    }

    public static func timedOut(toolName: String, timeoutSeconds: Double) -> ToolExecutionResult {
        ToolExecutionResult(toolName: toolName, status: .timedOut, output: "", errorDescription: "Execution exceeded timeout of \(timeoutSeconds) seconds.")
    }

    public static func cancelled(toolName: String) -> ToolExecutionResult {
        ToolExecutionResult(toolName: toolName, status: .cancelled, output: "", errorDescription: "Operation was cancelled.")
    }
}

/// Context provided to a tool during execution.
public struct ToolExecutionContext: Sendable {
    public let conversationId: UUID
    public let executionId: UUID
    public let timeoutSeconds: Double
    public let isInteractiveApprovalGranted: Bool

    public init(
        conversationId: UUID = UUID(),
        executionId: UUID = UUID(),
        timeoutSeconds: Double = 15.0,
        isInteractiveApprovalGranted: Bool = false
    ) {
        self.conversationId = conversationId
        self.executionId = executionId
        self.timeoutSeconds = timeoutSeconds
        self.isInteractiveApprovalGranted = isInteractiveApprovalGranted
    }
}

/// Standardized protocol that all Aether tools implement.
public protocol Tool: Sendable {
    var definition: ToolDefinition { get }
    func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult
}
