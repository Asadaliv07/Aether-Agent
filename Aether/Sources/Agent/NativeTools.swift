import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 1. System Information Tool

/// Safe, read-only tool providing macOS platform hardware and runtime telemetry.
public struct SystemInfoTool: Tool {
    public let definition = ToolDefinition(
        name: "system_info",
        description: "Returns macOS hardware metrics, Apple Silicon chip information, unified memory capacity, active CPU core count, and macOS version.",
        parameters: [],
        category: .systemInfo,
        permissionLevel: .safeReadOnly
    )

    public init() {}

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersionString
        let processorCount = processInfo.activeProcessorCount
        let physicalMemoryBytes = processInfo.physicalMemory
        let memoryGB = Double(physicalMemoryBytes) / (1024 * 1024 * 1024)

        // Read hw.model via sysctl
        var modelString = "Mac (Apple Silicon)"
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 {
                modelString = String(cString: model)
            }
        }

        let output = """
        Platform: Apple Silicon macOS
        Model: \(modelString)
        OS Version: \(osVersion)
        Active CPU Cores: \(processorCount)
        Physical Unified Memory: \(String(format: "%.2f", memoryGB)) GB
        Sandboxed: true
        Thermal State: \(Self.thermalStateString(processInfo.thermalState))
        """

        return .success(toolName: definition.name, output: output, metadata: [
            "cores": "\(processorCount)",
            "memoryGB": String(format: "%.2f", memoryGB)
        ])
    }

    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal (Cool)"
        case .fair: return "Fair"
        case .serious: return "Serious (Throttling possible)"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - 2. Safe Sandboxed File Reader Tool

/// Reads text, code, or markdown files with path canonicalization, sandbox safety, and length bounds.
public struct SandboxedFileReaderTool: Tool {
    public let definition = ToolDefinition(
        name: "file_reader",
        description: "Reads the content of a text, markdown, or code file from permitted local paths with path traversal protection.",
        parameters: [
            ToolParameter(name: "path", type: .string, description: "Absolute or sandbox-relative filesystem path of the file to inspect."),
            ToolParameter(name: "max_lines", type: .integer, description: "Maximum number of lines to read (1-1000, default: 200).", isRequired: false, defaultValue: "200")
        ],
        category: .filesystem,
        permissionLevel: .userConfirmationRequired
    )

    private let securityGuard: ToolSecurityGuard

    public init(securityGuard: ToolSecurityGuard = ToolSecurityGuard()) {
        self.securityGuard = securityGuard
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let rawPath = parameters["path"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'path'.")
        }

        let maxLines = Int(parameters["max_lines"] ?? "200") ?? 200
        let clampedMaxLines = max(1, min(maxLines, 1000))

        // Validate and sanitize path
        let sanitizedPath: String
        do {
            sanitizedPath = try securityGuard.sanitizeAndValidatePath(rawPath)
        } catch {
            return .denied(toolName: definition.name, reason: error.localizedDescription)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sanitizedPath, isDirectory: &isDir) else {
            return .failure(toolName: definition.name, error: "File not found at path: \(sanitizedPath)")
        }

        guard !isDir.boolValue else {
            return .failure(toolName: definition.name, error: "Path refers to a directory, not a regular file: \(sanitizedPath)")
        }

        // Check file size (refuse files larger than 10MB)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sanitizedPath),
           let fileSize = attrs[.size] as? Int64, fileSize > 10 * 1024 * 1024 {
            return .failure(toolName: definition.name, error: "File size exceeds 10MB limit (\(fileSize / (1024 * 1024))MB).")
        }

        // Read file contents
        do {
            let fileURL = URL(fileURLWithPath: sanitizedPath)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let truncated = lines.prefix(clampedMaxLines)
            var result = truncated.joined(separator: "\n")

            if lines.count > clampedMaxLines {
                result += "\n\n... [Truncated: showing first \(clampedMaxLines) of \(lines.count) lines]"
            }

            return .success(toolName: definition.name, output: result, metadata: [
                "totalLines": "\(lines.count)",
                "displayedLines": "\(truncated.count)",
                "path": sanitizedPath
            ])
        } catch {
            return .failure(toolName: definition.name, error: "Failed to read file: \(error.localizedDescription)")
        }
    }
}

// MARK: - 3. Document Text & Structure Extractor Tool

/// Inspects and summarizes structural documents (JSON, CSV, Markdown, plain text).
public struct DocumentTextExtractorTool: Tool {
    public let definition = ToolDefinition(
        name: "extract_document_text",
        description: "Extracts structured metadata, headings, key-value summaries, or line counts from JSON, Markdown, CSV, or text files.",
        parameters: [
            ToolParameter(name: "path", type: .string, description: "Filesystem path to the document to parse.")
        ],
        category: .filesystem,
        permissionLevel: .userConfirmationRequired
    )

    private let securityGuard: ToolSecurityGuard

    public init(securityGuard: ToolSecurityGuard = ToolSecurityGuard()) {
        self.securityGuard = securityGuard
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let rawPath = parameters["path"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'path'.")
        }

        let sanitizedPath: String
        do {
            sanitizedPath = try securityGuard.sanitizeAndValidatePath(rawPath)
        } catch {
            return .denied(toolName: definition.name, reason: error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: sanitizedPath) else {
            return .failure(toolName: definition.name, error: "Document not found at path: \(sanitizedPath)")
        }

        let fileURL = URL(fileURLWithPath: sanitizedPath)
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return .failure(toolName: definition.name, error: "Document is not valid UTF-8 text.")
        }

        let ext = fileURL.pathExtension.lowercased()
        var summary = "Document Type: .\(ext)\nFile Size: \(data.count) bytes\n\n"

        if ext == "json" {
            if let obj = try? JSONSerialization.jsonObject(with: data) {
                if let dict = obj as? [String: Any] {
                    summary += "Root: Object (\(dict.count) keys)\nKeys: \(dict.keys.sorted().joined(separator: ", "))\n"
                } else if let arr = obj as? [Any] {
                    summary += "Root: Array (\(arr.count) elements)\n"
                }
            } else {
                summary += "Notice: Malformed JSON syntax.\n"
            }
        } else if ext == "md" || ext == "markdown" {
            let headers = content.components(separatedBy: .newlines).filter { $0.hasPrefix("#") }
            summary += "Markdown Sections (\(headers.count) headings):\n"
            for h in headers.prefix(20) {
                summary += "  \(h)\n"
            }
        } else if ext == "csv" {
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            if let first = lines.first {
                summary += "CSV Headers: \(first)\nTotal Rows: \(lines.count - 1)\n"
            }
        } else {
            let lines = content.components(separatedBy: .newlines)
            let wordCount = content.split { $0.isWhitespace || $0.isNewline }.count
            summary += "Plain Text: \(lines.count) lines, \(wordCount) words.\n"
        }

        let preview = String(content.prefix(500))
        summary += "\nPreview:\n\(preview)\(content.count > 500 ? "..." : "")"

        return .success(toolName: definition.name, output: summary, metadata: ["type": ext])
    }
}

// MARK: - 4. Safe Math Calculator Tool

/// Pure Swift mathematical expression parser and evaluator.
/// Completely free of shell injection, arbitrary code evaluation, or external interpreters.
public struct SafeCalculatorTool: Tool {
    public let definition = ToolDefinition(
        name: "calculator",
        description: "Calculates mathematical expressions using standard arithmetic operators (+, -, *, /, %, ^) and functions (sqrt, sin, cos, tan, abs, log, ln, floor, ceil).",
        parameters: [
            ToolParameter(name: "expression", type: .string, description: "Mathematical expression to evaluate, e.g. '(12.5 * 4) + sqrt(144)'.")
        ],
        category: .computation,
        permissionLevel: .safeReadOnly
    )

    public init() {}

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let expr = parameters["expression"], !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'expression'.")
        }

        do {
            let result = try MathParser.evaluate(expr)
            // Format cleanly
            let formatted: String
            if result.rounded() == result && !result.isInfinite && !result.isNaN && abs(result) < 1e12 {
                formatted = "\(Int64(result))"
            } else {
                formatted = "\(result)"
            }
            return .success(toolName: definition.name, output: formatted, metadata: ["expression": expr])
        } catch {
            return .failure(toolName: definition.name, error: "Calculation error: \(error.localizedDescription)")
        }
    }
}

/// Recursive descent parser for safe arithmetic evaluation.
public enum MathParser {
    public enum MathError: LocalizedError, Equatable {
        case invalidSyntax(String)
        case divisionByZero
        case unknownFunction(String)
        case mismatchedParentheses

        public var errorDescription: String? {
            switch self {
            case .invalidSyntax(let msg): return "Invalid syntax: \(msg)"
            case .divisionByZero: return "Division by zero."
            case .unknownFunction(let name): return "Unknown math function '\(name)'."
            case .mismatchedParentheses: return "Mismatched parentheses."
            }
        }
    }

    public static func evaluate(_ expression: String) throws -> Double {
        var tokens = try tokenize(expression)
        let val = try parseExpression(&tokens)
        guard tokens.isEmpty else {
            throw MathError.invalidSyntax("Unexpected token at end of expression: '\(tokens[0])'")
        }
        return val
    }

    private static func tokenize(_ expr: String) throws -> [String] {
        var tokens: [String] = []
        var currentToken = ""
        let chars = Array(expr)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c.isWhitespace {
                if !currentToken.isEmpty {
                    tokens.append(currentToken)
                    currentToken = ""
                }
                i += 1
                continue
            }

            if "+-*/%^(),".contains(c) {
                if !currentToken.isEmpty {
                    tokens.append(currentToken)
                    currentToken = ""
                }
                tokens.append(String(c))
                i += 1
                continue
            }

            currentToken.append(c)
            i += 1
        }

        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }

        return tokens
    }

    private static func parseExpression(_ tokens: inout [String]) throws -> Double {
        var result = try parseTerm(&tokens)

        while !tokens.isEmpty && (tokens[0] == "+" || tokens[0] == "-") {
            let op = tokens.removeFirst()
            let nextTerm = try parseTerm(&tokens)
            if op == "+" {
                result += nextTerm
            } else {
                result -= nextTerm
            }
        }

        return result
    }

    private static func parseTerm(_ tokens: inout [String]) throws -> Double {
        var result = try parseFactor(&tokens)

        while !tokens.isEmpty && (tokens[0] == "*" || tokens[0] == "/" || tokens[0] == "%") {
            let op = tokens.removeFirst()
            let nextFactor = try parseFactor(&tokens)
            if op == "*" {
                result *= nextFactor
            } else if op == "/" {
                guard nextFactor != 0 else { throw MathError.divisionByZero }
                result /= nextFactor
            } else {
                guard nextFactor != 0 else { throw MathError.divisionByZero }
                result = result.truncatingRemainder(dividingBy: nextFactor)
            }
        }

        return result
    }

    private static func parseFactor(_ tokens: inout [String]) throws -> Double {
        var result = try parsePrimary(&tokens)

        if !tokens.isEmpty && tokens[0] == "^" {
            _ = tokens.removeFirst()
            let exponent = try parseFactor(&tokens)
            result = pow(result, exponent)
        }

        return result
    }

    private static func parsePrimary(_ tokens: inout [String]) throws -> Double {
        guard !tokens.isEmpty else {
            throw MathError.invalidSyntax("Expected number or expression, but found end of input.")
        }

        // Unary plus or minus
        if tokens[0] == "+" {
            tokens.removeFirst()
            return try parsePrimary(&tokens)
        }
        if tokens[0] == "-" {
            tokens.removeFirst()
            let val = try parsePrimary(&tokens)
            return -val
        }

        // Parentheses
        if tokens[0] == "(" {
            tokens.removeFirst()
            let val = try parseExpression(&tokens)
            guard !tokens.isEmpty && tokens[0] == ")" else {
                throw MathError.mismatchedParentheses
            }
            tokens.removeFirst()
            return val
        }

        let token = tokens.removeFirst()

        // Check if token is function call (e.g. sqrt, sin, cos)
        if !tokens.isEmpty && tokens[0] == "(" {
            tokens.removeFirst() // remove '('
            let arg = try parseExpression(&tokens)
            guard !tokens.isEmpty && tokens[0] == ")" else {
                throw MathError.mismatchedParentheses
            }
            tokens.removeFirst() // remove ')'

            switch token.lowercased() {
            case "sqrt":
                guard arg >= 0 else { throw MathError.invalidSyntax("sqrt of negative number") }
                return sqrt(arg)
            case "sin": return sin(arg)
            case "cos": return cos(arg)
            case "tan": return tan(arg)
            case "abs": return abs(arg)
            case "log", "log10": return log10(arg)
            case "ln": return log(arg)
            case "floor": return floor(arg)
            case "ceil": return ceil(arg)
            default:
                throw MathError.unknownFunction(token)
            }
        }

        // Constants
        if token.lowercased() == "pi" {
            return Double.pi
        }
        if token.lowercased() == "e" {
            return M_E
        }

        // Literal number
        guard let num = Double(token) else {
            throw MathError.invalidSyntax("Cannot parse number '\(token)'.")
        }

        return num
    }
}

// MARK: - 5. System Notification Tool

/// Dispatches native local user notifications.
public struct SystemNotificationTool: Tool {
    public let definition = ToolDefinition(
        name: "system_notification",
        description: "Dispatches a native macOS desktop notification banner to alert the user of task completion or important notices.",
        parameters: [
            ToolParameter(name: "title", type: .string, description: "Title header of the notification banner."),
            ToolParameter(name: "body", type: .string, description: "Main message text of the notification."),
            ToolParameter(name: "subtitle", type: .string, description: "Optional secondary subtitle text.", isRequired: false)
        ],
        category: .notification,
        permissionLevel: .userConfirmationRequired
    )

    public init() {}

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let title = parameters["title"], !title.isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'title'.")
        }
        guard let body = parameters["body"], !body.isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'body'.")
        }
        let subtitle = parameters["subtitle"]

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sub = subtitle, !sub.isEmpty {
            content.subtitle = sub
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return .success(toolName: definition.name, output: "Notification '\(title)' successfully scheduled for display.")
        } catch {
            return .failure(toolName: definition.name, error: "Failed to dispatch notification: \(error.localizedDescription)")
        }
    }
}
