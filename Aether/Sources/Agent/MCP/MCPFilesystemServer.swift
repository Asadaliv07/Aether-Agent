import Foundation
import os

/// Native macOS Model Context Protocol (MCP) Filesystem Server adhering to protocol version 2024-11-05.
/// Provides safe, verified, structured filesystem operations bounded by App Sandbox & `AuthorizedDirectoryManager`.
public actor MCPFilesystemServer {
    // MARK: - Properties

    public let directoryManager: AuthorizedDirectoryManager
    private var transport: MCPTransport?
    private var listeningTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.aether.Aether", category: "MCPFilesystemServer")
    private let dateFormatter: ISO8601DateFormatter

    // MARK: - Initializer

    public init(directoryManager: AuthorizedDirectoryManager) {
        self.directoryManager = directoryManager
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit {
        listeningTask?.cancel()
    }

    // MARK: - Lifecycle & Transport

    public func start(transport: MCPTransport) {
        self.transport = transport
        self.listeningTask = Task { [weak self] in
            for await messageData in transport.incomingMessages {
                guard let self = self else { break }
                await self.handleIncomingMessage(messageData)
            }
        }
    }

    public func stop() async {
        listeningTask?.cancel()
        listeningTask = nil
        await transport?.close()
        transport = nil
    }

    // MARK: - Message Handling

    private func handleIncomingMessage(_ data: Data) async {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let errResponse = JSONRPCResponse(id: .int(0), error: .parseError)
            await sendResponse(errResponse)
            return
        }

        // Check if request (has id) or notification (no id)
        if let rawId = jsonObject["id"] {
            let id: JSONRPCID
            if let intId = rawId as? Int {
                id = .int(intId)
            } else if let strId = rawId as? String {
                id = .string(strId)
            } else {
                id = .int(0)
            }

            guard let method = jsonObject["method"] as? String else {
                let errResponse = JSONRPCResponse(id: id, error: .invalidRequest)
                await sendResponse(errResponse)
                return
            }

            let params = jsonObject["params"] != nil ? AnyCodableSendable(jsonObject["params"]) : nil
            await handleRequest(id: id, method: method, params: params)
        } else if let method = jsonObject["method"] as? String {
            // Notification
            let params = jsonObject["params"] != nil ? AnyCodableSendable(jsonObject["params"]) : nil
            handleNotification(method: method, params: params)
        }
    }

    private func handleNotification(method: String, params: AnyCodableSendable?) {
        if method == "notifications/initialized" {
            logger.info("[MCPFilesystemServer] Client initialized notification received.")
        }
    }

    private func handleRequest(id: JSONRPCID, method: String, params: AnyCodableSendable?) async {
        switch method {
        case "initialize":
            let result = MCPInitializeResult(
                protocolVersion: MCPConstants.defaultProtocolVersion,
                capabilities: MCPServerCapabilities(tools: .init(listChanged: false)),
                serverInfo: MCPImplementation(name: "aether-filesystem", version: "1.0.0")
            )
            if let encData = try? JSONEncoder().encode(result),
               let anyCodable = try? JSONDecoder().decode(AnyCodableSendable.self, from: encData) {
                await sendResponse(JSONRPCResponse.success(id: id, result: anyCodable))
            } else {
                await sendResponse(JSONRPCResponse.failure(id: id, error: .internalError))
            }

        case "ping":
            await sendResponse(JSONRPCResponse.success(id: id, result: .dictionary([:])))

        case "tools/list":
            let tools = allToolDefinitions()
            let listResult = MCPListToolsResult(tools: tools)
            if let encData = try? JSONEncoder().encode(listResult),
               let anyCodable = try? JSONDecoder().decode(AnyCodableSendable.self, from: encData) {
                await sendResponse(JSONRPCResponse.success(id: id, result: anyCodable))
            } else {
                await sendResponse(JSONRPCResponse.failure(id: id, error: .internalError))
            }

        case "tools/call":
            guard let dict = params?.dictionaryValue,
                  let toolName = dict["name"]?.stringValue else {
                await sendResponse(JSONRPCResponse.failure(id: id, error: .invalidParams))
                return
            }
            let args = dict["arguments"]?.dictionaryValue ?? [:]
            let callResult = await executeTool(name: toolName, arguments: args)
            if let encData = try? JSONEncoder().encode(callResult),
               let anyCodable = try? JSONDecoder().decode(AnyCodableSendable.self, from: encData) {
                await sendResponse(JSONRPCResponse.success(id: id, result: anyCodable))
            } else {
                await sendResponse(JSONRPCResponse.failure(id: id, error: .internalError))
            }

        default:
            await sendResponse(JSONRPCResponse.failure(id: id, error: .methodNotFound))
        }
    }

    private func sendResponse(_ response: JSONRPCResponse) async {
        guard let transport = self.transport else { return }
        do {
            let data = try JSONEncoder().encode(response)
            try await transport.send(data: data)
        } catch {
            logger.error("[MCPFilesystemServer] Failed to send response: \(error.localizedDescription)")
        }
    }

    // MARK: - Registered Tool Definitions

    public func allToolDefinitions() -> [MCPTool] {
        [
            // 1. create_folder
            MCPTool(
                name: "create_folder",
                description: "Creates a folder at the specified authorized path.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path where directory should be created.")
                    ],
                    required: ["path"]
                )
            ),
            // 2. list_directory
            MCPTool(
                name: "list_directory",
                description: "Lists entries in an authorized directory.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path of directory to list.")
                    ],
                    required: ["path"]
                )
            ),
            // 3. search_directories
            MCPTool(
                name: "search_directories",
                description: "Recursively searches an authorized directory for subdirectories.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Root path of search."),
                        "pattern": MCPToolProperty(type: "string", description: "Directory name or pattern to search.")
                    ],
                    required: ["path", "pattern"]
                )
            ),
            // 4. rename_folder
            MCPTool(
                name: "rename_folder",
                description: "Renames an authorized directory to a new folder name.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Current path of directory."),
                        "new_name": MCPToolProperty(type: "string", description: "New name for directory.")
                    ],
                    required: ["path", "new_name"]
                )
            ),
            // 5. create_file
            MCPTool(
                name: "create_file",
                description: "Creates a file at the authorized path with optional content.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Destination path for file."),
                        "content": MCPToolProperty(type: "string", description: "Optional initial content.", default: "")
                    ],
                    required: ["path"]
                )
            ),
            // 6. read_file
            MCPTool(
                name: "read_file",
                description: "Reads UTF-8 text from an authorized file.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path of file to read."),
                        "max_lines": MCPToolProperty(type: "integer", description: "Max lines to read.", default: "500")
                    ],
                    required: ["path"]
                )
            ),
            // 7. write_file
            MCPTool(
                name: "write_file",
                description: "Overwrites an authorized file with content.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path of file to write."),
                        "content": MCPToolProperty(type: "string", description: "Text content to write.")
                    ],
                    required: ["path", "content"]
                )
            ),
            // 8. append_file
            MCPTool(
                name: "append_file",
                description: "Appends text content to an authorized file.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path of file to append."),
                        "content": MCPToolProperty(type: "string", description: "Text content to append.")
                    ],
                    required: ["path", "content"]
                )
            ),
            // 9. copy_file
            MCPTool(
                name: "copy_file",
                description: "Copies a file to an authorized destination path.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "source_path": MCPToolProperty(type: "string", description: "Source file path."),
                        "destination_path": MCPToolProperty(type: "string", description: "Destination copy path.")
                    ],
                    required: ["source_path", "destination_path"]
                )
            ),
            // 10. move_file
            MCPTool(
                name: "move_file",
                description: "Moves a file to an authorized destination path.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "source_path": MCPToolProperty(type: "string", description: "Source file path."),
                        "destination_path": MCPToolProperty(type: "string", description: "Destination file path.")
                    ],
                    required: ["source_path", "destination_path"]
                )
            ),
            // 11. rename_file
            MCPTool(
                name: "rename_file",
                description: "Renames a file in its current directory.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path of file to rename."),
                        "new_name": MCPToolProperty(type: "string", description: "New filename.")
                    ],
                    required: ["path", "new_name"]
                )
            ),
            // 12. delete_file
            MCPTool(
                name: "delete_file",
                description: "Deletes an authorized file or directory.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path of file/directory to delete."),
                        "recursive": MCPToolProperty(type: "boolean", description: "Recursive deletion flag.", default: "false")
                    ],
                    required: ["path"]
                )
            ),
            // 13. search_files
            MCPTool(
                name: "search_files",
                description: "Recursively searches an authorized directory for files.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Root directory path for search."),
                        "pattern": MCPToolProperty(type: "string", description: "File pattern or substring to match.")
                    ],
                    required: ["path", "pattern"]
                )
            ),
            // 14. get_file_metadata
            MCPTool(
                name: "get_file_metadata",
                description: "Retrieves metadata for an authorized file or directory.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path to inspect.")
                    ],
                    required: ["path"]
                )
            ),
            // 15. get_file_info (alias for get_file_metadata)
            MCPTool(
                name: "get_file_info",
                description: "Retrieves file metadata, size, creation/modification dates, and type info for an authorized file or directory.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path to inspect.")
                    ],
                    required: ["path"]
                )
            ),
            // 16. read_multiple_files
            MCPTool(
                name: "read_multiple_files",
                description: "Reads contents from multiple authorized file paths in a single coordinated operation.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "paths": MCPToolProperty(type: "string", description: "Comma-separated list or JSON array of file paths to read."),
                        "max_lines": MCPToolProperty(type: "integer", description: "Max lines per file (default 500).", default: "500")
                    ],
                    required: ["paths"]
                )
            ),
            // 17. directory_tree
            MCPTool(
                name: "directory_tree",
                description: "Generates an ASCII visual tree representation of directory contents up to a specified depth.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Root directory path for tree inspection."),
                        "max_depth": MCPToolProperty(type: "integer", description: "Maximum traversal depth (default 3).", default: "3")
                    ],
                    required: ["path"]
                )
            ),
            // 18. edit_file
            MCPTool(
                name: "edit_file",
                description: "Performs safe in-place text replacement in an authorized file.",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "path": MCPToolProperty(type: "string", description: "Path of file to edit."),
                        "target": MCPToolProperty(type: "string", description: "Exact target text to find and replace."),
                        "replacement": MCPToolProperty(type: "string", description: "New replacement text.")
                    ],
                    required: ["path", "target", "replacement"]
                )
            )
        ]
    }

    // MARK: - Tool Execution Dispatcher

    public func executeTool(name: String, arguments: [String: AnyCodableSendable]) async -> MCPCallToolResult {
        do {
            switch name {
            case "create_folder":
                return try await handleCreateFolder(args: arguments)
            case "list_directory":
                return try await handleListDirectory(args: arguments)
            case "search_directories":
                return try await handleSearchDirectories(args: arguments)
            case "rename_folder":
                return try await handleRenameFolder(args: arguments)
            case "create_file":
                return try await handleCreateFile(args: arguments)
            case "read_file":
                return try await handleReadFile(args: arguments)
            case "write_file":
                return try await handleWriteFile(args: arguments)
            case "append_file":
                return try await handleAppendFile(args: arguments)
            case "copy_file":
                return try await handleCopyFile(args: arguments)
            case "move_file":
                return try await handleMoveFile(args: arguments)
            case "rename_file":
                return try await handleRenameFile(args: arguments)
            case "delete_file":
                return try await handleDeleteFile(args: arguments)
            case "search_files":
                return try await handleSearchFiles(args: arguments)
            case "get_file_metadata", "get_file_info":
                return try await handleGetFileMetadata(args: arguments)
            case "read_multiple_files":
                return try await handleReadMultipleFiles(args: arguments)
            case "directory_tree":
                return try await handleDirectoryTree(args: arguments)
            case "edit_file":
                return try await handleEditFile(args: arguments)
            default:
                return MCPCallToolResult.text(formatError(op: name, error: "Tool '\(name)' is not implemented."), isError: true)
            }
        } catch {
            return MCPCallToolResult.text(formatError(op: name, error: error.localizedDescription), isError: true)
        }
    }

    // MARK: - Individual Tool Handlers

    private func handleCreateFolder(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        let rawPath = args["path"]?.stringValue
            ?? (args["parent_path"]?.stringValue.map { "\($0)/\(args["folder_name"]?.stringValue ?? "")" })
            ?? ""
        guard !rawPath.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "create_folder", error: "Missing required parameter 'path'."), isError: true)
        }
        if ToolSecurityGuard.isPlaceholderPath(rawPath) {
            return MCPCallToolResult.text(formatError(op: "create_folder", error: "Placeholder path '\(rawPath)' is not a valid destination."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let targetURL = access.url

        if await directoryManager.isReadOnly(url: targetURL) {
            return MCPCallToolResult.text(self.formatError(op: "create_folder", error: "Directory '\(targetURL.path)' is designated as read-only. Modifying operation 'create_folder' is prohibited."), isError: true)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            return MCPCallToolResult.text(self.formatError(op: "create_folder", error: "Directory was not created on disk."), isError: true)
        }

        // Post-creation containment verification (TOCTOU / symlink escape protection)
        let roots = await directoryManager.listAuthorizedRoots()
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let canonicalPost = targetURL.standardizedFileURL.resolvingSymlinksInPath().path
        let isContained = canonicalRoots.contains { rootPath in
            canonicalPost == rootPath || canonicalPost.hasPrefix(rootPath + "/")
        }
        guard isContained else {
            try? fm.removeItem(at: targetURL)
            return MCPCallToolResult.text(self.formatError(op: "create_folder", error: "Post-creation verification failed: directory escaped authorized root containment."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "create_folder",
            "path": targetURL.path,
            "message": "Folder created successfully: \(targetURL.lastPathComponent)"
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleListDirectory(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "list_directory", error: "Missing parameter 'path'."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let targetURL = access.url

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            return MCPCallToolResult.text(self.formatError(op: "list_directory", error: "Directory does not exist at '\(targetURL.path)'."), isError: true)
        }

        let contents = try fm.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [[String: Any]] = []
        for item in contents {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values.isDirectory ?? false
            let size = values.fileSize ?? 0
            let modDate = values.contentModificationDate.map { self.dateFormatter.string(from: $0) } ?? ""

            entries.append([
                "name": item.lastPathComponent,
                "path": item.path,
                "is_directory": isDirectory,
                "size_bytes": size,
                "modified_at": modDate
            ])
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "list_directory",
            "path": targetURL.path,
            "count": entries.count,
            "entries": entries
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleSearchDirectories(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue,
              let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "search_directories", error: "Missing 'path' or 'pattern'."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let rootURL = access.url

        let fm = FileManager.default
        var matchingDirs: [String] = []

        if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                    if fileURL.lastPathComponent.localizedCaseInsensitiveContains(pattern) {
                        matchingDirs.append(fileURL.path)
                    }
                }
            }
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "search_directories",
            "root_path": rootURL.path,
            "pattern": pattern,
            "matches": matchingDirs
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleRenameFolder(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue,
              let newName = args["new_name"]?.stringValue, !newName.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "rename_folder", error: "Missing 'path' or 'new_name'."), isError: true)
        }
        if ToolSecurityGuard.isPlaceholderPath(rawPath) {
            return MCPCallToolResult.text(formatError(op: "rename_folder", error: "Placeholder path '\(rawPath)' is not a valid destination."), isError: true)
        }
        if ToolSecurityGuard.isPlaceholderPath(newName) {
            return MCPCallToolResult.text(formatError(op: "rename_folder", error: "Placeholder name '\(newName)' is not a valid destination."), isError: true)
        }
        let trimmedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNewName.contains("/") && !trimmedNewName.contains("\\") && !trimmedNewName.contains("..") && !trimmedNewName.contains("\0") else {
            return MCPCallToolResult.text(formatError(op: "rename_folder", error: "Parameter 'new_name' must be a simple filename without path separators or traversal sequences."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let currentURL = access.url

        let roots = await directoryManager.listAuthorizedRoots()
        if roots.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path == currentURL.standardizedFileURL.resolvingSymlinksInPath().path }) {
            return MCPCallToolResult.text(formatError(op: "rename_folder", error: "Renaming an authorized root directory itself is prohibited."), isError: true)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: currentURL.path, isDirectory: &isDir), isDir.boolValue else {
            return MCPCallToolResult.text(self.formatError(op: "rename_folder", error: "Directory '\(currentURL.path)' not found."), isError: true)
        }

        let parentURL = currentURL.deletingLastPathComponent()
        let newURL = parentURL.appendingPathComponent(trimmedNewName).standardizedFileURL.resolvingSymlinksInPath()
        _ = try await directoryManager.validateAndResolve(path: newURL.path)

        let isCurrentRO = await directoryManager.isReadOnly(url: currentURL)
        let isNewRO = await directoryManager.isReadOnly(url: newURL)
        if isCurrentRO || isNewRO {
            return MCPCallToolResult.text(self.formatError(op: "rename_folder", error: "Directory is designated as read-only. Modifying operation 'rename_folder' is prohibited."), isError: true)
        }

        try fm.moveItem(at: currentURL, to: newURL)

        guard fm.fileExists(atPath: newURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "rename_folder", error: "Renamed folder not found on disk."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "rename_folder",
            "old_path": currentURL.path,
            "new_path": newURL.path,
            "message": "Folder renamed successfully to \(trimmedNewName)."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleCreateFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "create_file", error: "Missing parameter 'path'."), isError: true)
        }
        if ToolSecurityGuard.isPlaceholderPath(rawPath) {
            return MCPCallToolResult.text(formatError(op: "create_file", error: "Placeholder path '\(rawPath)' is not a valid destination."), isError: true)
        }
        let content = args["content"]?.stringValue ?? ""

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let targetURL = access.url

        if await directoryManager.isReadOnly(url: targetURL) {
            return MCPCallToolResult.text(self.formatError(op: "create_file", error: "Directory '\(targetURL.path)' is designated as read-only. Modifying operation 'create_file' is prohibited."), isError: true)
        }

        let roots = await directoryManager.listAuthorizedRoots()
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        if canonicalRoots.contains(targetURL.standardizedFileURL.resolvingSymlinksInPath().path) {
            return MCPCallToolResult.text(formatError(op: "create_file", error: "Target path cannot be an authorized root directory itself."), isError: true)
        }

        let fm = FileManager.default
        let parentURL = targetURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentURL.path) {
            try fm.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
        }

        guard let data = content.data(using: .utf8) else {
            return MCPCallToolResult.text(self.formatError(op: "create_file", error: "Cannot encode content to UTF-8."), isError: true)
        }

        try data.write(to: targetURL, options: .atomic)

        guard fm.fileExists(atPath: targetURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "create_file", error: "File creation verification failed."), isError: true)
        }

        // Post-creation containment verification (TOCTOU / symlink escape protection)
        let canonicalPost = targetURL.standardizedFileURL.resolvingSymlinksInPath().path
        let isContained = canonicalRoots.contains { rootPath in
            canonicalPost == rootPath || canonicalPost.hasPrefix(rootPath + "/")
        }
        guard isContained else {
            try? fm.removeItem(at: targetURL)
            return MCPCallToolResult.text(self.formatError(op: "create_file", error: "Post-creation verification failed: file escaped authorized root containment."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "create_file",
            "path": targetURL.path,
            "size_bytes": data.count,
            "message": "File '\(targetURL.lastPathComponent)' created successfully."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleReadFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "read_file", error: "Missing parameter 'path'."), isError: true)
        }
        let maxLines = args["max_lines"]?.intValue ?? 500

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let fileURL = access.url

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "read_file", error: "File not found at '\(fileURL.path)'."), isError: true)
        }

        let fileData = try Data(contentsOf: fileURL)
        guard let text = String(data: fileData, encoding: .utf8) else {
            return MCPCallToolResult.text(self.formatError(op: "read_file", error: "File contains non-UTF8 binary data."), isError: true)
        }

        let lines = text.components(separatedBy: "\n")
        let truncated = lines.prefix(maxLines).joined(separator: "\n")

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "read_file",
            "path": fileURL.path,
            "total_lines": lines.count,
            "returned_lines": min(lines.count, maxLines),
            "content": truncated
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleWriteFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty,
              let content = args["content"]?.stringValue else {
            return MCPCallToolResult.text(formatError(op: "write_file", error: "Missing 'path' or 'content'."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let fileURL = access.url

        if await directoryManager.isReadOnly(url: fileURL) {
            return MCPCallToolResult.text(self.formatError(op: "write_file", error: "Directory '\(fileURL.path)' is designated as read-only. Modifying operation 'write_file' is prohibited."), isError: true)
        }

        let roots = await directoryManager.listAuthorizedRoots()
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        if canonicalRoots.contains(fileURL.standardizedFileURL.resolvingSymlinksInPath().path) {
            return MCPCallToolResult.text(formatError(op: "write_file", error: "Target path cannot be an authorized root directory itself."), isError: true)
        }

        let fm = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        guard let data = content.data(using: .utf8) else {
            return MCPCallToolResult.text(self.formatError(op: "write_file", error: "Encoding failure."), isError: true)
        }

        try data.write(to: fileURL, options: .atomic)

        // Verify content
        let readBack = try String(contentsOf: fileURL, encoding: .utf8)
        guard readBack == content else {
            return MCPCallToolResult.text(self.formatError(op: "write_file", error: "Write verification mismatch."), isError: true)
        }

        // Post-creation containment verification (TOCTOU / symlink escape protection)
        let canonicalPost = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let isContained = canonicalRoots.contains { rootPath in
            canonicalPost == rootPath || canonicalPost.hasPrefix(rootPath + "/")
        }
        guard isContained else {
            try? fm.removeItem(at: fileURL)
            return MCPCallToolResult.text(self.formatError(op: "write_file", error: "Post-creation verification failed: file escaped authorized root containment."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "write_file",
            "path": fileURL.path,
            "bytes_written": data.count,
            "message": "File written and verified successfully."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleAppendFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty,
              let content = args["content"]?.stringValue else {
            return MCPCallToolResult.text(formatError(op: "append_file", error: "Missing 'path' or 'content'."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let fileURL = access.url

        if await directoryManager.isReadOnly(url: fileURL) {
            return MCPCallToolResult.text(self.formatError(op: "write_file", error: "Directory '\(fileURL.path)' is designated as read-only. Modifying operation 'write_file' is prohibited."), isError: true)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "append_file", error: "File '\(fileURL.path)' does not exist."), isError: true)
        }

        guard let appendData = content.data(using: .utf8) else {
            return MCPCallToolResult.text(self.formatError(op: "append_file", error: "Encoding failure."), isError: true)
        }

        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: appendData)

        let updatedSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "append_file",
            "path": fileURL.path,
            "bytes_appended": appendData.count,
            "new_size_bytes": updatedSize,
            "message": "Appended \(appendData.count) bytes successfully."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleCopyFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let src = args["source_path"]?.stringValue, !src.isEmpty,
              let dst = args["destination_path"]?.stringValue, !dst.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "copy_file", error: "Missing 'source_path' or 'destination_path'."), isError: true)
        }

        let srcAccess = try await directoryManager.acquireAccess(to: src)
        defer { srcAccess.release() }
        let dstAccess = try await directoryManager.acquireAccess(to: dst)
        defer { dstAccess.release() }

        let srcURL = srcAccess.url
        let dstURL = dstAccess.url

        let roots = await directoryManager.listAuthorizedRoots()
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let canonicalSrc = srcURL.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalDst = dstURL.standardizedFileURL.resolvingSymlinksInPath().path

        if canonicalRoots.contains(canonicalSrc) {
            return MCPCallToolResult.text(formatError(op: "copy_file", error: "Source path cannot be an authorized root directory itself."), isError: true)
        }
        if canonicalRoots.contains(canonicalDst) {
            return MCPCallToolResult.text(formatError(op: "copy_file", error: "Destination path cannot be an authorized root directory itself."), isError: true)
        }

        let isSrcRO = await directoryManager.isReadOnly(url: srcURL)
        let isDstRO = await directoryManager.isReadOnly(url: dstURL)
        if isSrcRO || isDstRO {
            return MCPCallToolResult.text(self.formatError(op: "copy_file", error: "Directory is designated as read-only. Modifying operation 'copy_file' is prohibited."), isError: true)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: srcURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "copy_file", error: "Source file not found."), isError: true)
        }

        let dstParent = dstURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dstParent.path) {
            try fm.createDirectory(at: dstParent, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: dstURL.path) {
            try fm.removeItem(at: dstURL)
        }

        try fm.copyItem(at: srcURL, to: dstURL)
        guard fm.fileExists(atPath: dstURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "copy_file", error: "Copy verification failed."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "copy_file",
            "source": srcURL.path,
            "destination": dstURL.path,
            "message": "File copied successfully."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleMoveFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let src = args["source_path"]?.stringValue, !src.isEmpty,
              let dst = args["destination_path"]?.stringValue, !dst.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "move_file", error: "Missing 'source_path' or 'destination_path'."), isError: true)
        }

        let srcAccess = try await directoryManager.acquireAccess(to: src)
        defer { srcAccess.release() }
        let dstAccess = try await directoryManager.acquireAccess(to: dst)
        defer { dstAccess.release() }

        let srcURL = srcAccess.url
        let dstURL = dstAccess.url

        let roots = await directoryManager.listAuthorizedRoots()
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let canonicalSrc = srcURL.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalDst = dstURL.standardizedFileURL.resolvingSymlinksInPath().path

        if canonicalRoots.contains(canonicalSrc) {
            return MCPCallToolResult.text(formatError(op: "move_file", error: "Source path cannot be an authorized root directory itself."), isError: true)
        }
        if canonicalRoots.contains(canonicalDst) {
            return MCPCallToolResult.text(formatError(op: "move_file", error: "Destination path cannot be an authorized root directory itself."), isError: true)
        }

        let isSrcRO = await directoryManager.isReadOnly(url: srcURL)
        let isDstRO = await directoryManager.isReadOnly(url: dstURL)
        if isSrcRO || isDstRO {
            return MCPCallToolResult.text(self.formatError(op: "move_file", error: "Directory is designated as read-only. Modifying operation 'move_file' is prohibited."), isError: true)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: srcURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "move_file", error: "Source file does not exist."), isError: true)
        }

        let dstParent = dstURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dstParent.path) {
            try fm.createDirectory(at: dstParent, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: dstURL.path) {
            try fm.removeItem(at: dstURL)
        }

        try fm.moveItem(at: srcURL, to: dstURL)
        guard fm.fileExists(atPath: dstURL.path) && !fm.fileExists(atPath: srcURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "move_file", error: "Move verification failed."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "move_file",
            "source": srcURL.path,
            "destination": dstURL.path,
            "message": "File moved successfully."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleRenameFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty,
              let newName = args["new_name"]?.stringValue, !newName.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "rename_file", error: "Missing 'path' or 'new_name'."), isError: true)
        }
        if ToolSecurityGuard.isPlaceholderPath(rawPath) {
            return MCPCallToolResult.text(formatError(op: "rename_file", error: "Placeholder path '\(rawPath)' is not a valid destination."), isError: true)
        }
        if ToolSecurityGuard.isPlaceholderPath(newName) {
            return MCPCallToolResult.text(formatError(op: "rename_file", error: "Placeholder name '\(newName)' is not a valid destination."), isError: true)
        }
        let trimmedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNewName.contains("/") && !trimmedNewName.contains("\\") && !trimmedNewName.contains("..") && !trimmedNewName.contains("\0") else {
            return MCPCallToolResult.text(formatError(op: "rename_file", error: "Parameter 'new_name' must be a simple filename without path separators or traversal sequences."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let fileURL = access.url

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "rename_file", error: "File not found at '\(fileURL.path)'."), isError: true)
        }

        let parentURL = fileURL.deletingLastPathComponent()
        let newURL = parentURL.appendingPathComponent(trimmedNewName).standardizedFileURL.resolvingSymlinksInPath()
        _ = try await directoryManager.validateAndResolve(path: newURL.path)

        let isFileRO = await directoryManager.isReadOnly(url: fileURL)
        let isNewRO = await directoryManager.isReadOnly(url: newURL)
        if isFileRO || isNewRO {
            return MCPCallToolResult.text(self.formatError(op: "rename_file", error: "Directory is designated as read-only. Modifying operation 'rename_file' is prohibited."), isError: true)
        }

        try fm.moveItem(at: fileURL, to: newURL)

        guard fm.fileExists(atPath: newURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "rename_file", error: "Renamed file verification failed."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "rename_file",
            "old_path": fileURL.path,
            "new_path": newURL.path,
            "message": "File renamed successfully to '\(trimmedNewName)'."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleDeleteFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "delete_file", error: "Missing parameter 'path'."), isError: true)
        }
        let recursive = args["recursive"]?.boolValue ?? false

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let targetURL = access.url

        let roots = await directoryManager.listAuthorizedRoots()
        if roots.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path == targetURL.standardizedFileURL.resolvingSymlinksInPath().path }) {
            return MCPCallToolResult.text(formatError(op: "delete_file", error: "Deleting an authorized root directory itself is prohibited."), isError: true)
        }

        if await directoryManager.isReadOnly(url: targetURL) {
            return MCPCallToolResult.text(self.formatError(op: "delete_file", error: "Directory '\(targetURL.path)' is designated as read-only. Modifying operation 'delete_file' is prohibited."), isError: true)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            return MCPCallToolResult.text(self.formatError(op: "delete_file", error: "Target '\(targetURL.path)' does not exist."), isError: true)
        }

        if isDir.boolValue && !recursive {
            let contents = try? fm.contentsOfDirectory(atPath: targetURL.path)
            if let contents = contents, !contents.isEmpty {
                return MCPCallToolResult.text(self.formatError(op: "delete_file", error: "Cannot delete non-empty directory without recursive flag."), isError: true)
            }
        }

        try fm.removeItem(at: targetURL)

        guard !fm.fileExists(atPath: targetURL.path) else {
            return MCPCallToolResult.text(self.formatError(op: "delete_file", error: "Deletion verification failed: file still exists."), isError: true)
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "delete_file",
            "path": targetURL.path,
            "was_directory": isDir.boolValue,
            "message": "Successfully deleted '\(targetURL.lastPathComponent)'."
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleSearchFiles(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue,
              let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "search_files", error: "Missing 'path' or 'pattern'."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let rootURL = access.url

        let fm = FileManager.default
        var matches: [[String: Any]] = []

        if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                   values.isDirectory != true {
                    if fileURL.lastPathComponent.localizedCaseInsensitiveContains(pattern) {
                        matches.append([
                            "name": fileURL.lastPathComponent,
                            "path": fileURL.path,
                            "size_bytes": values.fileSize ?? 0
                        ])
                    }
                }
            }
        }

        let resultDict: [String: Any] = [
            "success": true,
            "operation": "search_files",
            "root_path": rootURL.path,
            "pattern": pattern,
            "count": matches.count,
            "matches": matches
        ]
        return MCPCallToolResult.text(self.jsonString(from: resultDict))
    }

    private func handleGetFileMetadata(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "get_file_metadata", error: "Missing parameter 'path'."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let targetURL = access.url

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: targetURL.path, isDirectory: &isDir)

        if !exists {
            let dict: [String: Any] = [
                "success": true,
                "operation": "get_file_metadata",
                "path": targetURL.path,
                "exists": false
            ]
            return MCPCallToolResult.text(self.jsonString(from: dict))
        }

        let attrs = try fm.attributesOfItem(atPath: targetURL.path)
        let size = attrs[.size] as? Int ?? 0
        let creationDate = (attrs[.creationDate] as? Date).map { self.dateFormatter.string(from: $0) } ?? ""
        let modDate = (attrs[.modificationDate] as? Date).map { self.dateFormatter.string(from: $0) } ?? ""
        let posixPerms = attrs[.posixPermissions] as? Int ?? 0

        let dict: [String: Any] = [
            "success": true,
            "operation": "get_file_metadata",
            "path": targetURL.path,
            "exists": true,
            "is_directory": isDir.boolValue,
            "size_bytes": size,
            "created_at": creationDate,
            "modified_at": modDate,
            "posix_permissions": String(format: "%o", posixPerms)
        ]
        return MCPCallToolResult.text(self.jsonString(from: dict))
    }

    private func handleReadMultipleFiles(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPathsParam = args["paths"]?.stringValue, !rawPathsParam.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "read_multiple_files", error: "Missing parameter 'paths'."), isError: true)
        }
        let maxLines = args["max_lines"]?.intValue ?? 500

        var paths: [String] = []
        if let data = rawPathsParam.data(using: .utf8),
           let jsonArr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            paths = jsonArr
        } else {
            paths = rawPathsParam.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        guard !paths.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "read_multiple_files", error: "No valid file paths provided."), isError: true)
        }

        var results: [[String: Any]] = []
        let fm = FileManager.default

        for p in paths {
            if ToolSecurityGuard.isPlaceholderPath(p) {
                results.append(["path": p, "success": false, "error": "Placeholder path is invalid."])
                continue
            }
            do {
                let access = try await directoryManager.acquireAccess(to: p)
                let fileURL = access.url
                defer { access.release() }

                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                    results.append(["path": p, "resolved_path": fileURL.path, "success": false, "error": "File does not exist or is a directory."])
                    continue
                }

                let data = try Data(contentsOf: fileURL)
                guard let text = String(data: data, encoding: .utf8) else {
                    results.append(["path": p, "resolved_path": fileURL.path, "success": false, "error": "File contains non-UTF8 binary data."])
                    continue
                }

                let lines = text.components(separatedBy: "\n")
                let truncated = lines.prefix(maxLines).joined(separator: "\n")
                results.append([
                    "path": p,
                    "resolved_path": fileURL.path,
                    "success": true,
                    "total_lines": lines.count,
                    "returned_lines": min(lines.count, maxLines),
                    "content": truncated
                ])
            } catch {
                results.append(["path": p, "success": false, "error": error.localizedDescription])
            }
        }

        let dict: [String: Any] = [
            "success": true,
            "operation": "read_multiple_files",
            "files_count": results.count,
            "results": results
        ]
        return MCPCallToolResult.text(self.jsonString(from: dict))
    }

    private func handleDirectoryTree(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return MCPCallToolResult.text(formatError(op: "directory_tree", error: "Missing parameter 'path'."), isError: true)
        }
        let maxDepth = min(10, max(1, args["max_depth"]?.intValue ?? 3))

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let rootURL = access.url

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return MCPCallToolResult.text(formatError(op: "directory_tree", error: "Target path '\(rootURL.path)' is not a directory."), isError: true)
        }

        var lines: [String] = ["\(rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent)/"]

        func buildTree(url: URL, depth: Int, prefix: String) {
            guard depth <= maxDepth else { return }
            guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }

            let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for (idx, item) in sorted.enumerated() {
                let isLast = (idx == sorted.count - 1)
                let connector = isLast ? "└── " : "├── "
                let nextPrefix = prefix + (isLast ? "    " : "│   ")

                var itemIsDir: ObjCBool = false
                fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)

                if itemIsDir.boolValue {
                    lines.append("\(prefix)\(connector)\(item.lastPathComponent)/")
                    buildTree(url: item, depth: depth + 1, prefix: nextPrefix)
                } else {
                    lines.append("\(prefix)\(connector)\(item.lastPathComponent)")
                }
            }
        }

        buildTree(url: rootURL, depth: 1, prefix: "")

        let dict: [String: Any] = [
            "success": true,
            "operation": "directory_tree",
            "root_path": rootURL.path,
            "tree": lines.joined(separator: "\n")
        ]
        return MCPCallToolResult.text(self.jsonString(from: dict))
    }

    private func handleEditFile(args: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty,
              let target = args["target"]?.stringValue, !target.isEmpty,
              let replacement = args["replacement"]?.stringValue else {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "Missing required parameter 'path', 'target', or 'replacement'."), isError: true)
        }
        if ToolSecurityGuard.isPlaceholderPath(rawPath) {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "Placeholder path '\(rawPath)' is not a valid destination."), isError: true)
        }

        let access = try await directoryManager.acquireAccess(to: rawPath)
        defer { access.release() }
        let fileURL = access.url

        if await directoryManager.isReadOnly(url: fileURL) {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "Directory '\(fileURL.path)' is designated as read-only. Modifying operation 'edit_file' is prohibited."), isError: true)
        }

        let roots = await directoryManager.listAuthorizedRoots()
        let canonicalRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        if canonicalRoots.contains(fileURL.standardizedFileURL.resolvingSymlinksInPath().path) {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "Target path cannot be an authorized root directory itself."), isError: true)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "File not found at '\(fileURL.path)'."), isError: true)
        }

        let existingData = try Data(contentsOf: fileURL)
        guard let existingText = String(data: existingData, encoding: .utf8) else {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "File contains non-UTF8 binary data and cannot be edited."), isError: true)
        }

        guard existingText.contains(target) else {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "Target text '\(target)' was not found in '\(fileURL.lastPathComponent)'."), isError: true)
        }

        let updatedText = existingText.replacingOccurrences(of: target, with: replacement)
        guard let updatedData = updatedText.data(using: .utf8) else {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "Encoding failure during edit."), isError: true)
        }

        try updatedData.write(to: fileURL, options: .atomic)

        // Verification
        let readBack = try String(contentsOf: fileURL, encoding: .utf8)
        guard readBack == updatedText else {
            return MCPCallToolResult.text(formatError(op: "edit_file", error: "Edit verification failed: content mismatch on disk."), isError: true)
        }

        let dict: [String: Any] = [
            "success": true,
            "operation": "edit_file",
            "path": fileURL.path,
            "message": "File '\(fileURL.lastPathComponent)' edited successfully.",
            "original_length": existingText.count,
            "updated_length": updatedText.count
        ]
        return MCPCallToolResult.text(self.jsonString(from: dict))
    }

    // MARK: - Format Helpers

    private func formatError(op: String, error: String) -> String {
        let dict: [String: Any] = [
            "success": false,
            "operation": op,
            "error": error
        ]
        return jsonString(from: dict)
    }

    private func jsonString(from dictionary: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys, .prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"success\": false, \"error\": \"Serialization failure\"}"
    }
}
