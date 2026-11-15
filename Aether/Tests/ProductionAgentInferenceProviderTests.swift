import XCTest
@testable import Aether

// MARK: - Mock Inference Worker for Testing

internal actor TestAgentInferenceWorker: InferenceWorkerProtocol {
    private var queuedResponses: [String] = []
    private var shouldFailGenerate: Bool = false
    private var generateError: InferenceError = .decodeFailed(code: -1, description: "Simulated decode failure")
    private var delayNanoseconds: UInt64 = 0
    private var isLoaded: Bool = true
    private(set) var generatedPrompts: [String] = []

    init(responses: [String] = []) {
        self.queuedResponses = responses
    }

    func enqueueResponse(_ response: String) {
        queuedResponses.append(response)
    }

    func setShouldFailGenerate(_ fail: Bool, error: InferenceError = .decodeFailed(code: -1, description: "Simulated decode failure")) {
        self.shouldFailGenerate = fail
        self.generateError = error
    }

    func setDelayNanoseconds(_ delay: UInt64) {
        self.delayNanoseconds = delay
    }

    func initializeBackend() async throws {}

    func loadModel(at path: String, configuration: ModelConfiguration) async throws -> ModelInfo {
        isLoaded = true
        return ModelInfo(path: path, name: "TestModel", sizeInBytes: 1024, description: "Test")
    }

    func unloadModel() async throws {
        isLoaded = false
    }

    func shutdown() async {
        isLoaded = false
    }

    func isModelLoaded() async -> Bool {
        return isLoaded
    }

    func getModelChatTemplate() async -> String? {
        return nil
    }

    func countTokens(for text: String) async throws -> Int {
        if text.isEmpty { return 0 }
        return max(1, text.count / 4)
    }

    func generate(
        prompt: String,
        configuration: GenerationConfiguration,
        cancellationSignal: CancellationSignal,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws {
        generatedPrompts.append(prompt)

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        if cancellationSignal.isCancelled || Task.isCancelled {
            throw InferenceError.cancelled
        }

        if shouldFailGenerate {
            throw generateError
        }

        let response = queuedResponses.isEmpty ? "<final_answer>Default response</final_answer>" : queuedResponses.removeFirst()

        // Yield in chunks to simulate streaming
        let chunkSize = max(1, response.count / 3)
        var idx = response.startIndex
        while idx < response.endIndex {
            if cancellationSignal.isCancelled || Task.isCancelled {
                throw InferenceError.cancelled
            }
            let nextIdx = response.index(idx, offsetBy: chunkSize, limitedBy: response.endIndex) ?? response.endIndex
            let piece = String(response[idx..<nextIdx])
            onToken(piece)
            idx = nextIdx
        }
    }
}

// MARK: - Test Suite

final class ProductionAgentInferenceProviderTests: XCTestCase {

    private var registry: ToolRegistry!
    private var securityGuard: ToolSecurityGuard!
    private var testWorker: TestAgentInferenceWorker!
    private var inferenceService: InferenceService!
    private var tempModelPath: String!

    override func setUp() async throws {
        try await super.setUp()
        self.securityGuard = ToolSecurityGuard()
        self.registry = ToolRegistry(securityGuard: securityGuard)
        await registry.register(SystemInfoTool())
        await registry.register(SafeCalculatorTool())

        self.testWorker = TestAgentInferenceWorker()
        self.inferenceService = InferenceService(worker: testWorker)

        // Create temporary mock GGUF file so file-existence validation passes
        self.tempModelPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("test-model-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempModelPath, contents: Data("test".utf8))

        // Put inference service into loaded state
        _ = try await inferenceService.loadModel(
            at: tempModelPath,
            configuration: ModelConfiguration()
        )
    }

    override func tearDown() async throws {
        await inferenceService.shutdown()
        if let path = tempModelPath {
            try? FileManager.default.removeItem(atPath: path)
            tempModelPath = nil
        }
        self.inferenceService = nil
        self.testWorker = nil
        self.registry = nil
        self.securityGuard = nil
        try await super.tearDown()
    }

    // MARK: - 1. Prompt Construction Tests

    func testPromptConstructionIncludesToolsAndGoal() async {
        let tools = await registry.definitions
        let provider = ProductionAgentInferenceProvider(
            inferenceService: inferenceService,
            baseSystemPrompt: "Custom test assistant."
        )

        let state = AgentState(
            conversationId: UUID(),
            goal: "Check the hardware specifications."
        )

        let messages = await provider.buildPromptMessages(state: state, availableTools: tools)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertTrue(messages[0].content.contains("Custom test assistant."))
        XCTAssertTrue(messages[0].content.contains("system_info"))
        XCTAssertTrue(messages[0].content.contains("calculator"))

        XCTAssertEqual(messages[1].role, "user")
        XCTAssertEqual(messages[1].content, "Check the hardware specifications.")
    }

    func testPromptConstructionWithEmptyTools() async {
        let provider = ProductionAgentInferenceProvider(inferenceService: inferenceService)
        let state = AgentState(conversationId: UUID(), goal: "Simple question")

        let messages = await provider.buildPromptMessages(state: state, availableTools: [])

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].content.contains("(No tools currently available.)"))
    }

    func testPromptConstructionWithInjectedGuidance() async {
        let provider = ProductionAgentInferenceProvider(inferenceService: inferenceService)
        let state = AgentState(conversationId: UUID(), goal: "Repeat action test")

        let guidance = "[SYSTEM GUIDANCE: REPETITION DETECTED] Stop repeating."
        let messages = await provider.buildPromptMessages(
            state: state,
            availableTools: [],
            injectedGuidance: guidance
        )

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[2].role, "user")
        XCTAssertEqual(messages[2].content, guidance)
    }

    // MARK: - 2. Historical Step Serialization Tests

    func testHistoricalStepSerializationInterleavesAssistantAndUserObservations() async {
        let provider = ProductionAgentInferenceProvider(inferenceService: inferenceService)

        var state = AgentState(conversationId: UUID(), goal: "Multi-turn task")
        let step1 = AgentStepRecord(
            stepIndex: 0,
            phase: .observing,
            thought: "I will call system_info",
            action: .callTool(toolName: "system_info", parameters: [:], thought: "I will call system_info"),
            observation: .toolSuccess(toolName: "system_info", output: "macOS 14.5", durationSeconds: 0.05)
        )
        let step2 = AgentStepRecord(
            stepIndex: 1,
            phase: .observing,
            thought: "Now compute something",
            action: .callTool(toolName: "calculator", parameters: ["expression": "40 + 2"], thought: "Now compute something"),
            observation: .toolSuccess(toolName: "calculator", output: "42", durationSeconds: 0.01)
        )
        state.history = [step1, step2]

        let messages = await provider.buildPromptMessages(state: state, availableTools: [])

        // Expect: system (0), goal user (1), step1 assistant (2), step1 obs user (3), step2 assistant (4), step2 obs user (5)
        XCTAssertEqual(messages.count, 6)

        XCTAssertEqual(messages[2].role, "assistant")
        XCTAssertTrue(messages[2].content.contains("<thought>\nI will call system_info\n</thought>"))
        XCTAssertTrue(messages[2].content.contains("<name>system_info</name>"))

        XCTAssertEqual(messages[3].role, "user")
        XCTAssertTrue(messages[3].content.contains("<tool_response name=\"system_info\" status=\"success\">"))
        XCTAssertTrue(messages[3].content.contains("macOS 14.5"))

        XCTAssertEqual(messages[4].role, "assistant")
        XCTAssertTrue(messages[4].content.contains("<name>calculator</name>"))
        XCTAssertTrue(messages[4].content.contains("<expression>40 + 2</expression>"))

        XCTAssertEqual(messages[5].role, "user")
        XCTAssertTrue(messages[5].content.contains("42"))
    }

    func testHistoricalStepSerializationWithConfirmationAndFailure() async {
        let provider = ProductionAgentInferenceProvider(inferenceService: inferenceService)

        var state = AgentState(conversationId: UUID(), goal: "Confirmation test")
        let step1 = AgentStepRecord(
            stepIndex: 0,
            phase: .observing,
            thought: "Request permission",
            action: .requestConfirmation(toolName: "delete_file", parameters: ["path": "/tmp/a.txt"], prompt: "Delete file?"),
            observation: .confirmationDecision(toolName: "delete_file", approved: false)
        )
        let step2 = AgentStepRecord(
            stepIndex: 1,
            phase: .observing,
            thought: "Tool failure step",
            action: .callTool(toolName: "network_fetch", parameters: ["url": "invalid"], thought: "Tool failure step"),
            observation: .toolFailure(toolName: "network_fetch", error: "Host unreachable", durationSeconds: 0.1)
        )
        state.history = [step1, step2]

        let messages = await provider.buildPromptMessages(state: state, availableTools: [])

        XCTAssertEqual(messages.count, 6)
        XCTAssertTrue(messages[2].content.contains("<confirm_tool>"))
        XCTAssertTrue(messages[2].content.contains("<prompt>Delete file?</prompt>"))

        XCTAssertTrue(messages[3].content.contains("rejected"))

        XCTAssertTrue(messages[4].content.contains("<name>network_fetch</name>"))
        XCTAssertTrue(messages[5].content.contains("Error: Host unreachable"))
    }

    // MARK: - 3. Context Budgeting Integration

    func testContextBudgeterPrunesOldestTurnsWhilePreservingSystemAndGoal() async throws {
        // Construct a long conversation
        var messages: [PromptMessage] = [
            PromptMessage(role: "system", content: "Permanent system instructions"),
            PromptMessage(role: "user", content: "Original goal")
        ]

        for i in 1...10 {
            messages.append(PromptMessage(role: "assistant", content: "Historical reasoning step \(i) with verbose content..."))
            messages.append(PromptMessage(role: "user", content: "Historical tool observation output \(i)..."))
        }

        // Budget with small context length
        let result = try await ContextBudgeter.budget(
            messages: messages,
            contextLength: 200,
            maxTokens: 50,
            safetyMargin: 10,
            tokenizer: { text in max(1, text.count / 4) }
        )

        XCTAssertTrue(result.didPrune)
        XCTAssertTrue(result.budgetedMessages.count < messages.count)
        // System message at index 0 must be preserved
        XCTAssertEqual(result.budgetedMessages.first?.role, "system")
        XCTAssertEqual(result.budgetedMessages.first?.content, "Permanent system instructions")
        // Most recent message must be preserved
        XCTAssertEqual(result.budgetedMessages.last?.content, messages.last?.content)
    }

    // MARK: - 4. Tag Parsing Tests

    func testStandardToolCallParsingWithParameters() {
        let raw = """
        <thought>
        Let me calculate the square root of 144.
        </thought>
        <tool_call>
        <name>calculator</name>
        <parameters>
        <expression>12 * 12</expression>
        </parameters>
        </tool_call>
        """

        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)

        XCTAssertEqual(thought, "Let me calculate the square root of 144.")
        if case .callTool(let name, let params, let t) = action {
            XCTAssertEqual(name, "calculator")
            XCTAssertEqual(params["expression"], "12 * 12")
            XCTAssertEqual(t, thought)
        } else {
            XCTFail("Expected .callTool, got \(action)")
        }
    }

    func testFinalAnswerParsing() {
        let raw = """
        <thought>
        I have all necessary details now.
        </thought>
        <final_answer>
        The CPU has 10 cores and 32GB of unified memory.
        </final_answer>
        """

        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)

        XCTAssertEqual(thought, "I have all necessary details now.")
        XCTAssertEqual(action, .declareComplete(finalAnswer: "The CPU has 10 cores and 32GB of unified memory."))
    }

    func testConfirmToolParsing() {
        let raw = """
        <thought>
        Removing this directory is destructive.
        </thought>
        <confirm_tool>
        <name>file_system</name>
        <parameters>
        <action>delete</action>
        <path>/tmp/scratch</path>
        </parameters>
        <prompt>Do you want to permanently remove /tmp/scratch?</prompt>
        </confirm_tool>
        """

        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)

        XCTAssertEqual(thought, "Removing this directory is destructive.")
        if case .requestConfirmation(let name, let params, let prompt) = action {
            XCTAssertEqual(name, "file_system")
            XCTAssertEqual(params["action"], "delete")
            XCTAssertEqual(params["path"], "/tmp/scratch")
            XCTAssertEqual(prompt, "Do you want to permanently remove /tmp/scratch?")
        } else {
            XCTFail("Expected .requestConfirmation, got \(action)")
        }
    }

    func testActionTagUnwrapping() {
        let raw = """
        <action>
        <final_answer>Nested final answer inside action tag.</final_answer>
        </action>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)
        XCTAssertEqual(action, .declareComplete(finalAnswer: "Nested final answer inside action tag."))
    }

    func testJSONToolCallFallback() {
        let raw = """
        ```json
        {
          "name": "system_info",
          "parameters": {
            "verbose": "true"
          }
        }
        ```
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)
        if case .callTool(let name, let params, _) = action {
            XCTAssertEqual(name, "system_info")
            XCTAssertEqual(params["verbose"], "true")
        } else {
            XCTFail("Expected .callTool, got \(action)")
        }
    }

    // MARK: - 5. Malformed Output Recovery Tests

    func testEmptyOutputYieldsFailure() {
        let raw = "   \n\t  "
        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)
        if case .declareFailure(let reason) = action {
            XCTAssertTrue(reason.contains("empty"))
        } else {
            XCTFail("Expected .declareFailure on empty text, got \(action)")
        }
    }

    func testPlainTextWithoutTagsYieldsFinalAnswer() {
        let raw = "The capital of France is Paris."
        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)
        XCTAssertNil(thought)
        XCTAssertEqual(action, .declareComplete(finalAnswer: "The capital of France is Paris."))
    }

    func testThoughtOnlyYieldsFinalAnswerFromThought() {
        let raw = """
        <thought>
        The user simply said hello, so I will greet them warmly.
        </thought>
        """
        let (thought, action) = ProductionAgentInferenceProvider.parseModelOutput(from: raw)
        XCTAssertEqual(thought, "The user simply said hello, so I will greet them warmly.")
        XCTAssertEqual(action, .declareComplete(finalAnswer: "The user simply said hello, so I will greet them warmly."))
    }

    // MARK: - 6. AgentCyclicController Tests

    func testDuplicateActionDetectionIdenticalConsecutive() {
        let controller = AgentCyclicController()

        let action = AgentAction.callTool(toolName: "search", parameters: ["q": "swift"], thought: nil)
        let step1 = AgentStepRecord(stepIndex: 0, phase: .observing, action: action)
        let step2 = AgentStepRecord(stepIndex: 1, phase: .observing, action: action)

        // 2 identical consecutive actions -> Guidance
        let decision2 = controller.evaluatePolicy(history: [step1, step2])
        if case .injectGuidance(let g, let res) = decision2 {
            XCTAssertTrue(g.contains("REPETITION DETECTED"))
            XCTAssertEqual(res, .consecutiveIdenticalActions(action: action, count: 2))
        } else {
            XCTFail("Expected .injectGuidance, got \(decision2)")
        }

        // 3 identical consecutive actions -> Abort
        let step3 = AgentStepRecord(stepIndex: 2, phase: .observing, action: action)
        let decision3 = controller.evaluatePolicy(history: [step1, step2, step3])
        if case .abort(let reason, _) = decision3 {
            XCTAssertTrue(reason.contains("identical search 3 times"))
        } else {
            XCTFail("Expected .abort, got \(decision3)")
        }
    }

    func testParameterEquivalenceWithWhitespaceAndOrder() {
        let controller = AgentCyclicController()

        let p1 = ["query": "  apple silicon  ", "limit": "10"]
        let p2 = ["limit": "10", "query": "apple silicon"]

        XCTAssertTrue(controller.areParametersEquivalent(p1, p2))

        let a1 = AgentAction.callTool(toolName: "search", parameters: p1, thought: "t1")
        let a2 = AgentAction.callTool(toolName: "search", parameters: p2, thought: "t2")

        XCTAssertTrue(controller.areActionsEquivalent(a1, a2))
    }

    func testParameterEquivalenceWithJSON() {
        let controller = AgentCyclicController()

        let j1 = """
        {"name": "test", "val": 1}
        """
        let j2 = """
        { "val": 1, "name": "test" }
        """

        XCTAssertTrue(controller.areParametersEquivalent(["body": j1], ["body": j2]))
    }

    func testRepeatedToolFailureDetection() {
        let controller = AgentCyclicController()

        let step1 = AgentStepRecord(
            stepIndex: 0,
            phase: .observing,
            observation: .toolFailure(toolName: "web_fetch", error: "404 Not Found", durationSeconds: 0.1)
        )
        let step2 = AgentStepRecord(
            stepIndex: 1,
            phase: .observing,
            observation: .toolFailure(toolName: "web_fetch", error: "404 Not Found", durationSeconds: 0.1)
        )

        // 2 failures -> Guidance
        let decision2 = controller.evaluatePolicy(history: [step1, step2])
        if case .injectGuidance(let g, _) = decision2 {
            XCTAssertTrue(g.contains("REPEATED TOOL FAILURE"))
            XCTAssertTrue(g.contains("web_fetch"))
        } else {
            XCTFail("Expected .injectGuidance on 2 failures, got \(decision2)")
        }

        // 3 failures -> Abort
        let step3 = AgentStepRecord(
            stepIndex: 2,
            phase: .observing,
            observation: .toolFailure(toolName: "web_fetch", error: "500 Server Error", durationSeconds: 0.1)
        )
        let decision3 = controller.evaluatePolicy(history: [step1, step2, step3])
        if case .abort(let r, _) = decision3 {
            XCTAssertTrue(r.contains("web_fetch"))
            XCTAssertTrue(r.contains("3 consecutive times"))
        } else {
            XCTFail("Expected .abort on 3 failures, got \(decision3)")
        }
    }

    func testToolSuccessBreaksFailureChain() {
        let controller = AgentCyclicController()

        let step1 = AgentStepRecord(stepIndex: 0, phase: .observing, observation: .toolFailure(toolName: "t", error: "e", durationSeconds: 0.1))
        let step2 = AgentStepRecord(stepIndex: 1, phase: .observing, observation: .toolSuccess(toolName: "t", output: "ok", durationSeconds: 0.1))
        let step3 = AgentStepRecord(stepIndex: 2, phase: .observing, observation: .toolFailure(toolName: "t", error: "e", durationSeconds: 0.1))

        let decision = controller.evaluatePolicy(history: [step1, step2, step3])
        XCTAssertEqual(decision, .allow)
    }

    func testOscillatingPatternDetection() {
        let controller = AgentCyclicController()

        let actionA = AgentAction.callTool(toolName: "tool_a", parameters: [:], thought: nil)
        let actionB = AgentAction.callTool(toolName: "tool_b", parameters: [:], thought: nil)

        let step1 = AgentStepRecord(stepIndex: 0, phase: .observing, action: actionA)
        let step2 = AgentStepRecord(stepIndex: 1, phase: .observing, action: actionB)
        let step3 = AgentStepRecord(stepIndex: 2, phase: .observing, action: actionA)
        let step4 = AgentStepRecord(stepIndex: 3, phase: .observing, action: actionB)

        // 2 cycles (A -> B -> A -> B) -> Guidance
        let decision2 = controller.evaluatePolicy(history: [step1, step2, step3, step4])
        if case .injectGuidance(let g, _) = decision2 {
            XCTAssertTrue(g.contains("OSCILLATION DETECTED"))
        } else {
            XCTFail("Expected .injectGuidance for oscillation, got \(decision2)")
        }

        // 3 cycles (A -> B -> A -> B -> A -> B) -> Abort
        let step5 = AgentStepRecord(stepIndex: 4, phase: .observing, action: actionA)
        let step6 = AgentStepRecord(stepIndex: 5, phase: .observing, action: actionB)
        let decision3 = controller.evaluatePolicy(history: [step1, step2, step3, step4, step5, step6])
        if case .abort(let r, _) = decision3 {
            XCTAssertTrue(r.contains("Oscillating loop detected"))
        } else {
            XCTFail("Expected .abort for 3 oscillation cycles, got \(decision3)")
        }
    }

    func testThoughtStagnationDetection() {
        let controller = AgentCyclicController()

        let stagnantThought = "I am pondering what to do next."
        let step1 = AgentStepRecord(stepIndex: 0, phase: .observing, thought: stagnantThought)
        let step2 = AgentStepRecord(stepIndex: 1, phase: .observing, thought: stagnantThought)
        let step3 = AgentStepRecord(stepIndex: 2, phase: .observing, thought: stagnantThought)

        let decision = controller.evaluatePolicy(history: [step1, step2, step3])
        if case .injectGuidance(let g, _) = decision {
            XCTAssertTrue(g.contains("REASONING STAGNATION"))
        } else {
            XCTFail("Expected .injectGuidance for stagnation, got \(decision)")
        }
    }

    // MARK: - 7. Observation Evaluation Tests

    func testDefaultObservationEvaluationReturnsIncomplete() async throws {
        let provider = ProductionAgentInferenceProvider(inferenceService: inferenceService)
        let state = AgentState(conversationId: UUID(), goal: "Test goal")
        let obs = AgentObservation.toolSuccess(toolName: "system_info", output: "macOS", durationSeconds: 0.01)

        let result = try await provider.evaluateObservation(state: state, observation: obs)

        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.nextAction)
        XCTAssertNil(result.finalAnswer)
    }

    func testObservationEvaluationWithRepeatedFailuresTriggersTermination() async throws {
        let provider = ProductionAgentInferenceProvider(inferenceService: inferenceService)

        var state = AgentState(conversationId: UUID(), goal: "Failing goal")
        let failureObs = AgentObservation.toolFailure(toolName: "broken_tool", error: "Fatal error", durationSeconds: 0.1)
        state.history = [
            AgentStepRecord(stepIndex: 0, phase: .observing, observation: failureObs),
            AgentStepRecord(stepIndex: 1, phase: .observing, observation: failureObs),
            AgentStepRecord(stepIndex: 2, phase: .observing, observation: failureObs)
        ]

        let result = try await provider.evaluateObservation(state: state, observation: failureObs)

        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.finalAnswer?.contains("Task stopped due to unrecoverable tool failures") == true)
    }

    func testCustomObservationEvaluatorIntegration() async throws {
        let customEvaluator: ProductionAgentInferenceProvider.ObservationEvaluator = { state, obs in
            if obs.summary.contains("MAGIC_VALUE") {
                return (isComplete: true, nextAction: nil, finalAnswer: "Found magic value!")
            }
            return (isComplete: false, nextAction: nil, finalAnswer: nil)
        }

        let provider = ProductionAgentInferenceProvider(
            inferenceService: inferenceService,
            customEvaluator: customEvaluator
        )

        let state = AgentState(conversationId: UUID(), goal: "Find magic")
        let obs = AgentObservation.info("MAGIC_VALUE was located.")

        let result = try await provider.evaluateObservation(state: state, observation: obs)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.finalAnswer, "Found magic value!")
    }

    // MARK: - 8. End-to-End Multi-Step Reasoning with Mock Model

    func testMultiStepReasoningWithMockModel() async {
        // Enqueue 2 responses:
        // Turn 1: tool call
        await testWorker.enqueueResponse("""
        <thought>
        Query system info to inspect architecture.
        </thought>
        <tool_call>
        <name>system_info</name>
        <parameters>
        </parameters>
        </tool_call>
        """)

        // Turn 2: final answer after observing output
        await testWorker.enqueueResponse("""
        <thought>
        Information gathered successfully.
        </thought>
        <final_answer>
        The system is running macOS natively on Apple Silicon.
        </final_answer>
        """)

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard, maxSteps: 5)
        let finalState = await orchestrator.runProductionLoop(
            goal: "What platform is Aether running on?",
            conversationId: UUID(),
            inferenceService: inferenceService
        )

        XCTAssertEqual(finalState.phase, .completed)
        XCTAssertEqual(finalState.stepIndex, 2)
        XCTAssertEqual(finalState.finalAnswer, "The system is running macOS natively on Apple Silicon.")
        XCTAssertEqual(finalState.history.count, 2) // 1 tool step + 1 completion step
    }

    // MARK: - 9. Cooperative Cancellation Tests

    func testCooperativeCancellationAbortsInference() async {
        await testWorker.setDelayNanoseconds(100_000_000) // 100ms delay

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let loop = await orchestrator.createProductionLoop(
            goal: "Slow reasoning task",
            conversationId: UUID(),
            inferenceService: inferenceService
        )

        let task = Task {
            await loop.run()
        }

        // Cancel almost immediately
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        await loop.cancel()

        let state = await task.value
        XCTAssertEqual(state.phase, .cancelled)
    }

    // MARK: - 10. Inference Error Handling Tests

    func testInferenceErrorPropagatesToFailedState() async {
        await testWorker.setShouldFailGenerate(true, error: .decodeFailed(code: -1, description: "Out of compute budget"))

        let orchestrator = AgentOrchestrator(registry: registry, securityGuard: securityGuard)
        let state = await orchestrator.runProductionLoop(
            goal: "Will fail task",
            conversationId: UUID(),
            inferenceService: inferenceService
        )

        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.errorDescription?.contains("Out of compute budget") == true)
    }

    // MARK: - 11. AgentOrchestrator Integration Tests

    func testAgentOrchestratorParseAction() {
        let text = "<thought>Calculating</thought><final_answer>Result is 100</final_answer>"
        let (thought, action) = AgentOrchestrator.parseAction(from: text)

        XCTAssertEqual(thought, "Calculating")
        XCTAssertEqual(action, .declareComplete(finalAnswer: "Result is 100"))
    }
}
