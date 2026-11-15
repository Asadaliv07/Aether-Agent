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
    case placeholderPath(path: String)

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
        case .placeholderPath(let path):
            return "Placeholder path '\(path)' is not a valid destination. A real destination path is required."
        }
    }
}

/// Actor enforcing least privilege, path sanitization, prompt injection screening,
/// and interactive authorization gates for agent tools.
public actor ToolSecurityGuard {
    private var sessionGrants: [UUID: Set<String>] = [:]
    private var blacklistedTools: Set<String> = []
    private var consumedTokens: Set<UUID> = []
    private var maxParameterLength: Int = 16_384
    private var authorizationDelayNanoseconds: UInt64 = 0
    public private(set) var directoryManager: AuthorizedDirectoryManager?

    public init(blacklistedTools: Set<String> = [], directoryManager: AuthorizedDirectoryManager? = nil) {
        self.blacklistedTools = blacklistedTools
        self.directoryManager = directoryManager
    }

    public func setDirectoryManager(_ manager: AuthorizedDirectoryManager) {
        self.directoryManager = manager
    }

    /// Sets an artificial delay for deterministic lifecycle testing.
    public func setAuthorizationDelay(seconds: Double) {
        self.authorizationDelayNanoseconds = UInt64(seconds * 1_000_000_000)
    }

    // MARK: - Authorization Gate

    /// Evaluates whether a tool execution request can proceed, needs user confirmation, or must be rejected.
    public func authorize(
        tool: ToolDefinition,
        parameters: [String: String],
        context: ToolExecutionContext
    ) async -> ToolAuthorizationDecision {
        if authorizationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: authorizationDelayNanoseconds)
        }

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

        // 2b. Fail closed if filesystem tool invoked without directory manager
        if tool.category == .filesystem && directoryManager == nil {
            return .denied(reason: "Filesystem access is prohibited because no authorized directory manager is configured.")
        }

        // 2c. Validate filesystem path parameters against authorized directory manager
        if let manager = directoryManager {
            let authorizedRoots = await manager.listAuthorizedRoots()
            let canonicalRootPaths = Set(authorizedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })

            let pathKeys = ["path", "source_path", "destination_path", "target_path", "save_path", "parent_path", "new_name"]
            for key in pathKeys {
                if let rawPath = parameters[key], !rawPath.isEmpty {
                    if Self.isPlaceholderPath(rawPath) {
                        return .denied(reason: "Placeholder path '\(rawPath)' is not a valid destination. A real destination path is required.")
                    }
                    if key == "new_name" {
                        if rawPath.contains("/") || rawPath.contains("\\") || rawPath.contains("..") || rawPath.contains("\0") {
                            return .denied(reason: "Parameter 'new_name' must be a simple filename without path separators or traversal sequences.")
                        }
                        continue
                    }
                    do {
                        let (canonicalURL, _) = try await manager.validateAndResolve(path: rawPath)
                        // Prohibit deleting, renaming, moving, overwriting, or modifying an authorized root directory itself
                        let isTargetingAnyRoot = canonicalRootPaths.contains(canonicalURL.path)
                        let mutatingOps: Set<String> = [
                            "delete_file", "rename_folder", "move_file", "copy_file",
                            "create_file", "write_file", "append_file", "edit_file"
                        ]
                        if isTargetingAnyRoot && mutatingOps.contains(tool.name) {
                            return .denied(reason: "Operating directly on an authorized root directory itself ('\(tool.name)') is prohibited.")
                        }
                        if tool.permissionLevel != .safeReadOnly || key == "save_path" {
                            let isRO = await manager.isReadOnly(url: canonicalURL)
                            if isRO {
                                return .denied(reason: "Directory '\(canonicalURL.path)' is authorized as read-only. Modifying operation '\(tool.name)' is prohibited.")
                            }
                        }
                    } catch {
                        return .denied(reason: "Filesystem path validation failed for parameter '\(key)': \(error.localizedDescription)")
                    }
                }
            }

            if let rawPaths = parameters["paths"], !rawPaths.isEmpty {
                var pathList: [String] = []
                if let data = rawPaths.data(using: .utf8),
                   let jsonArr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    pathList = jsonArr
                } else {
                    pathList = rawPaths.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                }
                for p in pathList {
                    if Self.isPlaceholderPath(p) {
                        return .denied(reason: "Placeholder path '\(p)' is not a valid destination.")
                    }
                    do {
                        _ = try await manager.validateAndResolve(path: p)
                    } catch {
                        return .denied(reason: "Filesystem path validation failed for path in 'paths': \(error.localizedDescription)")
                    }
                }
            }
        } else if let savePath = parameters["save_path"], !savePath.isEmpty {
            // A save_path was provided for screenshot/snapshot, but no directory manager is configured
            return .denied(reason: "Saving files to '\(savePath)' is prohibited because no authorized directory manager is configured.")
        }

        // 2d. Validate browser URL parameters
        if tool.category == .browser, let urlStr = parameters["url"] {
            guard let url = URL(string: urlStr), let scheme = url.scheme?.lowercased() else {
                return .denied(reason: "Malformed browser URL: '\(urlStr)'.")
            }
            if !["http", "https", "about"].contains(scheme) {
                return .denied(reason: "Unsafe browser URL scheme '\(scheme)'. Only http, https, and about:blank destinations are allowed.")
            }
            if let host = url.host?.lowercased() {
                if host == "169.254.169.254" || host == "metadata.google.internal" {
                    return .denied(reason: "Access to private cloud metadata service address '\(host)' is forbidden.")
                }
            }
        }

        // 2d. Validate desktop application whitelist
        if tool.category == .desktopApp, let appName = parameters["app_name"], !appName.isEmpty {
            let clean = appName.replacingOccurrences(of: ".app", with: "")
            let bannedApps: Set<String> = ["Terminal", "bash", "zsh", "sh", "curl", "rm", "sudo"]
            if bannedApps.contains(appName) || bannedApps.contains(clean) {
                return .denied(reason: "Application '\(appName)' is prohibited by active desktop application whitelist policy.")
            }
            let permitted = [
                "Finder", "Safari", "TextEdit", "Notes", "System Settings", "System Preferences",
                "Calculator", "Calendar", "Reminders", "Mail", "Maps", "Photos", "Messages",
                "Music", "Preview", "Xcode", "Keynote", "Pages", "Numbers",
                "Weather", "Clock", "News", "Stocks", "Books", "Podcasts", "Voice Memos",
                "Shortcuts", "App Store", "Freeform", "Google Chrome", "Chrome"
            ]
            let isAllowed = permitted.contains {
                $0.caseInsensitiveCompare(appName) == .orderedSame ||
                appName.localizedCaseInsensitiveContains($0) ||
                clean.caseInsensitiveCompare($0) == .orderedSame
            } || {
                let candidatePaths = [
                    "/Applications/\(clean).app",
                    "/System/Applications/\(clean).app"
                ]
                return candidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
            }()
            if !isAllowed {
                return .denied(reason: "Application '\(appName)' is not in the permitted desktop automation whitelist: \(permitted.joined(separator: ", ")).")
            }
        }

        // 3. Screen parameters for prompt injection signatures
        for (key, value) in parameters {
            let (isInjected, signature) = detectPromptInjection(in: value)
            if isInjected, let sig = signature {
                return .denied(reason: "Security Alert: Detected prompt injection pattern in parameter '\(key)': \(sig)")
            }
        }

        // 4. Validate cryptographic approval token if provided (replay, tampering, expiration protection)
        if let token = context.approvalToken {
            guard token.toolName == tool.name else {
                return .denied(reason: "Approval token tool mismatch: expected '\(tool.name)', got '\(token.toolName)'.")
            }
            guard !token.isConsumed && !consumedTokens.contains(token.tokenId) else {
                return .denied(reason: "Approval token has already been consumed (replay attack prevented).")
            }
            guard Date().timeIntervalSince1970 <= token.expiresAt else {
                return .denied(reason: "Approval token has expired.")
            }
            guard token.conversationId == context.conversationId else {
                return .denied(reason: "Approval token conversation context mismatch.")
            }
            let currentHash = ApprovalToken.computeArgumentHash(parameters: parameters)
            guard token.argumentHash == currentHash else {
                return .denied(reason: "Approval token argument hash mismatch: parameters have been modified or tampered with.")
            }
            consumedTokens.insert(token.tokenId)
            return .authorized
        }

        // 4b. If execution already carries interactive approval from the user, allow
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

        // 6. Evaluate by permission level (elevating to user confirmation if save_path mutation is requested on a read-only tool)
        let effectiveLevel: ToolPermissionLevel
        if tool.permissionLevel == .safeReadOnly, let savePath = parameters["save_path"], !savePath.isEmpty {
            effectiveLevel = .userConfirmationRequired
        } else {
            effectiveLevel = tool.permissionLevel
        }

        switch effectiveLevel {
        case .safeReadOnly:
            return .authorized

        case .userConfirmationRequired:
            let request = ToolConfirmationRequest(
                toolName: tool.name,
                permissionLevel: effectiveLevel,
                parameters: parameters,
                description: tool.description,
                riskSummary: "This operation reads system state, documents, writes screenshot files, or dispatches system notifications."
            )
            return .requiresUserConfirmation(request)

        case .restricted:
            let request = ToolConfirmationRequest(
                toolName: tool.name,
                permissionLevel: effectiveLevel,
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

    /// Identifies generic placeholder paths (e.g. '/path/to/new/folder') that must never be treated as valid destinations.
    public static func isPlaceholderPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }

        // Any string containing XML tag delimiters or bracket templates is a placeholder / leaked markup
        if trimmed.contains("<") || trimmed.contains(">") {
            return true
        }
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
           (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) {
            return true
        }
        if trimmed.hasPrefix("path/to") || trimmed.hasPrefix("/path/to") ||
           trimmed.hasPrefix("your/path") || trimmed.hasPrefix("/your/path") {
            return true
        }

        let placeholderSubstrings = [
            "/path/to/",
            "path/to/",
            "/your/path/",
            "your/path/",
            "<path>",
            "[path]",
            "{path}",
            "<folder>",
            "[folder]",
            "{folder}",
            "<filename>",
            "[filename]",
            "{filename}",
            "placeholder"
        ]

        for sub in placeholderSubstrings {
            if trimmed.contains(sub) {
                return true
            }
        }

        let exactMatches: Set<String> = [
            "/path",
            "path",
            "/destination",
            "destination",
            "...",
            "new/folder",
            "/new/folder",
            "example/path",
            "/example/path",
            "/path/to/new/folder",
            "path/to/new/folder",
            "/path/to/folder",
            "path/to/folder",
            "/path/to/file",
            "path/to/file",
            "/path/to/directory",
            "path/to/directory"
        ]

        return exactMatches.contains(trimmed)
    }

    public func validateParameters(tool: ToolDefinition, parameters: [String: String]) throws {
        // 1. Reject unexpected parameters or ambiguous parser conflict flags
        let declaredParamNames = Set(tool.parameters.map(\.name))
        for (key, val) in parameters {
            if key == "__ambiguous_parameter_conflict" {
                throw SecurityValidationError.disallowedEnumValue(name: "parameter_conflict", value: val, allowed: Array(declaredParamNames))
            }
            if !declaredParamNames.contains(key) {
                // Allow known compatibility aliases only for filesystem tools
                let isAllowedAlias = (tool.category == .filesystem && ["parent_path", "folder_name", "file_name"].contains(key))
                if !isAllowedAlias {
                    throw SecurityValidationError.disallowedEnumValue(name: key, value: "unexpected_parameter", allowed: Array(declaredParamNames))
                }
            }
        }

        for param in tool.parameters {
            guard let val = parameters[param.name] else {
                if param.isRequired {
                    throw SecurityValidationError.missingRequiredParameter(param.name)
                }
                continue
            }

            if param.isRequired && val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SecurityValidationError.missingRequiredParameter(param.name)
            }

            let effectiveMax = (param.name == "content" && tool.category == .filesystem) ? max(maxParameterLength, 1_048_576) : maxParameterLength
            if val.count > effectiveMax {
                throw SecurityValidationError.parameterLengthExceeded(name: param.name, max: effectiveMax)
            }

            // Check placeholder paths on filesystem path arguments
            let pathKeys = ["path", "source_path", "destination_path", "target_path", "directory", "save_path", "parent_path", "folder_name", "file_name", "new_name"]
            if pathKeys.contains(param.name) && Self.isPlaceholderPath(val) {
                throw SecurityValidationError.placeholderPath(path: val)
            }

            // Validate new_name is a simple filename component
            if param.name == "new_name" && (val.contains("/") || val.contains("\\") || val.contains("..") || val.contains("\0")) {
                throw SecurityValidationError.pathTraversalAttempt(path: val)
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
        let components = (trimmed as NSString).pathComponents
        if components.contains("..") {
            throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
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
