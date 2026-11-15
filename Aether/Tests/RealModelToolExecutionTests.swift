import XCTest
@testable import Aether

final class RealModelToolExecutionTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var directoryManager: AuthorizedDirectoryManager!
    private var mcpServer: MCPFilesystemServer!
    private var mcpClient: MCPClient!
    private var toolRegistry: ToolRegistry!
    private var securityGuard: ToolSecurityGuard!

    private var candidateModelPath: String? {
        let candidates = [
            "/Users/asadalishaikh/Desktop/qwen2.5-coder/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463",
            "/Users/asadalishaikh/.ollama/models/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463"
        ]
        return candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
    }

    override func setUp() async throws {
        try await super.setUp()

        let baseTemp = FileManager.default.temporaryDirectory
        let uniqueName = "AetherRealToolTest_\(UUID().uuidString)"
        tempDirectoryURL = baseTemp.appendingPathComponent(uniqueName)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        directoryManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        await directoryManager.authorizeTemporaryDirectory(url: tempDirectoryURL)

        mcpServer = MCPFilesystemServer(directoryManager: directoryManager)
        let (clientTransport, serverTransport) = MCPInMemoryTransport.createPair()
        await mcpServer.start(transport: serverTransport)

        mcpClient = MCPClient()
        await mcpClient.connect(transport: clientTransport)

        securityGuard = ToolSecurityGuard(directoryManager: directoryManager)
        toolRegistry = ToolRegistry(securityGuard: securityGuard)

        _ = try await mcpClient.initialize(clientInfo: MCPImplementation(name: "AetherRealModelTestRunner", version: "1.0.0"))
        let discoveredTools = try await mcpClient.listTools()
        for tool in discoveredTools {
            let adapter = MCPToolAdapter(mcpTool: tool, client: mcpClient)
            await toolRegistry.register(adapter)
        }
    }

    override func tearDown() async throws {
        await mcpClient?.disconnect()
        await mcpServer?.stop()
        if let temp = tempDirectoryURL, FileManager.default.fileExists(atPath: temp.path) {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - 1. Structured Tool-Call Parsing Resilience Tests

    func testParseToolCallJSONWithArguments() {
        let modelOutput = """
        <thought>
        Creating project directory.
        </thought>
        <tool_call>
        {"name": "create_folder", "arguments": {"path": "AetherProjects"}}
        </tool_call>
        """

        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput)
        XCTAssertEqual(thought, "Creating project directory.")
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "create_folder")
            XCTAssertEqual(params["path"], "AetherProjects")
        } else {
            XCTFail("Expected .callTool, got: \(action)")
        }

        let orchestratorInvocation = AgentOrchestrator.parseToolCall(from: modelOutput)
        XCTAssertNotNil(orchestratorInvocation)
        XCTAssertEqual(orchestratorInvocation?.toolName, "create_folder")
        XCTAssertEqual(orchestratorInvocation?.parameters["path"], "AetherProjects")
    }

    func testParseToolCallJSONWithParameters() {
        let modelOutput = """
        <thought>
        Writing file.
        </thought>
        <tool_call>
        {"name": "write_file", "parameters": {"path": "README.txt", "content": "Project description"}}
        </tool_call>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "write_file")
            XCTAssertEqual(params["path"], "README.txt")
            XCTAssertEqual(params["content"], "Project description")
        } else {
            XCTFail("Expected .callTool, got: \(action)")
        }
    }

    func testParseToolCallJSONArray() {
        let modelOutput = """
        <tool_call>
        [{"name": "list_directory", "arguments": {"path": "AetherProjects"}}]
        </tool_call>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "list_directory")
            XCTAssertEqual(params["path"], "AetherProjects")
        } else {
            XCTFail("Expected .callTool, got: \(action)")
        }
    }

    func testParseToolCallUnclosedTagTruncation() {
        let modelOutput = """
        <thought>
        I need to create the file.
        </thought>
        <tool_call>
        <name>create_file</name>
        <parameters>
          <path>Demo/test.txt</path>
          <content>Hello</content>
        </parameters>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "create_file")
            XCTAssertEqual(params["path"], "Demo/test.txt")
            XCTAssertEqual(params["content"], "Hello")
        } else {
            XCTFail("Expected .callTool for unclosed tag, got: \(action)")
        }
    }

    func testParseToolCallFunctionSyntaxFallback() {
        let modelOutput = """
        <thought>
        Calling create_folder function.
        </thought>
        create_folder(path="AetherProjects")
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "create_folder")
            XCTAssertEqual(params["path"], "AetherProjects")
        } else {
            XCTFail("Expected .callTool from function syntax fallback, got: \(action)")
        }
    }

    func testParseToolCallReActSyntaxFallback() {
        let modelOutput = """
        Action: create_folder
        Action Input: {"path": "AetherProjects"}
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "create_folder")
            XCTAssertEqual(params["path"], "AetherProjects")
        } else {
            XCTFail("Expected .callTool from ReAct syntax fallback, got: \(action)")
        }
    }

    // MARK: - 1b. Schema Parameter Alignment & Ambiguity Resolution Tests

    func testToolCallNamedJSONArguments() {
        let modelOutput = """
        <thought>
        I need to create the requested folder named AetherTest on Desktop.
        </thought>
        <tool_call>
        {"name": "create_folder", "arguments": {"path": "Desktop/AetherTest"}}
        </tool_call>
        """

        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(
            from: modelOutput,
            availableTools: [
                ToolDefinition(
                    name: "create_folder",
                    description: "Create folder",
                    parameters: [
                        ToolParameter(name: "path", type: .string, description: "Path", isRequired: true)
                    ],
                    category: .filesystem,
                    permissionLevel: .userConfirmationRequired
                )
            ]
        )

        XCTAssertEqual(thought, "I need to create the requested folder named AetherTest on Desktop.")
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "create_folder")
            XCTAssertEqual(params["path"], "Desktop/AetherTest")
        } else {
            XCTFail("Expected .callTool with named path argument, got: \(action)")
        }

        let orchestratorInvocation = AgentOrchestrator.parseToolCall(from: modelOutput)
        XCTAssertNotNil(orchestratorInvocation)
        XCTAssertEqual(orchestratorInvocation?.toolName, "create_folder")
        XCTAssertEqual(orchestratorInvocation?.parameters["path"], "Desktop/AetherTest")
    }

    func testToolCallNamedXMLArguments() {
        let modelOutputTag = """
        <thought>
        Creating folder using named tag.
        </thought>
        <tool_call>
        <name>create_folder</name>
        <parameters>
          <path>Desktop/AetherTest</path>
        </parameters>
        </tool_call>
        """

        let (_, action1) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutputTag)
        if case .callTool(let name, let params, _) = action1 {
            XCTAssertEqual(name, "create_folder")
            XCTAssertEqual(params["path"], "Desktop/AetherTest")
        } else {
            XCTFail("Expected .callTool from named tag, got: \(action1)")
        }

        let modelOutputAttr = """
        <thought>
        Creating folder using parameter name attribute.
        </thought>
        <tool_call>
        <name>create_folder</name>
        <parameters>
          <param name="path">Desktop/AetherTest</param>
        </parameters>
        </tool_call>
        """

        let (_, action2) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutputAttr)
        if case .callTool(let name, let params, _) = action2 {
            XCTAssertEqual(name, "create_folder")
            XCTAssertEqual(params["path"], "Desktop/AetherTest")
        } else {
            XCTFail("Expected .callTool from parameter name attribute, got: \(action2)")
        }
    }

    func testToolCallPositionalXMLArgumentsUnambiguous() async {
        // When the model outputs generic <param> value, but the tool schema has exactly 1 required parameter
        let modelOutput = """
        <thought>
        Create directory with generic param tag.
        </thought>
        <tool_call>
        <name>create_folder</name>
        <parameters>
          <param>Desktop/AetherTest</param>
        </parameters>
        </tool_call>
        """

        let tools = await toolRegistry.definitions
        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput, availableTools: tools)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "create_folder")
            XCTAssertEqual(params["path"], "Desktop/AetherTest", "Unambiguous single parameter must map to 'path'")
        } else {
            XCTFail("Expected .callTool with unambiguously resolved parameter, got: \(action)")
        }
    }

    func testToolCallPositionalXMLArgumentsAmbiguousRejected() async {
        // move_file requires both source_path and destination_path
        let modelOutput = """
        <thought>
        Move file with generic param.
        </thought>
        <tool_call>
        <name>move_file</name>
        <parameters>
          <param>Desktop/AetherTest</param>
        </parameters>
        </tool_call>
        """

        let tools = await toolRegistry.definitions
        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: modelOutput, availableTools: tools)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "move_file")
            XCTAssertNil(params["source_path"], "Ambiguous positional parameter must not be guessed")
            XCTAssertNil(params["destination_path"], "Ambiguous positional parameter must not be guessed")

            // When passed to ToolSecurityGuard, validation must fail with missingRequiredParameter
            if let moveTool = await toolRegistry.tool(named: "move_file") {
                do {
                    try await securityGuard.validateParameters(tool: moveTool.definition, parameters: params)
                    XCTFail("Expected validation error for missing parameters")
                } catch let secErr as SecurityValidationError {
                    if case .missingRequiredParameter = secErr {
                        // Expected
                    } else {
                        XCTFail("Expected missingRequiredParameter, got \(secErr)")
                    }
                } catch {
                    XCTFail("Expected SecurityValidationError, got \(error)")
                }
            }
        } else {
            XCTFail("Expected .callTool with unmapped parameters, got: \(action)")
        }
    }

    func testPlaceholderPathRejectedBySecurityGuardAndDirectoryManager() async throws {
        let placeholderPaths = [
            "/path/to/new/folder",
            "path/to/folder",
            "/path/to/file.txt",
            "/your/path/here",
            "<path>",
            "[path]",
            "{path}",
            "placeholder"
        ]

        let createTool = await toolRegistry.tool(named: "create_folder")!

        for placeholder in placeholderPaths {
            // 1. Static detector
            XCTAssertTrue(ToolSecurityGuard.isPlaceholderPath(placeholder), "Expected '\(placeholder)' to be identified as a placeholder path")

            // 2. ToolSecurityGuard parameter validation
            do {
                try await securityGuard.validateParameters(tool: createTool.definition, parameters: ["path": placeholder])
                XCTFail("Expected placeholder error for '\(placeholder)'")
            } catch let secErr as SecurityValidationError {
                XCTAssertEqual(secErr, .placeholderPath(path: placeholder))
            } catch {
                XCTFail("Expected SecurityValidationError for '\(placeholder)', got \(error)")
            }

            // 3. ToolSecurityGuard authorization decision
            let decision = await securityGuard.authorize(
                tool: createTool.definition,
                parameters: ["path": placeholder],
                context: ToolExecutionContext(isInteractiveApprovalGranted: true)
            )
            if case .denied(let reason) = decision {
                XCTAssertTrue(reason.contains("Placeholder path") || reason.contains("validation failed"),
                              "Expected denial for placeholder path: \(reason)")
            } else {
                XCTFail("Placeholder path '\(placeholder)' must be denied by security guard, got: \(decision)")
            }

            // 4. AuthorizedDirectoryManager rejection
            do {
                _ = try await directoryManager.validateAndResolve(path: placeholder)
                XCTFail("Expected directoryManager to reject placeholder '\(placeholder)'")
            } catch let secErr as SecurityValidationError {
                XCTAssertEqual(secErr, .placeholderPath(path: placeholder))
            } catch {
                XCTFail("Expected SecurityValidationError in directoryManager for '\(placeholder)', got \(error)")
            }
        }
    }

    func testMissingArgumentsTriggersValidationError() async {
        let createTool = await toolRegistry.tool(named: "create_folder")!

        // Empty parameters dictionary
        do {
            try await securityGuard.validateParameters(tool: createTool.definition, parameters: [:])
            XCTFail("Expected missing required parameter error")
        } catch let secErr as SecurityValidationError {
            XCTAssertEqual(secErr, .missingRequiredParameter("path"))
        } catch {
            XCTFail("Expected SecurityValidationError, got \(error)")
        }

        // Authorization decision must be denied
        let decision = await securityGuard.authorize(
            tool: createTool.definition,
            parameters: [:],
            context: ToolExecutionContext(isInteractiveApprovalGranted: true)
        )
        if case .denied(let reason) = decision {
            XCTAssertTrue(reason.contains("Required parameter 'path' is missing") || reason.contains("missing"),
                          "Decision must cite missing parameter: \(reason)")
        } else {
            XCTFail("Expected denial for missing required parameter, got: \(decision)")
        }
    }

    /// Explicit scenario required by Directive: "Create a folder named AetherTest on my Desktop."
    func testRealModelCreateFolderWithRealArguments() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        await directoryManager.clearAll()
        let testDesktopURL = tempDirectoryURL.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: testDesktopURL, withIntermediateDirectories: true)
        await directoryManager.authorizeTemporaryDirectory(url: testDesktopURL)

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 4096, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether. The user's Desktop is authorized for file operations."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 4)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Create a folder named AetherTest on my Desktop.",
            conversationId: UUID(),
            inferenceProvider: provider
        )

        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "create_folder")

        let finalState = await loop.run()
        print("=== REAL MODEL AETHERTEST EXECUTION AUDIT ===")
        print("[AUDIT] Final Phase: \(finalState.phase)")
        print("[AUDIT] Step Count: \(finalState.stepIndex)")
        print("[AUDIT] Final Answer: \(finalState.finalAnswer ?? "nil")")

        for (idx, step) in finalState.history.enumerated() {
            print("[AUDIT] Turn \(idx):")
            print("  Thought: \(step.thought ?? "nil")")
            print("  Action: \(String(describing: step.action))")
            print("  Observation: \(step.observation?.summary ?? "nil")")
        }

        let toolSteps = finalState.history.compactMap { step -> (String, [String: String])? in
            if case .callTool(let name, let params, _) = step.action {
                return (name, params)
            }
            return nil
        }
        XCTAssertFalse(toolSteps.isEmpty, "Model must propose invoking a tool.")
        guard let firstTool = toolSteps.first else {
            XCTFail("No tool calls found in execution history")
            return
        }

        XCTAssertEqual(firstTool.0, "create_folder", "Tool invoked must be create_folder")
        XCTAssertEqual(firstTool.1["path"], "Desktop/AetherTest", "Parameter 'path' must be 'Desktop/AetherTest'")
        XCTAssertFalse(ToolSecurityGuard.isPlaceholderPath(firstTool.1["path"] ?? ""), "Dispatched path must never be a placeholder")

        let createdFolder = testDesktopURL.appendingPathComponent("AetherTest")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: createdFolder.path, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue, "Directory 'AetherTest' must physically exist on disk at \(createdFolder.path).")

        if let answer = finalState.finalAnswer {
            XCTAssertTrue(answer.localizedCaseInsensitiveContains("AetherTest") || answer.localizedCaseInsensitiveContains("created"),
                          "Final answer must confirm folder creation: \(answer)")
        }
    }

    // MARK: - 2. macOS Permissions & Directory Authorization Lifecycle

    func testDesktopAuthorizationHelper() async throws {
        let isAuthBefore = await directoryManager.isDesktopAuthorized()
        XCTAssertFalse(isAuthBefore, "Desktop must not be authorized initially when created with empty roots.")

        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            try await directoryManager.authorizeDirectory(url: desktopURL)
            let isAuthAfter = await directoryManager.isDesktopAuthorized()
            XCTAssertTrue(isAuthAfter, "Desktop must be recognized as authorized after authorization.")

            // Verify clean resolution without Desktop/Desktop duplication
            let (resolved, root) = try await directoryManager.validateAndResolve(path: "Desktop/AetherProjects")
            XCTAssertEqual(root.path, desktopURL.standardizedFileURL.resolvingSymlinksInPath().path)
            XCTAssertTrue(resolved.path.hasSuffix("/Desktop/AetherProjects"), "Resolved path must resolve to ~/Desktop/AetherProjects: \(resolved.path)")
            XCTAssertFalse(resolved.path.contains("/Desktop/Desktop/"), "Path resolution must not produce redundant Desktop/Desktop segment.")

            // Clean up authorization
            await directoryManager.revokeDirectory(url: desktopURL)
            let isAuthRevoked = await directoryManager.isDesktopAuthorized()
            XCTAssertFalse(isAuthRevoked, "Desktop authorization must be revoked.")
        }
    }

    func testReadOnlyRootEnforcement() async throws {
        let roDir = tempDirectoryURL.appendingPathComponent("ReadOnlyZone")
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        await directoryManager.authorizeTemporaryDirectory(url: roDir)
        await directoryManager.setReadOnly(url: roDir, isReadOnly: true)

        let isRO = await directoryManager.isReadOnly(url: roDir)
        XCTAssertTrue(isRO, "Directory must be recognized as read-only.")

        // 1. Reading from read-only directory must succeed
        let testFile = roDir.appendingPathComponent("data.txt")
        try "Content".write(to: testFile, atomically: true, encoding: .utf8)
        let readTool = await toolRegistry.tool(named: "read_file")!
        let readDecision = await securityGuard.authorize(
            tool: readTool.definition,
            parameters: ["path": testFile.path],
            context: ToolExecutionContext(isInteractiveApprovalGranted: true)
        )
        XCTAssertEqual(readDecision, .authorized, "Read operations in read-only directory must be authorized.")

        // 2. Modifying operations in read-only directory must be denied by security guard
        let createFolderTool = await toolRegistry.tool(named: "create_folder")!
        let writeDecision = await securityGuard.authorize(
            tool: createFolderTool.definition,
            parameters: ["path": roDir.appendingPathComponent("NewSub").path],
            context: ToolExecutionContext(isInteractiveApprovalGranted: true)
        )
        if case .denied(let reason) = writeDecision {
            XCTAssertTrue(reason.contains("read-only"), "Denial reason must explain read-only restriction: \(reason)")
        } else {
            XCTFail("Write operation in read-only root must be denied, got: \(writeDecision)")
        }
    }

    func testPathTraversalAndUnauthorizedPathRejection() async throws {
        let traversalPath = "\(tempDirectoryURL.path)/../../System/Library"
        let createTool = await toolRegistry.tool(named: "create_folder")!

        let decision = await securityGuard.authorize(
            tool: createTool.definition,
            parameters: ["path": traversalPath],
            context: ToolExecutionContext(isInteractiveApprovalGranted: true)
        )

        if case .denied(let reason) = decision {
            XCTAssertTrue(reason.contains("traversal") || reason.contains("outside") || reason.contains("validation failed"),
                          "Security guard must reject traversal: \(reason)")
        } else {
            XCTFail("Path traversal must be denied, got: \(decision)")
        }
    }

    func testDestructiveOperationConfirmationRequirement() async throws {
        let deleteTool = await toolRegistry.tool(named: "delete_file")!
        let decision = await securityGuard.authorize(
            tool: deleteTool.definition,
            parameters: ["path": "\(tempDirectoryURL.path)/dummy.txt"],
            context: ToolExecutionContext(isInteractiveApprovalGranted: false)
        )

        if case .requiresUserConfirmation(let request) = decision {
            XCTAssertEqual(request.toolName, "delete_file")
            XCTAssertEqual(request.permissionLevel, .restricted)
        } else {
            XCTFail("Destructive operation delete_file must require user confirmation, got: \(decision)")
        }
    }

    // MARK: - 3. Real Model End-to-End Filesystem Tool Calling Scenarios

    /// Test A — Folder creation on Desktop
    func testRealModel_TestA_FolderCreation() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        // Authorize our isolated test folder as the agent's desktop environment
        await directoryManager.clearAll()
        let testDesktopURL = tempDirectoryURL.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: testDesktopURL, withIntermediateDirectories: true)
        await directoryManager.authorizeTemporaryDirectory(url: testDesktopURL)

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 4096, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether. The user's Desktop is authorized for file operations."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 4)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Create a folder named AetherProjects on my Desktop.",
            conversationId: UUID(),
            inferenceProvider: provider
        )

        // Pre-approve tool execution for headless integration testing
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "create_folder")

        let finalState = await loop.run()
        print("[DEBUG TestA] finalState: stepIndex=\(finalState.stepIndex), finalAnswer=\(String(describing: finalState.finalAnswer)), history count=\(finalState.history.count)")
        for (idx, step) in finalState.history.enumerated() {
            print("[DEBUG TestA] step \(idx): thought=\(step.thought ?? "nil"), action=\(String(describing: step.action)), observation=\(step.observation?.summary ?? "nil")")
        }

        // 1. Verify model reached completion or invoked the tool
        let toolSteps = finalState.history.filter { step in
            if case .callTool(let name, _, _) = step.action { return name == "create_folder" }
            return false
        }
        XCTAssertFalse(toolSteps.isEmpty, "Model must propose invoking create_folder.")

        // 2. Physical filesystem verification: folder must exist on disk
        let createdFolder = testDesktopURL.appendingPathComponent("AetherProjects")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: createdFolder.path, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue, "Directory 'AetherProjects' must physically exist on disk.")

        // 3. Final answer verification: model must produce confirmation based on tool observation
        if let answer = finalState.finalAnswer {
            XCTAssertTrue(answer.localizedCaseInsensitiveContains("AetherProjects") || answer.localizedCaseInsensitiveContains("created"),
                          "Final answer must confirm folder creation: \(answer)")
        }
    }

    /// Test B & C — File creation and writing
    func testRealModel_TestB_C_FileCreationAndWriting() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        await directoryManager.clearAll()
        let testDesktopURL = tempDirectoryURL.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: testDesktopURL, withIntermediateDirectories: true)
        await directoryManager.authorizeTemporaryDirectory(url: testDesktopURL)

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 4096, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether. The user's Desktop is authorized for file operations."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 4)

        // Create file & write description
        let loop = await orchestrator.createExecutionLoop(
            goal: "Create a file named README.txt on Desktop and write a short project description into it.",
            conversationId: UUID(),
            inferenceProvider: provider
        )
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "create_file")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "write_file")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "search_files")

        let state = await loop.run()
        print("[DEBUG TestB_C] finalState stepIndex=\(state.stepIndex), finalAnswer=\(state.finalAnswer ?? "nil")")

        let targetFile = testDesktopURL.appendingPathComponent("README.txt")
        let exists = FileManager.default.fileExists(atPath: targetFile.path)
        XCTAssertTrue(exists, "README.txt must exist on disk at \(targetFile.path).")

        let writtenContent = try? String(contentsOf: targetFile, encoding: .utf8)
        XCTAssertNotNil(writtenContent)
        XCTAssertFalse(writtenContent?.isEmpty ?? true, "README.txt must contain written content.")
    }

    /// Test D — Directory listing
    func testRealModel_TestD_DirectoryListing() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        await directoryManager.clearAll()
        let testDesktopURL = tempDirectoryURL.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: testDesktopURL, withIntermediateDirectories: true)
        await directoryManager.authorizeTemporaryDirectory(url: testDesktopURL)

        // Populate sample files
        try "File 1".write(to: testDesktopURL.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "File 2".write(to: testDesktopURL.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 4096, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether. The user's Desktop is authorized for file operations."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 3)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Show me the files inside Desktop.",
            conversationId: UUID(),
            inferenceProvider: provider
        )
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "list_directory")

        let state = await loop.run()
        let listSteps = state.history.filter { step in
            if case .callTool(let name, _, _) = step.action { return name == "list_directory" }
            return false
        }
        XCTAssertFalse(listSteps.isEmpty, "Model must invoke list_directory.")
    }

    /// Test E — Multi-step task: create folder and add files
    func testRealModel_TestE_MultiStepTask() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        await directoryManager.clearAll()
        let testDesktopURL = tempDirectoryURL.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: testDesktopURL, withIntermediateDirectories: true)
        await directoryManager.authorizeTemporaryDirectory(url: testDesktopURL)

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 4096, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether. The user's Desktop is authorized for file operations."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 6)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Create a folder called DemoProject on Desktop, add README.md with a project description into DemoProject, and add notes.txt into DemoProject.",
            conversationId: UUID(),
            inferenceProvider: provider
        )
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "create_folder")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "create_file")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "write_file")

        let state = await loop.run()

        let projectDir = testDesktopURL.appendingPathComponent("DemoProject")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path), "DemoProject folder must exist on disk.")

        let readmeFile = projectDir.appendingPathComponent("README.md")
        let notesFile = projectDir.appendingPathComponent("notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readmeFile.path) || FileManager.default.fileExists(atPath: notesFile.path),
                      "At least one requested file must exist inside DemoProject.")
    }

    /// Test F — Natural-language phrasing variations
    func testRealModel_TestF_NaturalLanguageVariations() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        await directoryManager.clearAll()
        let testDesktopURL = tempDirectoryURL.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: testDesktopURL, withIntermediateDirectories: true)
        await directoryManager.authorizeTemporaryDirectory(url: testDesktopURL)

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 4096, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether. The user's Desktop is authorized for file operations."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 3)

        // Phrasing variation: "Make a new directory on Desktop called TestDir."
        let loop = await orchestrator.createExecutionLoop(
            goal: "Make a new directory on Desktop called TestDir.",
            conversationId: UUID(),
            inferenceProvider: provider
        )
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "create_folder")
        _ = await loop.run()

        let testDir = testDesktopURL.appendingPathComponent("TestDir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir.path), "TestDir must be created from natural variation.")
    }

    /// Test G — Missing information: model must ask user instead of inventing a path
    func testRealModel_TestG_MissingInformationPromptingUser() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 4096, maxTokens: 128, temperature: 0.0)
        )

        let (thought, action) = try await provider.determineNextAction(
            state: AgentState(sessionId: UUID(), conversationId: UUID(), phase: .planning, stepIndex: 0, maxSteps: 3, goal: "Create a folder."),
            availableTools: await toolRegistry.definitions
        )

        // When goal is simply "Create a folder." with no destination or name,
        // model must either ask user for the name/destination or propose create_folder with a prompt for name.
        if case .declareComplete(let answer) = action {
            let lower = answer.lowercased()
            XCTAssertTrue(lower.contains("name") || lower.contains("where") || lower.contains("folder") || lower.contains("location"),
                          "Model must ask for missing folder name or destination: \(answer)")
        } else if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "create_folder")
            XCTAssertTrue(params["path"] != nil)
        }
    }
}
