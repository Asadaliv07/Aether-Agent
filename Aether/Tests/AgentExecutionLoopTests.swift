import XCTest
@testable import Aether

// MARK: - Mock Inference Provider for Deterministic Testing

actor MockAgentInferenceProvider: AgentInferenceProvider {
    private var actionQueue: [(thought: String?, action: AgentAction)] = []
    private var evaluationQueue: [(isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?)] = []
    private var actionError: Error?
    private var evaluationError: Error?
    private var shouldCancelCurrentTaskOnAction: Bool = false
    private(set) var observedObservations: [AgentObservation] = []

    init(
        actions: [(thought: String?, action: AgentAction)] = [],
        evaluations: [(isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?)] = [],
        actionError: Error? = nil,
        evaluationError: Error? = nil
    ) {
        self.actionQueue = actions
        self.evaluationQueue = evaluations
        self.actionError = actionError
        self.evaluationError = evaluationError
    }

    func enqueueAction(thought: String?, action: AgentAction) {
        actionQueue.append((thought, action))
    }

    func enqueueEvaluation(isComplete: Bool, nextAction: AgentAction? = nil, finalAnswer: String? = nil) {
        evaluationQueue.append((isComplete, nextAction, finalAnswer))
    }

    func setActionError(_ error: Error?) {
        self.actionError = error
    }

    func setEvaluationError(_ error: Error?) {
        self.evaluationError = error
    }

    func setCancelCurrentTaskOnAction(_ cancel: Bool) {
        self.shouldCancelCurrentTaskOnAction = cancel
    }

    func determineNextAction(
        state: AgentState,
        availableTools: [ToolDefinition]
    ) async throws -> (thought: String?, action: AgentAction) {
        if shouldCancelCurrentTaskOnAction {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if let err = actionError {
            throw err
        }
        guard !actionQueue.isEmpty else {
            return ("No more actions in queue", .declareComplete(finalAnswer: "Default completed"))
        }
        return actionQueue.removeFirst()
    }

    func evaluateObservation(
        state: AgentState,
        observation: AgentObservation
    ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?) {
        observedObservations.append(observation)
        if let err = evaluationError {
            throw err
        }
        guard !evaluationQueue.isEmpty else {
            return (true, nil, "Evaluated complete")
        }
        return evaluationQueue.removeFirst()
    }
}

// MARK: - Mock Slow Tool for Timeouts and Cancellation

struct MockSlowTool: Tool {
    let definition: ToolDefinition
    let delayNanoseconds: UInt64

    init(name: String = "slow_tool", delaySeconds: Double = 0.2) {
        self.definition = ToolDefinition(
            name: name,
            description: "Deterministic slow tool for testing timeouts and cooperative cancellation",
            permissionLevel: .safeReadOnly
        )
        self.delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
    }

    func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return .success(toolName: definition.name, output: "Delayed output from \(definition.name)")
    }
}

// MARK: - Test Suite

final class AgentExecutionLoopTests: XCTestCase {

    var registry: ToolRegistry!
    var securityGuard: ToolSecurityGuard!
    var directoryManager: AuthorizedDirectoryManager!
    var tempDirectory: URL!
    var testFile: URL!
    let testConversationId = UUID()

    override func setUp() async throws {
        directoryManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentExecutionLoopTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try await directoryManager.authorizeDirectory(url: tempDirectory)
        testFile = tempDirectory.appendingPathComponent("test.txt")
        try "Test content".write(to: testFile, atomically: true, encoding: .utf8)

        registry = ToolRegistry()
        securityGuard = ToolSecurityGuard(directoryManager: directoryManager)
        await registry.register(SystemInfoTool())
        await registry.register(SafeCalculatorTool())
        await registry.register(SandboxedFileReaderTool(securityGuard: securityGuard))
    }

    override func tearDown() async throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    // MARK: - 1. State Machine & Transition Tests

    func testInitialStateIsIdleAndValidTransitions() {
        let state = AgentState(conversationId: testConversationId, goal: "Test Goal")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.stepIndex, 0)
        XCTAssertTrue(state.history.isEmpty)

        // Valid transitions
        XCTAssertTrue(AgentState.isValidTransition(from: .idle, to: .understanding))
        XCTAssertTrue(AgentState.isValidTransition(from: .understanding, to: .planning))
        XCTAssertTrue(AgentState.isValidTransition(from: .planning, to: .executing))
        XCTAssertTrue(AgentState.isValidTransition(from: .executing, to: .observing))
        XCTAssertTrue(AgentState.isValidTransition(from: .executing, to: .awaitingConfirmation))
        XCTAssertTrue(AgentState.isValidTransition(from: .awaitingConfirmation, to: .executing))
        XCTAssertTrue(AgentState.isValidTransition(from: .awaitingConfirmation, to: .observing))
        XCTAssertTrue(AgentState.isValidTransition(from: .observing, to: .evaluating))
        XCTAssertTrue(AgentState.isValidTransition(from: .evaluating, to: .executing))
        XCTAssertTrue(AgentState.isValidTransition(from: .evaluating, to: .completed))

        // Non-terminal states can transition to cancelled or failed
        XCTAssertTrue(AgentState.isValidTransition(from: .planning, to: .cancelled))
        XCTAssertTrue(AgentState.isValidTransition(from: .executing, to: .failed))

        // Invalid transitions
        XCTAssertFalse(AgentState.isValidTransition(from: .idle, to: .executing))
        XCTAssertFalse(AgentState.isValidTransition(from: .idle, to: .completed))
        XCTAssertFalse(AgentState.isValidTransition(from: .completed, to: .planning))
        XCTAssertFalse(AgentState.isValidTransition(from: .failed, to: .executing))
        XCTAssertFalse(AgentState.isValidTransition(from: .cancelled, to: .understanding))
    }

    // MARK: - 2. Direct Completion Without Tools

    func testDirectCompletionWithoutTools() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "No tools needed.", action: .declareComplete(finalAnswer: "Swift actors isolate mutable state."))
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "What are Swift actors?",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let finalState = await loop.run()

        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "Swift actors isolate mutable state.")
        XCTAssertEqual(finalState.stepIndex, 1)
        XCTAssertEqual(finalState.history.count, 1)
        XCTAssertEqual(finalState.history.first?.thought, "No tools needed.")
    }

    // MARK: - 3. Multi-Step Cyclic Execution

    func testMultiStepCyclicExecutionWithTools() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                // Step 1: Call system_info
                (thought: "First let me inspect hardware specifications.",
                 action: .callTool(toolName: "system_info", parameters: [:], thought: "Inspect hardware")),
                // Step 2: Call calculator
                (thought: "Now compute memory in megabytes.",
                 action: .callTool(toolName: "calculator", parameters: ["expression": "16 * 1024"], thought: "Calculate MB"))
            ],
            evaluations: [
                // Evaluation for Step 1: Not complete, need step 2
                (isComplete: false, nextAction: nil, finalAnswer: nil),
                // Evaluation for Step 2: Complete with final answer
                (isComplete: true, nextAction: nil, finalAnswer: "System has 16384 MB unified memory.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Check memory and convert to MB",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let finalState = await loop.run()

        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.stepIndex, 2)
        XCTAssertEqual(finalState.history.count, 2)
        XCTAssertEqual(finalState.finalAnswer, "System has 16384 MB unified memory.")

        // Verify Step 1 observation
        if case .toolSuccess(let name, let output, _) = finalState.history[0].observation {
            XCTAssertEqual(name, "system_info")
            XCTAssertTrue(output.contains("Apple Silicon"))
        } else {
            XCTFail("Expected toolSuccess for step 1")
        }

        // Verify Step 2 observation
        if case .toolSuccess(let name, let output, _) = finalState.history[1].observation {
            XCTAssertEqual(name, "calculator")
            XCTAssertTrue(output.contains("16384"))
        } else {
            XCTFail("Expected toolSuccess for step 2")
        }
    }

    // MARK: - 4. Action-Observation Decoupling & Tool Failure

    func testToolFailureHandling() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Attempt to call unregistered tool.",
                 action: .callTool(toolName: "unknown_external_tool", parameters: [:], thought: nil))
            ],
            evaluations: [
                // Evaluation receives failure observation and decides to abort gracefully
                (isComplete: true, nextAction: nil, finalAnswer: "Tool was unavailable; handled failure.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Trigger tool error",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let finalState = await loop.run()

        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.history.count, 1)

        // Verify observation recorded is toolFailure
        if case .toolFailure(let name, let err, _) = finalState.history.first?.observation {
            XCTAssertEqual(name, "unknown_external_tool")
            XCTAssertTrue(err.contains("not registered"))
        } else {
            XCTFail("Expected toolFailure observation")
        }
    }

    // MARK: - 5. Interactive Confirmation Gate (Approval)

    func testConfirmationApprovalGate() async {
        let path = testFile.path
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Read sensitive user file.",
                 action: .callTool(toolName: "file_reader", parameters: ["path": path], thought: nil))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "File read successfully.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Read file",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        // Run loop in detached task capturing loop by value
        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        // Wait briefly for the loop to reach awaitingConfirmation
        try? await Task.sleep(nanoseconds: 50_000_000)

        let intermediatePhase = await loop.state.phase
        XCTAssertEqual(intermediatePhase, .awaitingConfirmation)

        // Submit approval
        await loop.submitConfirmationDecision(approved: true)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "File read successfully.")
    }

    // MARK: - 6. Interactive Confirmation Gate (Rejection)

    func testConfirmationRejectionGate() async {
        let path = testFile.path
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Read sensitive user file.",
                 action: .callTool(toolName: "file_reader", parameters: ["path": path], thought: nil))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "User denied file access.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Read file",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        let intermediatePhase = await loop.state.phase
        XCTAssertEqual(intermediatePhase, .awaitingConfirmation)

        // Submit rejection
        await loop.submitConfirmationDecision(approved: false)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)

        if case .confirmationDecision(let toolName, let approved) = finalState.lastObservation {
            XCTAssertEqual(toolName, "file_reader")
            XCTAssertFalse(approved)
        } else {
            XCTFail("Expected confirmationDecision with approved=false")
        }
    }

    // MARK: - 7. Maximum Steps Circuit Breaker

    func testMaxStepsCircuitBreaker() async {
        // Provider keeps looping forever with isComplete = false
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Step 1", action: .callTool(toolName: "system_info", parameters: [:], thought: nil)),
                (thought: "Step 2", action: .callTool(toolName: "system_info", parameters: [:], thought: nil)),
                (thought: "Step 3", action: .callTool(toolName: "system_info", parameters: [:], thought: nil)),
                (thought: "Step 4", action: .callTool(toolName: "system_info", parameters: [:], thought: nil))
            ],
            evaluations: [
                (isComplete: false, nextAction: nil, finalAnswer: nil),
                (isComplete: false, nextAction: nil, finalAnswer: nil),
                (isComplete: false, nextAction: nil, finalAnswer: nil),
                (isComplete: false, nextAction: nil, finalAnswer: nil)
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Run infinite loop",
            conversationId: testConversationId,
            inferenceProvider: provider,
            maxSteps: 3
        )

        let finalState = await loop.run()

        XCTAssertEqual(finalState.phase, .failed)
        XCTAssertEqual(finalState.stepIndex, 3)
        XCTAssertTrue(finalState.errorDescription?.contains("Maximum execution steps (3) exceeded") == true)
    }

    // MARK: - 8. Cooperative Cancellation

    func testCooperativeCancellation() async {
        let path = testFile.path
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Reading file", action: .callTool(toolName: "file_reader", parameters: ["path": path], thought: nil))
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Cancel me",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        // Cancel the loop while awaiting confirmation
        await loop.cancel()

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .cancelled)
    }

    // MARK: - 9. Event Streaming Verification

    func testEventStreamingEmitsLifecycleEvents() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Checking specs", action: .callTool(toolName: "system_info", parameters: [:], thought: "Spec thought"))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Done")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Stream events",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let stream = await loop.makeEventStream()

        let streamTask = Task.detached { () -> [AgentExecutionEvent] in
            var collected: [AgentExecutionEvent] = []
            for await event in stream {
                collected.append(event)
                if case .completed = event {
                    break
                }
            }
            return collected
        }

        await loop.run()
        let receivedEvents = await streamTask.value

        XCTAssertTrue(receivedEvents.contains(where: {
            if case .stateChanged(from: .idle, to: .understanding) = $0 { return true }
            return false
        }))
        XCTAssertTrue(receivedEvents.contains(where: {
            if case .actionExecuting(let name) = $0 { return name == "system_info" }
            return false
        }))
        XCTAssertTrue(receivedEvents.contains(where: {
            if case .completed(let ans, _) = $0 { return ans == "Done" }
            return false
        }))
    }

    // MARK: - 10. Explicit Confirmation (Approval)

    func testExplicitConfirmationApprovalExecutesTool() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Request permission to query system specs.",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Allow reading system specifications?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Specs gathered after user approval.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Explicit approval test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        // Wait for loop to transition into .awaitingConfirmation
        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        let activeReqId = await loop.activeConfirmationRequestId
        XCTAssertNotNil(activeReqId)

        // Submit approval using the active request ID
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "system_info", approved: true)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "Specs gathered after user approval.")
        XCTAssertEqual(finalState.history.count, 1)

        // Verify that the tool was actually executed and produced toolSuccess
        if case .toolSuccess(let name, let output, _) = finalState.history[0].observation {
            XCTAssertEqual(name, "system_info")
            XCTAssertTrue(output.contains("Apple Silicon"))
        } else {
            XCTFail("Expected toolSuccess observation following approved explicit confirmation, got \(String(describing: finalState.history.first?.observation))")
        }
    }

    // MARK: - 11. Explicit Confirmation (Rejection)

    func testExplicitConfirmationRejectionPreventsToolExecution() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Request permission to inspect system info.",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Allow reading system specifications?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Handled user rejection cleanly.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Explicit rejection test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        let activeReqId = await loop.activeConfirmationRequestId
        XCTAssertNotNil(activeReqId)

        // Submit rejection
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "system_info", approved: false)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "Handled user rejection cleanly.")
        XCTAssertEqual(finalState.history.count, 1)

        // Verify observation is confirmationDecision with approved=false
        if case .confirmationDecision(let toolName, let approved) = finalState.history[0].observation {
            XCTAssertEqual(toolName, "system_info")
            XCTAssertFalse(approved)
        } else {
            XCTFail("Expected confirmationDecision with approved=false, got \(String(describing: finalState.history.first?.observation))")
        }
    }

    // MARK: - 12. Task Cancellation While Awaiting Confirmation

    func testExternalTaskCancellationWhileAwaitingConfirmation() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Requesting confirmation",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Proceed?"
                 ))
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "External task cancel test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        // Cancel the outer Task directly
        runTask.cancel()

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .cancelled)
        let loopPhase = await loop.state.phase
        XCTAssertEqual(loopPhase, .cancelled)
    }

    // MARK: - 13. Cancellation Racing With Confirmation Decision

    func testCancellationRacingWithConfirmationApproval() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Requesting confirmation",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Proceed?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Completed if approved in race.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Race cancellation test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        // Fire both cancel and submitConfirmationDecision concurrently
        async let cancelOp: Void = loop.cancel()
        async let approveOp: Void = loop.submitConfirmationDecision(approved: true)
        _ = await (cancelOp, approveOp)

        let finalState = await runTask.value
        // Either cancellation won or approval won; neither may deadlock, leak continuation, or cause crashes
        let isTerminalExpected = (finalState.phase == AgentPhase.cancelled || finalState.phase == AgentPhase.completed)
        XCTAssertTrue(isTerminalExpected)
    }

    // MARK: - 14. Request Identity Validation & Duplicate Suppression

    func testDuplicateAndStaleConfirmationDecisions() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Requesting confirmation",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Proceed?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Finished.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Duplicate confirmation test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        let activeReqId = await loop.activeConfirmationRequestId
        XCTAssertNotNil(activeReqId)

        // 1. Submit mismatched request ID -> must be ignored
        let staleId = UUID()
        await loop.submitConfirmationDecision(requestId: staleId, toolName: "system_info", approved: true)
        let phaseAfterStale = await loop.state.phase
        XCTAssertEqual(phaseAfterStale, .awaitingConfirmation)

        // 2. Submit valid request ID -> must succeed
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "system_info", approved: true)

        // 3. Submit duplicate decision immediately -> must be cleanly ignored without crash
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "system_info", approved: true)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "Finished.")
    }

    // MARK: - 15. Inference Provider Error Handling

    func testInferenceProviderThrowingErrorTransitionsToFailed() async {
        struct TestError: LocalizedError {
            var errorDescription: String? { "Simulated inference service outage" }
        }

        // Test failure during action determination
        let providerThrowingAction = MockAgentInferenceProvider(
            actionError: TestError()
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop1 = await orchestrator.createExecutionLoop(
            goal: "Error on action",
            conversationId: testConversationId,
            inferenceProvider: providerThrowingAction
        )

        let state1 = await loop1.run()
        XCTAssertEqual(state1.phase, .failed)
        XCTAssertTrue(state1.errorDescription?.contains("Simulated inference service outage") == true)

        // Test failure during observation evaluation
        let providerThrowingEval = MockAgentInferenceProvider(
            actions: [
                (thought: "Call tool", action: .callTool(toolName: "system_info", parameters: [:], thought: nil))
            ],
            evaluationError: TestError()
        )

        let loop2 = await orchestrator.createExecutionLoop(
            goal: "Error on evaluation",
            conversationId: testConversationId,
            inferenceProvider: providerThrowingEval
        )

        let state2 = await loop2.run()
        XCTAssertEqual(state2.phase, .failed)
        XCTAssertTrue(state2.errorDescription?.contains("Simulated inference service outage") == true)
    }

    // MARK: - 16. Tool Execution Timeout Handling

    func testToolExecutionTimeoutHandling() async {
        await registry.register(MockSlowTool(name: "timeout_tool", delaySeconds: 0.2))

        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Run slow tool", action: .callTool(toolName: "timeout_tool", parameters: [:], thought: nil))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Tool timed out as expected.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Timeout test",
            conversationId: testConversationId,
            inferenceProvider: provider,
            timeoutSeconds: 0.05 // 50ms timeout vs 200ms delay
        )

        let finalState = await loop.run()
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.history.count, 1)

        if case .toolTimedOut(let name, let timeoutSec) = finalState.history[0].observation {
            XCTAssertEqual(name, "timeout_tool")
            XCTAssertEqual(timeoutSec, 0.05, accuracy: 0.001)
        } else {
            XCTFail("Expected toolTimedOut observation, got \(String(describing: finalState.history.first?.observation))")
        }
    }

    // MARK: - 17. Cancellation During Active Tool Execution

    func testCancellationDuringActiveToolExecution() async {
        await registry.register(MockSlowTool(name: "cancellable_slow_tool", delaySeconds: 0.5))

        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Run slow tool", action: .callTool(toolName: "cancellable_slow_tool", parameters: [:], thought: nil))
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Cancel during execution",
            conversationId: testConversationId,
            inferenceProvider: provider,
            timeoutSeconds: 5.0
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        // Wait briefly so tool begins executing
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Cancel the loop while the tool is in-flight
        await loop.cancel()

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .cancelled)
    }

    // MARK: - 18. Invalid State Transition Rejection Without State Mutation

    func testInvalidTransitionRejectionWithoutStateMutation() {
        let state = AgentState(conversationId: testConversationId, goal: "State integrity test")
        XCTAssertEqual(state.phase, .idle)

        // Attempting an illegal transition directly via validation
        XCTAssertFalse(AgentState.isValidTransition(from: .idle, to: .executing))
        XCTAssertFalse(AgentState.isValidTransition(from: .idle, to: .evaluating))
        XCTAssertFalse(AgentState.isValidTransition(from: .idle, to: .completed))

        // State remains intact
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.errorDescription)
        XCTAssertNil(state.finalAnswer)

        // Terminal states cannot transition to anything
        let terminalPhases: [AgentPhase] = [.completed, .failed, .cancelled]
        let allPhases: [AgentPhase] = [
            .idle, .understanding, .planning, .executing,
            .awaitingConfirmation, .observing, .evaluating,
            .completed, .failed, .cancelled
        ]

        for term in terminalPhases {
            for target in allPhases {
                XCTAssertFalse(
                    AgentState.isValidTransition(from: term, to: target),
                    "Terminal phase \(term) must reject transition to \(target)"
                )
            }
        }
    }

    // MARK: - 19. Tool Identity Validation (Approval with Matching Name)

    func testConfirmationToolNameAndRequestIdAccepted() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Request permission to inspect system info.",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Allow reading system specifications?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Specs gathered with matching tool name.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Tool identity acceptance test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        let activeReqId = await loop.activeConfirmationRequestId
        let activeToolName = await loop.activeConfirmationToolName
        XCTAssertNotNil(activeReqId)
        XCTAssertEqual(activeToolName, "system_info")

        // Submit approval with matching toolName AND matching requestId
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "system_info", approved: true)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "Specs gathered with matching tool name.")
        XCTAssertEqual(finalState.history.count, 1)

        // Verify active tracking properties were cleared upon resolution
        let resolvedReqId = await loop.activeConfirmationRequestId
        let resolvedToolName = await loop.activeConfirmationToolName
        XCTAssertNil(resolvedReqId)
        XCTAssertNil(resolvedToolName)
    }

    // MARK: - 20. Tool Identity Validation (Mismatched Tool Name Rejection)

    func testConfirmationMismatchedToolNameRejected() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Request permission to inspect system info.",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Allow reading system specifications?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Completed after valid confirmation.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Mismatched tool name test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        let activeReqId = await loop.activeConfirmationRequestId
        XCTAssertNotNil(activeReqId)

        // 1. Submit approval with MISMATCHED tool name -> MUST BE REJECTED
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "malicious_unregistered_tool", approved: true)

        // Assert that the state remains paused at awaitingConfirmation
        let phaseAfterMismatched = await loop.state.phase
        XCTAssertEqual(phaseAfterMismatched, .awaitingConfirmation)
        let stillActiveReqId = await loop.activeConfirmationRequestId
        XCTAssertEqual(stillActiveReqId, activeReqId)

        // 2. Submit approval with CORRECT tool name -> MUST SUCCEED
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "system_info", approved: true)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.history.count, 1)
    }

    // MARK: - 21. Tool Identity Validation (Correct Tool Name with Stale Request ID Rejection)

    func testConfirmationCorrectToolNameWithStaleRequestIdRejected() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Request permission to inspect system info.",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Allow reading system specifications?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Completed after valid ID.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Stale request ID test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        let activeReqId = await loop.activeConfirmationRequestId
        XCTAssertNotNil(activeReqId)

        // 1. Submit approval with correct toolName but STALE/MISMATCHED requestId -> MUST BE REJECTED
        let staleReqId = UUID()
        await loop.submitConfirmationDecision(requestId: staleReqId, toolName: "system_info", approved: true)

        let phaseAfterStale = await loop.state.phase
        XCTAssertEqual(phaseAfterStale, .awaitingConfirmation)

        // 2. Submit approval with matching active requestId -> MUST SUCCEED
        await loop.submitConfirmationDecision(requestId: activeReqId, toolName: "system_info", approved: true)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
    }

    // MARK: - 22. Legacy Confirmation Overload Backward Compatibility

    func testLegacyConfirmationDecisionBackwardCompatibility() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Request permission to inspect system info.",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Allow reading system specifications?"
                 ))
            ],
            evaluations: [
                (isComplete: true, nextAction: nil, finalAnswer: "Legacy confirmation succeeded.")
            ]
        )

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Legacy compatibility test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        // Calling legacy overload when loop is idle must be safely ignored
        await loop.submitConfirmationDecision(approved: true)

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let phase = await loop.state.phase
        XCTAssertEqual(phase, .awaitingConfirmation)

        // Calling legacy overload while awaiting confirmation resumes correctly
        await loop.submitConfirmationDecision(approved: true)

        let finalState = await runTask.value
        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.finalAnswer, "Legacy confirmation succeeded.")

        // Calling legacy overload after completion must be safely ignored
        await loop.submitConfirmationDecision(approved: true)
    }

    // MARK: - 23. Pre-Cancelled Task Early Abort & Continuation Cleanup

    func testPreCancelledTaskDoesNotRetainContinuationAndAborts() async {
        let provider = MockAgentInferenceProvider(
            actions: [
                (thought: "Request permission to inspect system info.",
                 action: .requestConfirmation(
                     toolName: "system_info",
                     parameters: [:],
                     prompt: "Allow reading system specifications?"
                 ))
            ]
        )

        // Deterministically cancel the task during action determination before confirmation is awaited
        await provider.setCancelCurrentTaskOnAction(true)

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Pre-cancelled task test",
            conversationId: testConversationId,
            inferenceProvider: provider
        )

        let runTask = Task.detached { [loop] in
            await loop.run()
        }

        let finalState = await runTask.value

        // 1. Loop must reach terminal .cancelled phase
        XCTAssertEqual(finalState.phase, .cancelled)

        // 2. Active confirmation ID and tool name must be cleared
        let activeReqId = await loop.activeConfirmationRequestId
        let activeToolName = await loop.activeConfirmationToolName
        XCTAssertNil(activeReqId)
        XCTAssertNil(activeToolName)

        // 3. No tool execution must have occurred
        XCTAssertEqual(finalState.history.count, 0)

        // 4. Submitting a decision to the cancelled loop must be safely ignored
        await loop.submitConfirmationDecision(approved: true)
        let phaseAfterDecision = await loop.state.phase
        XCTAssertEqual(phaseAfterDecision, .cancelled)
    }
}
