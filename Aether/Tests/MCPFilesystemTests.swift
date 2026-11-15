import XCTest
@testable import Aether

final class MCPFilesystemTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var directoryManager: AuthorizedDirectoryManager!
    private var mcpServer: MCPFilesystemServer!
    private var mcpClient: MCPClient!
    private var toolRegistry: ToolRegistry!

    override func setUp() async throws {
        try await super.setUp()

        // Create a unique temporary directory for real filesystem testing
        let baseTemp = FileManager.default.temporaryDirectory
        let uniqueName = "AetherTest_\(UUID().uuidString)"
        tempDirectoryURL = baseTemp.appendingPathComponent(uniqueName)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        // Initialize AuthorizedDirectoryManager authorizing our temp directory
        directoryManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        await directoryManager.authorizeTemporaryDirectory(url: tempDirectoryURL)

        // Create and start MCPFilesystemServer
        mcpServer = MCPFilesystemServer(directoryManager: directoryManager)

        // Wire via MCPInMemoryTransport
        let (clientTransport, serverTransport) = MCPInMemoryTransport.createPair()
        await mcpServer.start(transport: serverTransport)

        // Initialize MCPClient
        mcpClient = MCPClient()
        await mcpClient.connect(transport: clientTransport)

        // Setup ToolRegistry with security guard wired to directoryManager
        let securityGuard = ToolSecurityGuard(directoryManager: directoryManager)
        toolRegistry = ToolRegistry(securityGuard: securityGuard)

        // Initialize MCP session and register adapted tools
        _ = try await mcpClient.initialize(clientInfo: MCPImplementation(name: "AetherTestRunner", version: "1.0.0"))
        let discoveredTools = try await mcpClient.listTools()
        for tool in discoveredTools {
            let adapter = MCPToolAdapter(mcpTool: tool, client: mcpClient)
            await toolRegistry.register(adapter)
        }
    }

    override func tearDown() async throws {
        await mcpClient.disconnect()
        await mcpServer.stop()
        if let temp = tempDirectoryURL, FileManager.default.fileExists(atPath: temp.path) {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - 1. MCP Protocol & Discovery Tests

    func testMCPProtocolTypesSerialization() throws {
        let tool = MCPTool(
            name: "create_folder",
            description: "Creates a folder",
            inputSchema: MCPToolInputSchema(
                properties: ["path": MCPToolProperty(type: "string", description: "Folder path")],
                required: ["path"]
            )
        )
        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(MCPTool.self, from: data)
        XCTAssertEqual(decoded.name, "create_folder")
        XCTAssertEqual(decoded.inputSchema.required, ["path"])
    }

    func testMCPToolDiscoveryRegistersAll14Tools() async {
        let definitions = await toolRegistry.definitions
        let registeredNames = Set(definitions.map { $0.name })

        let expectedTools = [
            "create_folder", "list_directory", "search_directories", "rename_folder",
            "create_file", "read_file", "write_file", "append_file", "copy_file",
            "move_file", "rename_file", "delete_file", "search_files", "get_file_metadata"
        ]

        for expected in expectedTools {
            XCTAssertTrue(registeredNames.contains(expected), "Missing tool: \(expected)")
        }
    }

    func testToolSchemasAreValidAndPresentInPrompt() async {
        let promptSnippet = await toolRegistry.formatToolsForPrompt(style: .xmlTags)
        XCTAssertTrue(promptSnippet.contains("<name>create_folder</name>"))
        XCTAssertTrue(promptSnippet.contains("<name>create_file</name>"))
        XCTAssertTrue(promptSnippet.contains("<name>delete_file</name>"))
    }

    // MARK: - 2. Real Filesystem Operations

    func testCreateFolderAndNestedFolders() async throws {
        let folderPath = tempDirectoryURL.appendingPathComponent("Level1/Level2/Level3").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        let result = await toolRegistry.execute(
            toolName: "create_folder",
            parameters: ["path": folderPath],
            context: ctx
        )

        XCTAssertTrue(result.isSuccess, "Create folder should succeed: \(result.errorDescription ?? "")")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue, "Directory should physically exist on disk")
    }

    func testCreateReadWriteAppendFile() async throws {
        let filePath = tempDirectoryURL.appendingPathComponent("note.txt").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        // 1. Create file
        let createRes = await toolRegistry.execute(
            toolName: "create_file",
            parameters: ["path": filePath, "content": "Initial line.\n"],
            context: ctx
        )
        XCTAssertTrue(createRes.isSuccess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))

        // 2. Read file
        let readRes = await toolRegistry.execute(
            toolName: "read_file",
            parameters: ["path": filePath],
            context: ctx
        )
        XCTAssertTrue(readRes.isSuccess)
        XCTAssertTrue(readRes.output.contains("Initial line."))

        // 3. Append to file
        let appendRes = await toolRegistry.execute(
            toolName: "append_file",
            parameters: ["path": filePath, "content": "Second line.\n"],
            context: ctx
        )
        XCTAssertTrue(appendRes.isSuccess)

        // 4. Overwrite file
        let writeRes = await toolRegistry.execute(
            toolName: "write_file",
            parameters: ["path": filePath, "content": "Overwritten content."],
            context: ctx
        )
        XCTAssertTrue(writeRes.isSuccess)

        let contents = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(contents, "Overwritten content.")
    }

    func testCopyMoveRenameFile() async throws {
        let originalPath = tempDirectoryURL.appendingPathComponent("source.txt").path
        let copyPath = tempDirectoryURL.appendingPathComponent("copy.txt").path
        let movedPath = tempDirectoryURL.appendingPathComponent("moved.txt").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        // Create initial
        _ = await toolRegistry.execute(toolName: "create_file", parameters: ["path": originalPath, "content": "Data"], context: ctx)

        // Copy
        let copyRes = await toolRegistry.execute(toolName: "copy_file", parameters: ["source_path": originalPath, "destination_path": copyPath], context: ctx)
        XCTAssertTrue(copyRes.isSuccess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyPath))

        // Move
        let moveRes = await toolRegistry.execute(toolName: "move_file", parameters: ["source_path": copyPath, "destination_path": movedPath], context: ctx)
        XCTAssertTrue(moveRes.isSuccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedPath))

        // Rename
        let renameRes = await toolRegistry.execute(toolName: "rename_file", parameters: ["path": movedPath, "new_name": "renamed.txt"], context: ctx)
        XCTAssertTrue(renameRes.isSuccess)
        let finalPath = tempDirectoryURL.appendingPathComponent("renamed.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath))
    }

    func testListDirectoryAndSearch() async throws {
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        // Create files and folder
        let subDir = tempDirectoryURL.appendingPathComponent("SubFolder").path
        _ = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": subDir], context: ctx)
        _ = await toolRegistry.execute(toolName: "create_file", parameters: ["path": "\(subDir)/target.pdf", "content": "PDF Content"], context: ctx)
        _ = await toolRegistry.execute(toolName: "create_file", parameters: ["path": "\(tempDirectoryURL.path)/sample.txt", "content": "TXT Content"], context: ctx)

        // List directory
        let listRes = await toolRegistry.execute(toolName: "list_directory", parameters: ["path": tempDirectoryURL.path], context: ctx)
        XCTAssertTrue(listRes.isSuccess)
        XCTAssertTrue(listRes.output.contains("SubFolder"))
        XCTAssertTrue(listRes.output.contains("sample.txt"))

        // Search files
        let searchRes = await toolRegistry.execute(toolName: "search_files", parameters: ["path": tempDirectoryURL.path, "pattern": "target"], context: ctx)
        XCTAssertTrue(searchRes.isSuccess)
        XCTAssertTrue(searchRes.output.contains("target.pdf"))

        // Search directories
        let searchDirsRes = await toolRegistry.execute(toolName: "search_directories", parameters: ["path": tempDirectoryURL.path, "pattern": "Sub"], context: ctx)
        XCTAssertTrue(searchDirsRes.isSuccess)
        XCTAssertTrue(searchDirsRes.output.contains("SubFolder"))
    }

    func testGetFileMetadata() async throws {
        let filePath = tempDirectoryURL.appendingPathComponent("meta.txt").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)
        _ = await toolRegistry.execute(toolName: "create_file", parameters: ["path": filePath, "content": "1234567890"], context: ctx)

        let metaRes = await toolRegistry.execute(toolName: "get_file_metadata", parameters: ["path": filePath], context: ctx)
        XCTAssertTrue(metaRes.isSuccess)
        XCTAssertTrue(metaRes.output.contains("\"exists\" : true"))
        XCTAssertTrue(metaRes.output.contains("\"size_bytes\" : 10"))
    }

    // MARK: - 3. Security Boundary & Path Traversal Prevention

    func testPathTraversalIsRejected() async throws {
        let traversalPath = "\(tempDirectoryURL.path)/../../../../../../etc/passwd"
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        let result = await toolRegistry.execute(toolName: "read_file", parameters: ["path": traversalPath], context: ctx)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.status, .permissionDenied)
    }

    func testUnauthorizedDirectoryIsRejected() async throws {
        let unauthorizedPath = "/Library/Application Support/unauthorized_test.txt"
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        let result = await toolRegistry.execute(toolName: "create_file", parameters: ["path": unauthorizedPath, "content": "Forbidden"], context: ctx)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.status, .permissionDenied)
    }

    // MARK: - 4. Section 17 Acceptance Tests (TEST 1 - TEST 7)

    func testAcceptanceTest1_CreateFolderNamedAetherTest() async throws {
        let targetFolder = tempDirectoryURL.appendingPathComponent("AetherTest").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        let result = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": targetFolder], context: ctx)
        XCTAssertTrue(result.isSuccess, "TEST 1 failed: \(result.errorDescription ?? "")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFolder))
    }

    func testAcceptanceTest2_InsideAetherTestCreateThreeFolders() async throws {
        let root = tempDirectoryURL.appendingPathComponent("AetherTest").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        _ = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": "\(root)/Projects"], context: ctx)
        _ = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": "\(root)/Images"], context: ctx)
        _ = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": "\(root)/Documents"], context: ctx)

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/Projects"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/Images"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/Documents"))
    }

    func testAcceptanceTest3_CreateReadmeWithContent() async throws {
        let readmePath = tempDirectoryURL.appendingPathComponent("AetherTest/README.md").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        let result = await toolRegistry.execute(
            toolName: "create_file",
            parameters: ["path": readmePath, "content": "Hello from Aether"],
            context: ctx
        )
        XCTAssertTrue(result.isSuccess)

        let content = try String(contentsOfFile: readmePath, encoding: .utf8)
        XCTAssertEqual(content, "Hello from Aether")
    }

    func testAcceptanceTest4_ListEverythingInsideAetherTest() async throws {
        let root = tempDirectoryURL.appendingPathComponent("AetherTest").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        // Setup directories and readme
        _ = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": "\(root)/Projects"], context: ctx)
        _ = await toolRegistry.execute(toolName: "create_file", parameters: ["path": "\(root)/README.md", "content": "Hello"], context: ctx)

        let listResult = await toolRegistry.execute(toolName: "list_directory", parameters: ["path": root], context: ctx)
        XCTAssertTrue(listResult.isSuccess)
        XCTAssertTrue(listResult.output.contains("Projects"))
        XCTAssertTrue(listResult.output.contains("README.md"))
    }

    func testAcceptanceTest5_DeleteRequiresUserConfirmation() async throws {
        let docPath = tempDirectoryURL.appendingPathComponent("AetherTest/Documents").path
        let ctxWithoutApproval = ToolExecutionContext(isInteractiveApprovalGranted: false)

        // Attempting to delete without user approval should trigger user rejected / requires confirmation
        let result = await toolRegistry.execute(
            toolName: "delete_file",
            parameters: ["path": docPath],
            context: ctxWithoutApproval
        )

        // ToolSecurityGuard returns .requiresUserConfirmation for .restricted tools
        // which ToolRegistry translates into status .userRejected
        XCTAssertEqual(result.status, .userRejected, "Delete must require interactive user confirmation")

        // Now with explicit approval granted
        let ctxApproved = ToolExecutionContext(isInteractiveApprovalGranted: true)
        _ = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": docPath], context: ctxApproved)
        let approvedResult = await toolRegistry.execute(toolName: "delete_file", parameters: ["path": docPath], context: ctxApproved)
        XCTAssertTrue(approvedResult.isSuccess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: docPath))
    }

    func testAcceptanceTest6_CreateFolderOutsideAuthorizedDirectoryRejected() async throws {
        let outsidePath = "/tmp/AetherUnauthorizedExternalFolder_\(UUID().uuidString)"
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        let result = await toolRegistry.execute(
            toolName: "create_folder",
            parameters: ["path": outsidePath],
            context: ctx
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsidePath))
    }

    func testAcceptanceTest7_CreateFolderAndVerifyExistence() async throws {
        let targetPath = tempDirectoryURL.appendingPathComponent("VerifiedFolder").path
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)

        // 1. Create folder
        let createResult = await toolRegistry.execute(toolName: "create_folder", parameters: ["path": targetPath], context: ctx)
        XCTAssertTrue(createResult.isSuccess)

        // 2. Check existence via get_file_metadata
        let metaResult = await toolRegistry.execute(toolName: "get_file_metadata", parameters: ["path": targetPath], context: ctx)
        XCTAssertTrue(metaResult.isSuccess)
        XCTAssertTrue(metaResult.output.contains("\"exists\" : true"))
        XCTAssertTrue(metaResult.output.contains("\"is_directory\" : true"))
    }

    // MARK: - 5. LLM Tool-Calling & Result Feedback Loop

    func testLLMToolCallingAndResultFeedbackLoop() async throws {
        let folderPath = tempDirectoryURL.appendingPathComponent("AgentProjects").path

        actor FilesystemMockInferenceProvider: AgentInferenceProvider {
            let targetPath: String
            private var stepCount = 0

            init(targetPath: String) {
                self.targetPath = targetPath
            }

            func determineNextAction(
                state: AgentState,
                availableTools: [ToolDefinition],
                cancellationSignal: CancellationSignal?
            ) async throws -> (thought: String?, action: AgentAction) {
                stepCount += 1

                if stepCount == 1 {
                    // Turn 1: Model requests create_folder
                    return (
                        thought: "I need to create the Projects folder.",
                        action: .callTool(toolName: "create_folder", parameters: ["path": targetPath], thought: "Creating folder")
                    )
                } else {
                    // Turn 2: Model inspects observation and completes
                    guard let lastObservation = state.history.last?.observation else {
                        return (thought: "No observation", action: .declareFailure(reason: "Missing observation"))
                    }
                    if case .toolSuccess(let name, let output, _) = lastObservation {
                        return (
                            thought: "Tool \(name) succeeded with output: \(output)",
                            action: .declareComplete(finalAnswer: "The folder has been created successfully.")
                        )
                    } else {
                        return (thought: "Failed", action: .declareFailure(reason: "Tool did not succeed"))
                    }
                }
            }

            func evaluateObservation(
                state: AgentState,
                observation: AgentObservation,
                cancellationSignal: CancellationSignal?
            ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?) {
                return (isComplete: false, nextAction: nil, finalAnswer: nil)
            }
        }

        let conversationId = UUID()
        let initialState = AgentState(
            conversationId: conversationId,
            goal: "Create a folder named AgentProjects"
        )
        let provider = FilesystemMockInferenceProvider(targetPath: folderPath)
        let guardActor = await toolRegistry.securityGuard
        let loopActor = AgentExecutionLoopActor(
            initialState: initialState,
            registry: toolRegistry,
            securityGuard: guardActor,
            inferenceProvider: provider,
            maxSteps: 5
        )

        // Pre-approve create_folder in session
        await guardActor.grantSessionPermission(conversationId: conversationId, toolName: "create_folder")

        let finalState = await loopActor.run()

        XCTAssertEqual(finalState.phase, .completed, "Loop should complete successfully, got phase: \(finalState.phase)")
        XCTAssertEqual(finalState.finalAnswer, "The folder has been created successfully.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderPath), "Folder should physically exist on disk")
    }

    // MARK: - 6. Phase 3 & 4 Extended Edge Case Tests

    func testUnicodeAndSpaceContainingPaths() async throws {
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)
        let root = tempDirectoryURL.path
        let complexFolderPath = "\(root)/Aether Projects/🚀 Rocket Workspace"
        let complexFilePath = "\(complexFolderPath)/📄 Readme & Notes.txt"

        // 1. Create folder with spaces and emoji
        let createFolderRes = await toolRegistry.execute(
            toolName: "create_folder",
            parameters: ["path": complexFolderPath],
            context: ctx
        )
        XCTAssertTrue(createFolderRes.isSuccess, "Creating folder with unicode and spaces should succeed: \(createFolderRes.errorDescription ?? "")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: complexFolderPath))

        // 2. Write file with unicode content
        let unicodeContent = "こんにちは世界 🌍 ! Swift 6 + Apple Silicon native execution.\nLine 2: 🚀 testing spaces."
        let createFileRes = await toolRegistry.execute(
            toolName: "write_file",
            parameters: ["path": complexFilePath, "content": unicodeContent],
            context: ctx
        )
        XCTAssertTrue(createFileRes.isSuccess, "Writing file with unicode and spaces should succeed: \(createFileRes.errorDescription ?? "")")

        // 3. Read back file
        let readRes = await toolRegistry.execute(
            toolName: "read_file",
            parameters: ["path": complexFilePath],
            context: ctx
        )
        XCTAssertTrue(readRes.isSuccess)
        XCTAssertTrue(readRes.output.contains("こんにちは世界 🌍 !"))
        XCTAssertTrue(readRes.output.contains("🚀 testing spaces."))

        // 4. Verify list_directory handles unicode folder
        let listRes = await toolRegistry.execute(
            toolName: "list_directory",
            parameters: ["path": complexFolderPath],
            context: ctx
        )
        XCTAssertTrue(listRes.isSuccess)
        XCTAssertTrue(listRes.output.contains("📄 Readme & Notes.txt"))
    }

    func testLargeFileWriteAndRead500KB() async throws {
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)
        let largeFilePath = tempDirectoryURL.appendingPathComponent("large_buffer_500kb.txt").path

        // Generate a 500KB string (500 lines of 1,000 characters each)
        let line = String(repeating: "AetherBench2026", count: 66) + "\n" // ~991 chars per line
        let largeContent = String(repeating: line, count: 505) // ~500,455 chars
        XCTAssertGreaterThanOrEqual(largeContent.utf8.count, 500_000)

        // 1. Write 500KB file
        let writeRes = await toolRegistry.execute(
            toolName: "write_file",
            parameters: ["path": largeFilePath, "content": largeContent],
            context: ctx
        )
        XCTAssertTrue(writeRes.isSuccess, "Writing 500KB file should succeed: \(writeRes.errorDescription ?? "")")

        // 2. Verify file size metadata
        let metaRes = await toolRegistry.execute(
            toolName: "get_file_metadata",
            parameters: ["path": largeFilePath],
            context: ctx
        )
        XCTAssertTrue(metaRes.isSuccess)
        XCTAssertTrue(metaRes.output.contains("\"exists\" : true"))

        // 3. Read file with max_lines limit
        let readRes = await toolRegistry.execute(
            toolName: "read_file",
            parameters: ["path": largeFilePath, "max_lines": "100"],
            context: ctx
        )
        XCTAssertTrue(readRes.isSuccess)
        XCTAssertTrue(readRes.output.contains("AetherBench2026"))
    }

    func testEmptyFileCreationAndMetadata() async throws {
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)
        let emptyFilePath = tempDirectoryURL.appendingPathComponent("empty_note.txt").path

        let createRes = await toolRegistry.execute(
            toolName: "create_file",
            parameters: ["path": emptyFilePath, "content": ""],
            context: ctx
        )
        XCTAssertTrue(createRes.isSuccess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyFilePath))

        let metaRes = await toolRegistry.execute(
            toolName: "get_file_metadata",
            parameters: ["path": emptyFilePath],
            context: ctx
        )
        XCTAssertTrue(metaRes.isSuccess)
        XCTAssertTrue(metaRes.output.contains("\"size_bytes\" : 0"))
        XCTAssertTrue(metaRes.output.contains("\"exists\" : true"))
    }

    func testEditFileExactTargetReplacement() async throws {
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)
        let configPath = tempDirectoryURL.appendingPathComponent("config.env").path
        let initialConfig = "HOST=127.0.0.1\nPORT=8080\nDEBUG=false\nLOG_LEVEL=info\n"
        try initialConfig.write(toFile: configPath, atomically: true, encoding: .utf8)

        let editRes = await toolRegistry.execute(
            toolName: "edit_file",
            parameters: [
                "path": configPath,
                "target": "DEBUG=false",
                "replacement": "DEBUG=true"
            ],
            context: ctx
        )
        XCTAssertTrue(editRes.isSuccess, "Edit file should succeed: \(editRes.errorDescription ?? "")")

        let updatedContent = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(updatedContent.contains("DEBUG=true"))
        XCTAssertFalse(updatedContent.contains("DEBUG=false"))
        XCTAssertTrue(updatedContent.contains("PORT=8080"))
    }

    func testReadMultipleFilesWorkflow() async throws {
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)
        let fileA = tempDirectoryURL.appendingPathComponent("fileA.txt").path
        let fileB = tempDirectoryURL.appendingPathComponent("fileB.txt").path
        let fileC = tempDirectoryURL.appendingPathComponent("fileC.txt").path

        try "Content Alpha".write(toFile: fileA, atomically: true, encoding: .utf8)
        try "Content Beta".write(toFile: fileB, atomically: true, encoding: .utf8)
        try "Content Gamma".write(toFile: fileC, atomically: true, encoding: .utf8)

        let readMultiRes = await toolRegistry.execute(
            toolName: "read_multiple_files",
            parameters: ["paths": "\(fileA),\(fileB),\(fileC)"],
            context: ctx
        )
        XCTAssertTrue(readMultiRes.isSuccess, "read_multiple_files should succeed: \(readMultiRes.errorDescription ?? "")")
        XCTAssertTrue(readMultiRes.output.contains("Content Alpha"))
        XCTAssertTrue(readMultiRes.output.contains("Content Beta"))
        XCTAssertTrue(readMultiRes.output.contains("Content Gamma"))
    }

    func testDirectoryTreeVisualHierarchy() async throws {
        let ctx = ToolExecutionContext(isInteractiveApprovalGranted: true)
        let treeRoot = tempDirectoryURL.appendingPathComponent("TreeDemo").path
        try FileManager.default.createDirectory(atPath: "\(treeRoot)/Sources/Models", withIntermediateDirectories: true)
        try "class App {}".write(toFile: "\(treeRoot)/Sources/App.swift", atomically: true, encoding: .utf8)
        try "struct User {}".write(toFile: "\(treeRoot)/Sources/Models/User.swift", atomically: true, encoding: .utf8)

        let treeRes = await toolRegistry.execute(
            toolName: "directory_tree",
            parameters: ["path": treeRoot, "max_depth": "3"],
            context: ctx
        )
        XCTAssertTrue(treeRes.isSuccess, "directory_tree should succeed: \(treeRes.errorDescription ?? "")")
        XCTAssertTrue(treeRes.output.contains("TreeDemo"))
        XCTAssertTrue(treeRes.output.contains("Sources"))
        XCTAssertTrue(treeRes.output.contains("App.swift"))
        XCTAssertTrue(treeRes.output.contains("Models"))
    }
}
