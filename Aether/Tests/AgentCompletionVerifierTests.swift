import XCTest
@testable import Aether

final class AgentCompletionVerifierTests: XCTestCase {

    var registry: ToolRegistry!
    var securityGuard: ToolSecurityGuard!
    var directoryManager: AuthorizedDirectoryManager!
    var tempDirectory: URL!
    var mcpServer: MCPFilesystemServer!
    var mcpClient: MCPClient!
    let testConversationId = UUID()

    override func setUp() async throws {
        directoryManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCompletionVerifierTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try await directoryManager.authorizeDirectory(url: tempDirectory)

        securityGuard = ToolSecurityGuard(directoryManager: directoryManager)
        registry = ToolRegistry(securityGuard: securityGuard)
        await registry.register(SystemInfoTool())
        await registry.register(SafeCalculatorTool())
        await registry.register(SandboxedFileReaderTool(securityGuard: securityGuard))

        mcpServer = MCPFilesystemServer(directoryManager: directoryManager)
        let (clientT, serverT) = MCPInMemoryTransport.createPair()
        await mcpServer.start(transport: serverT)
        mcpClient = MCPClient()
        await mcpClient.connect(transport: clientT)
        _ = try await mcpClient.initialize(clientInfo: MCPImplementation(name: "AetherTestRunner", version: "1.0.0"))
        let discoveredTools = try await mcpClient.listTools()
        for tool in discoveredTools {
            let adapter = MCPToolAdapter(mcpTool: tool, client: mcpClient)
            await registry.register(adapter)
            await securityGuard.grantSessionPermission(conversationId: testConversationId, toolName: tool.name)
        }
    }

    override func tearDown() async throws {
        await mcpClient?.disconnect()
        await mcpServer?.stop()
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    // MARK: - 1. Non-Filesystem Goal Verification

    func testVerifyNonFilesystemGoalPassesImmediately() async {
        let state = AgentState(
            conversationId: testConversationId,
            phase: .evaluating,
            stepIndex: 1,
            goal: "Calculate 125 * 48",
            history: [
                AgentStepRecord(
                    stepIndex: 1,
                    phase: .observing,
                    thought: "Compute math",
                    action: .callTool(toolName: "calculator", parameters: ["expression": "125 * 48"], thought: nil),
                    observation: .toolSuccess(toolName: "calculator", output: "6000", durationSeconds: 0.01)
                )
            ]
        )

        let result = await AgentCompletionVerifier.verify(state: state, registry: registry)
        if case .verified(let details) = result {
            XCTAssertTrue(details.contains("No mutating filesystem operations"))
        } else {
            XCTFail("Expected .verified for calculation task, got \(result)")
        }
    }

    // MARK: - 2. Folder Creation Verification

    func testVerifyFilesystemCreationSucceedsWhenFolderExists() async throws {
        let folderName = "VerifiedFolder_\(UUID().uuidString)"
        let targetFolderURL = tempDirectory.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: targetFolderURL, withIntermediateDirectories: true)

        let state = AgentState(
            conversationId: testConversationId,
            phase: .evaluating,
            stepIndex: 1,
            goal: "Create folder named \(folderName)",
            history: [
                AgentStepRecord(
                    stepIndex: 1,
                    phase: .observing,
                    thought: "Creating folder",
                    action: .callTool(toolName: "create_folder", parameters: ["path": targetFolderURL.path], thought: nil),
                    observation: .toolSuccess(toolName: "create_folder", output: "Created", durationSeconds: 0.01)
                )
            ]
        )

        let result = await AgentCompletionVerifier.verify(state: state, registry: registry)
        if case .verified(let details) = result {
            XCTAssertTrue(details.contains("Verified 1 destination"))
        } else {
            XCTFail("Expected .verified for existing folder, got \(result)")
        }
    }

    func testVerifyFilesystemCreationFailsWhenFolderDoesNotExist() async {
        let nonExistentPath = tempDirectory.appendingPathComponent("NonExistentFolder_\(UUID().uuidString)").path

        let state = AgentState(
            conversationId: testConversationId,
            phase: .evaluating,
            stepIndex: 1,
            goal: "Create folder",
            history: [
                AgentStepRecord(
                    stepIndex: 1,
                    phase: .observing,
                    thought: "Create folder",
                    action: .callTool(toolName: "create_folder", parameters: ["path": nonExistentPath], thought: nil),
                    observation: .toolSuccess(toolName: "create_folder", output: "Created", durationSeconds: 0.01)
                )
            ]
        )

        let result = await AgentCompletionVerifier.verify(state: state, registry: registry)
        if case .unverified(let reason) = result {
            XCTAssertTrue(reason.contains("does not exist on disk"))
        } else {
            XCTFail("Expected .unverified for non-existent folder, got \(result)")
        }
    }

    // MARK: - 3. File Non-Empty Verification

    func testVerifyFileWriteFailsWhenFileIsEmpty() async throws {
        let emptyFileURL = tempDirectory.appendingPathComponent("empty_test.txt")
        FileManager.default.createFile(atPath: emptyFileURL.path, contents: Data())

        let state = AgentState(
            conversationId: testConversationId,
            phase: .evaluating,
            stepIndex: 1,
            goal: "Write notes to empty_test.txt",
            history: [
                AgentStepRecord(
                    stepIndex: 1,
                    phase: .observing,
                    thought: "Writing notes",
                    action: .callTool(toolName: "write_file", parameters: ["path": emptyFileURL.path, "content": "Sample non-empty content"], thought: nil),
                    observation: .toolSuccess(toolName: "write_file", output: "Written", durationSeconds: 0.01)
                )
            ]
        )

        let result = await AgentCompletionVerifier.verify(state: state, registry: registry)
        if case .unverified(let reason) = result {
            XCTAssertTrue(reason.contains("empty (0 bytes)"))
        } else {
            XCTFail("Expected .unverified for 0-byte file when non-empty content was expected, got \(result)")
        }
    }

    func testVerifyFileWriteSucceedsWhenFileIsNonEmpty() async throws {
        let validFileURL = tempDirectory.appendingPathComponent("valid_test.txt")
        try "Production contents for Aether".write(to: validFileURL, atomically: true, encoding: .utf8)

        let state = AgentState(
            conversationId: testConversationId,
            phase: .evaluating,
            stepIndex: 1,
            goal: "Write notes to valid_test.txt",
            history: [
                AgentStepRecord(
                    stepIndex: 1,
                    phase: .observing,
                    thought: "Writing notes",
                    action: .callTool(toolName: "write_file", parameters: ["path": validFileURL.path, "content": "Production contents for Aether"], thought: nil),
                    observation: .toolSuccess(toolName: "write_file", output: "Written", durationSeconds: 0.01)
                )
            ]
        )

        let result = await AgentCompletionVerifier.verify(state: state, registry: registry)
        if case .verified(let details) = result {
            XCTAssertTrue(details.contains("Verified 1 destination"))
        } else {
            XCTFail("Expected .verified for non-empty file, got \(result)")
        }
    }

    // MARK: - 4. Hallucinated / Simulated Completion Prevention

    func testVerifyHallucinatedCompletionWithoutToolsFails() async {
        let state = AgentState(
            conversationId: testConversationId,
            phase: .planning,
            stepIndex: 1,
            goal: "Create a folder named AetherProjects on my Desktop",
            history: [] // No tools executed!
        )

        let result = await AgentCompletionVerifier.verify(state: state, registry: registry)
        if case .unverified(let reason) = result {
            XCTAssertTrue(reason.contains("no filesystem tools were executed"))
        } else {
            XCTFail("Expected .unverified for hallucinated completion without tools, got \(result)")
        }
    }

    // MARK: - 5. Self-Correction Loop Driven by Verification Failure

    func testAgentExecutionLoopRecoversFromVerificationFailure() async throws {
        let testDirURL = tempDirectory.appendingPathComponent("RecoverableFolder")

        // Step 1: Model tries to declare complete without creating the folder (hallucination)
        // Step 2: Verification fails, yielding .toolFailure observation
        // Step 3: Model inspects failure and actually creates folder
        // Step 4: Model declares complete again -> verification passes!
        let provider = MockAgentInferenceProvider(
            actions: [
                // Step 1: premature declareComplete
                (thought: "I think it is already done.", action: .declareComplete(finalAnswer: "All done early")),
                // Step 2: received verification failure, now actually call create_folder
                (thought: "Verification showed it was not created. Now creating it.",
                 action: .callTool(toolName: "create_folder", parameters: ["path": testDirURL.path], thought: "Create directory")),
                // Step 3: declare complete after creating
                (thought: "Now folder is created, declaring complete.", action: .declareComplete(finalAnswer: "Folder verified and created."))
            ],
            evaluations: [
                // Eval for step 2 tool call
                (isComplete: false, nextAction: nil, finalAnswer: nil)
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Create folder named RecoverableFolder",
            conversationId: testConversationId,
            inferenceProvider: provider,
            maxSteps: 5
        )

        let finalState = await loop.run()

        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "Folder verified and created.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDirURL.path))
    }
}
