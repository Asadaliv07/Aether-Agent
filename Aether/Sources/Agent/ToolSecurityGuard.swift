import Foundation
import os

/// The result of a security check prior to invoking a tool.
public enum ToolAuthorizationDecision: Sendable, Equatable {
    case authorized
    case requiresUserConfirmation(ToolConfirmationRequest)
    case denied(reason: String)
}

/// A structured user confirmation request presented to the UI when an operation requires explicit approval.
public struct ToolConfirmationRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolName: String
    public let permissionLevel: ToolPermissionLevel
    public let parameters: [String: String]
    public let description: String
    public let riskSummary: String

    public init(
        id: UUID = UUID(),
        toolName: String,
        permissionLevel: ToolPermissionLevel,
        parameters: [String: String],
        description: String,
        riskSummary: String
    ) {
        self.id = id
        self.toolName = toolName
        self.permissionLevel = permissionLevel
        self.parameters = parameters
        self.description = description
        self.riskSummary = riskSummary
    }
}

/// Security violation errors during input validation, path sanitization, or injection scans.
public enum SecurityValidationError: LocalizedError, Equatable {
    case missingRequiredParameter(String)
    case invalidParameterType(name: String, expected: String, actual: String)
    case disallowedEnumValue(name: String, value: String, allowed: [String])
    case pathTraversalAttempt(path: String)
    case protectedSystemPath(path: String)
    case potentialPromptInjection(pattern: String)
    case toolBlacklisted(String)
    case parameterLengthExceeded(name: String, max: Int)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredParameter(let name):
            return "Required parameter '\(name)' is missing."
        case .invalidParameterType(let name, let exp, let act):
            return "Parameter '\(name)' must be of type \(exp), but received \(act)."
        case .disallowedEnumValue(let name, let val, let allowed):
            return "Value '\(val)' for '\(name)' is invalid. Allowed: \(allowed.joined(separator: ", "))."
        case .pathTraversalAttempt(let path):
            return "Path traversal vector detected in path: '\(path)'."
        case .protectedSystemPath(let path):
            return "Access to protected system path is forbidden: '\(path)'."
        case .potentialPromptInjection(let pattern):
            return "Execution rejected due to detected prompt injection attempt: '\(pattern)'."
        case .toolBlacklisted(let name):
            return "Tool '\(name)' is disabled by local security policy."
        case .parameterLengthExceeded(let name, let max):
            return "Parameter '\(name)' exceeds maximum permitted length of \(max) characters."
        }
    }
}

/// Actor enforcing least privilege, path sanitization, prompt injection screening,
/// and interactive authorization gates for agent tools.
public actor ToolSecurityGuard {
    private var sessionGrants: [UUID: Set<String>] = [:]
    private var blacklistedTools: Set<String> = []
    private var maxParameterLength: Int = 16_384

    public init(blacklistedTools: Set<String> = []) {
        self.blacklistedTools = blacklistedTools
    }

    // MARK: - Authorization Gate

    /// Evaluates whether a tool execution request can proceed, needs user confirmation, or must be rejected.
    public func authorize(
        tool: ToolDefinition,
        parameters: [String: String],
        context: ToolExecutionContext
    ) async -> ToolAuthorizationDecision {
        // 1. Blacklist check
        if blacklistedTools.contains(tool.name) {
            return .denied(reason: "Tool '\(tool.name)' is prohibited by active security policy.")
        }

        // 2. Validate input parameters first
        do {
            try validateParameters(tool: tool, parameters: parameters)
        } catch {
            return .denied(reason: error.localizedDescription)
        }

        // 3. Screen parameters for prompt injection signatures
        for (key, value) in parameters {
            let (isInjected, signature) = detectPromptInjection(in: value)
            if isInjected, let sig = signature {
                return .denied(reason: "Security Alert: Detected prompt injection pattern in parameter '\(key)': \(sig)")
            }
        }

        // 4. If execution already carries interactive approval from the user, allow
        if context.isInteractiveApprovalGranted {
            return .authorized
        }

        // 5. Check if user already authorized this tool in the active conversation session
        if let sessionSet = sessionGrants[context.conversationId], sessionSet.contains(tool.name) {
            // Restricted operations always require fresh approval, even if previously granted in session
            if tool.permissionLevel != .restricted {
                return .authorized
            }
        }

        // 6. Evaluate by permission level
        switch tool.permissionLevel {
        case .safeReadOnly:
            return .authorized

        case .userConfirmationRequired:
            let request = ToolConfirmationRequest(
                toolName: tool.name,
                permissionLevel: tool.permissionLevel,
                parameters: parameters,
                description: tool.description,
                riskSummary: "This operation reads system state, documents, or dispatches system notifications."
            )
            return .requiresUserConfirmation(request)

        case .restricted:
            let request = ToolConfirmationRequest(
                toolName: tool.name,
                permissionLevel: tool.permissionLevel,
                parameters: parameters,
                description: tool.description,
                riskSummary: "WARNING: High-sensitivity operation that may alter external state or write files."
            )
            return .requiresUserConfirmation(request)
        }
    }

    // MARK: - Session Permission Management

    /// Grants permission for a specific tool for the duration of a conversation session.
    public func grantSessionPermission(conversationId: UUID, toolName: String) {
        var set = sessionGrants[conversationId] ?? []
        set.insert(toolName)
        sessionGrants[conversationId] = set
    }

    /// Revokes all session permissions for a conversation.
    public func revokeSessionPermissions(conversationId: UUID) {
        sessionGrants.removeValue(forKey: conversationId)
    }

    // MARK: - Parameter Validation

    public func validateParameters(tool: ToolDefinition, parameters: [String: String]) throws {
        for param in tool.parameters {
            guard let val = parameters[param.name] else {
                if param.isRequired {
                    throw SecurityValidationError.missingRequiredParameter(param.name)
                }
                continue
            }

            if val.count > maxParameterLength {
                throw SecurityValidationError.parameterLengthExceeded(name: param.name, max: maxParameterLength)
            }

            // Type check
            switch param.type {
            case .integer:
                if Int(val.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                    throw SecurityValidationError.invalidParameterType(name: param.name, expected: "integer", actual: val)
                }
            case .number:
                if Double(val.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                    throw SecurityValidationError.invalidParameterType(name: param.name, expected: "number", actual: val)
                }
            case .boolean:
                let lower = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lower != "true" && lower != "false" && lower != "1" && lower != "0" {
                    throw SecurityValidationError.invalidParameterType(name: param.name, expected: "boolean", actual: val)
                }
            default:
                break
            }

            // Allowed enum values
            if let allowed = param.allowedValues, !allowed.isEmpty {
                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                if !allowed.contains(trimmed) {
                    throw SecurityValidationError.disallowedEnumValue(name: param.name, value: trimmed, allowed: allowed)
                }
            }
        }
    }

    // MARK: - Path Sanitization & Traversal Prevention

    /// Validates and canonicalizes a filesystem path to prevent sandbox escapes and unauthorized directory reads.
    nonisolated public func sanitizeAndValidatePath(
        _ rawPath: String,
        allowedPrefixes: [String]? = nil
    ) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
        }

        // 1. Check for null-byte or illegal URL-encoded characters
        if trimmed.contains("\0") || trimmed.contains("%00") {
            throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
        }

        // 2. Expand tilde safely
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath

        // 3. Prohibit path traversal segments
        if trimmed.contains("..") {
            // Verify standardized path does not escape
            let components = (trimmed as NSString).pathComponents
            if components.contains("..") {
                // If it resolves outside intended boundaries
                if !standardized.hasPrefix("/") {
                    throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
                }
            }
        }

        // 4. Forbidden protected system root paths
        let protectedRoots = [
            "/etc", "/private/etc",
            "/var/root", "/private/var/root",
            "/System", "/Library/Keychains",
            "/usr/bin", "/bin", "/sbin"
        ]
        for prot in protectedRoots {
            if standardized == prot || standardized.hasPrefix(prot + "/") {
                throw SecurityValidationError.protectedSystemPath(path: standardized)
            }
        }

        // 5. Sensitive user profile directories
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let sensitiveUserDirs = [
            userHome + "/.ssh",
            userHome + "/.gnupg",
            userHome + "/.aws",
            userHome + "/.config/gh",
            userHome + "/Library/Keychains"
        ]
        for sens in sensitiveUserDirs {
            if standardized == sens || standardized.hasPrefix(sens + "/") {
                throw SecurityValidationError.protectedSystemPath(path: standardized)
            }
        }

        // 6. If allowed prefixes are specified, ensure path falls within one of them
        if let allowed = allowedPrefixes, !allowed.isEmpty {
            let isAllowed = allowed.contains { prefix in
                let stdPrefix = (prefix as NSString).standardizingPath
                return standardized == stdPrefix || standardized.hasPrefix(stdPrefix + "/")
            }
            if !isAllowed {
                throw SecurityValidationError.protectedSystemPath(path: standardized)
            }
        }

        return standardized
    }

    // MARK: - Prompt Injection Screening

    /// Scans text for malicious instruction overrides and system hijacking attempts.
    nonisolated public func detectPromptInjection(in text: String) -> (hasInjection: Bool, matchedPattern: String?) {
        let lower = text.lowercased()

        let patterns = [
            "ignore previous instructions",
            "ignore all previous instructions",
            "disregard all previous instructions",
            "disregard previous instructions",
            "system prompt override",
            "override system prompt",
            "<|im_start|>system",
            "<|im_start|>assistant",
            "<|endoftext|>",
            "[inst] <<sys>>",
            "you are now an unrestricted",
            "jailbreak",
            "forget your rules",
            "new system instructions:"
        ]

        for p in patterns {
            if lower.contains(p) {
                return (true, p)
            }
        }

        return (false, nil)
    }
}
