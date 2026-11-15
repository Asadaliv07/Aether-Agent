import Foundation

/// Adapts an MCP tool discovered from an MCP server into a native Aether `Tool`
/// registered with `ToolRegistry` and subject to `ToolSecurityGuard`.
public struct MCPToolAdapter: Tool {
    // MARK: - Properties

    public let definition: ToolDefinition
    private let client: MCPClient

    // MARK: - Initializer

    public init(mcpTool: MCPTool, client: MCPClient) {
        self.client = client

        // 1. Determine permission level based on security policy
        let permissionLevel: ToolPermissionLevel
        switch mcpTool.name {
        case "delete_file":
            permissionLevel = .restricted
        case "create_folder", "create_file", "write_file", "append_file", "copy_file", "move_file", "rename_file", "rename_folder", "edit_file":
            permissionLevel = .userConfirmationRequired
        case "list_directory", "read_file", "search_directories", "search_files", "get_file_metadata", "get_file_info", "read_multiple_files", "directory_tree":
            permissionLevel = .safeReadOnly
        default:
            permissionLevel = .userConfirmationRequired
        }

        // 2. Map schema properties to ToolParameter array
        var toolParameters: [ToolParameter] = []
        let requiredSet = Set(mcpTool.inputSchema.required ?? [])

        for (propName, prop) in mcpTool.inputSchema.properties.sorted(by: { $0.key < $1.key }) {
            let paramType: ToolParameterType
            switch prop.type.lowercased() {
            case "integer", "int":
                paramType = .integer
            case "number", "float", "double":
                paramType = .number
            case "boolean", "bool":
                paramType = .boolean
            case "array":
                paramType = .array
            case "object":
                paramType = .object
            default:
                paramType = .string
            }

            toolParameters.append(ToolParameter(
                name: propName,
                type: paramType,
                description: prop.description ?? "",
                isRequired: requiredSet.contains(propName),
                defaultValue: prop.default,
                allowedValues: prop.enum
            ))
        }

        self.definition = ToolDefinition(
            name: mcpTool.name,
            description: mcpTool.description ?? "",
            parameters: toolParameters,
            category: .filesystem,
            permissionLevel: permissionLevel
        )
    }

    // MARK: - Tool Protocol Execution

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        // Convert string parameters to AnyCodableSendable respecting schema types
        var arguments: [String: AnyCodableSendable] = [:]
        for param in definition.parameters {
            guard let rawVal = parameters[param.name] else { continue }
            switch param.type {
            case .integer:
                if let intVal = Int(rawVal.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    arguments[param.name] = .int(intVal)
                } else {
                    arguments[param.name] = .string(rawVal)
                }
            case .number:
                if let dblVal = Double(rawVal.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    arguments[param.name] = .double(dblVal)
                } else {
                    arguments[param.name] = .string(rawVal)
                }
            case .boolean:
                let lower = rawVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lower == "true" || lower == "1" {
                    arguments[param.name] = .bool(true)
                } else if lower == "false" || lower == "0" {
                    arguments[param.name] = .bool(false)
                } else {
                    arguments[param.name] = .string(rawVal)
                }
            default:
                arguments[param.name] = .string(rawVal)
            }
        }

        // Call tool via MCP Client
        let mcpResult = try await client.callTool(name: definition.name, arguments: arguments)
        let outputText = mcpResult.content.compactMap { $0.text }.joined(separator: "\n")

        if mcpResult.isError == true {
            return .failure(toolName: definition.name, error: outputText.isEmpty ? "Operation failed" : outputText)
        } else {
            return .success(toolName: definition.name, output: outputText)
        }
    }
}

