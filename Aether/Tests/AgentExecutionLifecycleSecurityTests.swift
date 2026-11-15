import XCTest
@testable import Aether

private actor LifecycleSecurityTestProvider: AgentInferenceProvider {
    var nextActionResult: (thought: String?, action: AgentAction)?

    func determineNextAction(
        state: AgentState,
        availableTools: [ToolDefinition],
        cancellationSignal: CancellationSignal?
    ) async throws -> (thought: String?, action: AgentAction) {
        if Task.isCancelled || cancellationSignal?.isCancelled == true {
            throw CancellationError()
        }
        return nextActionResult ?? (thought: nil, action: .declareComplete(finalAnswer: "Finished"))
    }

    func evaluateObservation(
        state: AgentState,
        observation: AgentObservation,
        cancellationSignal: CancellationSignal?
    ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?) {
        return (isComplete: true, nextAction: nil, finalAnswer: "Done")
    }
}

final class AgentExecutionLifecycleSecurityTests: XCTestCase {
    var registry: ToolRegistry!
    var securityGuard: ToolSecurityGuard!
    var tempDirectory: URL!
    var directoryManager: AuthorizedDirectoryManager!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempDirectory = fm.temporaryDirectory.appendingPathComponent("AetherLifecycle_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        directoryManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        try await directoryManager.authorizeDirectory(url: tempDirectory)

        securityGuard = ToolSecurityGuard(directoryManager: directoryManager)
        registry = ToolRegistry(securityGuard: securityGuard)

        let server = MCPFilesystemServer(directoryManager: directoryManager)
        let (clientT, serverT) = MCPInMemoryTransport.createPair()
        await server.start(transport: serverT)
        let client = MCPClient()
        await client.connect(transport: clientT)

        for toolDef in await server.allToolDefinitions() {
            let adapter = MCPToolAdapter(mcpTool: toolDef, client: client)
            await registry.register(adapter)
        }
    }

    override func tearDown() async throws {
        let fm = FileManager.default
        if let temp = tempDirectory {
            try? fm.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    func testStaleOrMismatchedConfirmationRequestIdRejected() async {
        let convId = UUID()
        let provider = LifecycleSecurityTestProvider()
        let initialState = AgentState(conversationId: convId, goal: "Test stale confirmation")
        let loop = AgentExecutionLoopActor(
            initialState: initialState,
            registry: registry,
            securityGuard: securityGuard,
            inferenceProvider: provider
        )

        // Submit confirmation decision when loop is NOT awaiting confirmation
        await loop.submitConfirmationDecision(
            requestId: UUID(),
            toolName: "delete_file",
            approved: true
        )

        let state = await loop.state
        XCTAssertNotEqual(state.phase, AgentPhase.executing, "Should not transition to executing on unrequested confirmation")
    }

    func testCancellationHaltsExecutionImmediately() async {
        let convId = UUID()
        let provider = LifecycleSecurityTestProvider()
        let initialState = AgentState(conversationId: convId, goal: "Create a folder")
        let loop = AgentExecutionLoopActor(
            initialState: initialState,
            registry: registry,
            securityGuard: securityGuard,
            inferenceProvider: provider
        )

        await loop.sessionSignal.cancel()

        let finalState = await loop.run()
        XCTAssertEqual(finalState.phase, AgentPhase.cancelled)
    }

    func testPrematureFinalAnswerWithToolCallExecutesTool() async throws {
        // Model provides tool call AND premature final answer in one response
        let mockModelOutput = """
        <thought>Creating folder</thought>
        <tool_call>
        <name>create_folder</name>
        <parameters>
            <path>\(tempDirectory.appendingPathComponent("SubProject").path)</path>
        </parameters>
        </tool_call>
        <final_answer>I have created the folder.</final_answer>
        """

        let tools = await registry.definitions
        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: mockModelOutput, availableTools: tools)

        // Verify that the parser returned .callTool rather than .declareComplete
        guard case .callTool(let name, let params, _) = action else {
            XCTFail("Parser must prioritize tool call over premature final answer, got: \(action)")
            return
        }

        XCTAssertEqual(name, "create_folder")
        XCTAssertEqual(params["path"], tempDirectory.appendingPathComponent("SubProject").path)
    }
}
