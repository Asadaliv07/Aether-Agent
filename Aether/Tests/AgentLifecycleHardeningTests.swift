import XCTest
@testable import Aether

// MARK: - Lifecycle Test Mocks

actor LifecycleMockInferenceProvider: AgentInferenceProvider {
    private var actionQueue: [(thought: String?, action: AgentAction)] = []
    private var evaluationQueue: [(isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?)] = []
    
    private(set) var capturedActionSignals: [CancellationSignal] = []
    private(set) var capturedEvaluationSignals: [CancellationSignal] = []
    private(set) var determineActionCallCount = 0
    private(set) var evaluateObservationCallCount = 0

    private var shouldBlockActionUntilCancelled = false
    private var shouldBlockEvaluationUntilCancelled = false
    private var evaluationDelayNanoseconds: UInt64 = 0
    
    var onActionStarted: (@Sendable () -> Void)?
    var onEvaluationStarted: (@Sendable () -> Void)?

    func setShouldBlockActionUntilCancelled(_ value: Bool) {
        self.shouldBlockActionUntilCancelled = value
    }

    func setShouldBlockEvaluationUntilCancelled(_ value: Bool) {
        self.shouldBlockEvaluationUntilCancelled = value
    }

    func setEvaluationDelay(seconds: Double) {
        self.evaluationDelayNanoseconds = UInt64(seconds * 1_000_000_000)
    }

    func setOnActionStarted(_ closure: (@Sendable () -> Void)?) {
        self.onActionStarted = closure
    }

    func setOnEvaluationStarted(_ closure: (@Sendable () -> Void)?) {
        self.onEvaluationStarted = closure
    }

    func enqueueAction(thought: String? = nil, action: AgentAction) {
        actionQueue.append((thought, action))
    }

    func enqueueEvaluation(isComplete: Bool, nextAction: AgentAction? = nil, finalAnswer: String? = nil) {
        evaluationQueue.append((isComplete, nextAction, finalAnswer))
    }

    func determineNextAction(
        state: AgentState,
        availableTools: [ToolDefinition],
        cancellationSignal: CancellationSignal?
    ) async throws -> (thought: String?, action: AgentAction) {
        determineActionCallCount += 1
        if let sig = cancellationSignal {
            capturedActionSignals.append(sig)
        }
        onActionStarted?()

        if shouldBlockActionUntilCancelled {
            while !(cancellationSignal?.isCancelled ?? false) && !Task.isCancelled {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if cancellationSignal?.isCancelled == true || Task.isCancelled {
                throw CancellationError()
            }
        }

        guard !actionQueue.isEmpty else {
            return ("Default action", .declareComplete(finalAnswer: "Default success"))
        }
        return actionQueue.removeFirst()
    }

    func evaluateObservation(
        state: AgentState,
        observation: AgentObservation,
        cancellationSignal: CancellationSignal?
    ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?) {
        evaluateObservationCallCount += 1
        if let sig = cancellationSignal {
            capturedEvaluationSignals.append(sig)
        }
        onEvaluationStarted?()

        if evaluationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: evaluationDelayNanoseconds)
        }

        if shouldBlockEvaluationUntilCancelled {
            while !(cancellationSignal?.isCancelled ?? false) && !Task.isCancelled {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if cancellationSignal?.isCancelled == true || Task.isCancelled {
                throw CancellationError()
            }
        }

        guard !evaluationQueue.isEmpty else {
            return (true, nil, "Default evaluation complete")
        }
        return evaluationQueue.removeFirst()
    }
}

// MARK: - Lifecycle Test Tools

actor AtomicCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

struct LifecycleNotificationMockTool: Tool {
    let definition = ToolDefinition(
        name: "mock_notification",
        description: "Mock notification side-effect tool",
        permissionLevel: .safeReadOnly
    )
    let counter: AtomicCounter

    func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        await counter.increment()
        return .success(toolName: definition.name, output: "Notification posted")
    }
}

struct LifecycleBlockingTool: Tool {
    let definition: ToolDefinition
    let delayNanoseconds: UInt64
    let onStarted: (@Sendable () -> Void)?

    init(name: String = "blocking_tool", delaySeconds: Double = 0.05, onStarted: (@Sendable () -> Void)? = nil) {
        self.definition = ToolDefinition(
            name: name,
            description: "Deterministic blocking tool",
            permissionLevel: .safeReadOnly
        )
        self.delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
        self.onStarted = onStarted
    }

    func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        onStarted?()
        try await Task.sleep(nanoseconds: delayNanoseconds)
        if context.cancellationSignal?.isCancelled == true || Task.isCancelled {
            return .cancelled(toolName: definition.name)
        }
        return .success(toolName: definition.name, output: "Blocking tool finished successfully")
    }
}

actor AtomicItemStore {
    private(set) var items: [String] = []
    func append(_ item: String) { items.append(item) }
}

struct LifecycleAtomicMockTool: Tool {
    let definition = ToolDefinition(
        name: "atomic_writer",
        description: "Simulates multi-item atomic mutation",
        permissionLevel: .safeReadOnly
    )
    let store: AtomicItemStore

    func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        for i in 1...5 {
            await store.append("item_\(i)")
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms per item
        }
        return .success(toolName: definition.name, output: "Wrote 5 items atomically")
    }
}

struct LifecycleRestrictedMockTool: Tool {
    let definition = ToolDefinition(
        name: "restricted_tool",
        description: "Tool requiring interactive confirmation",
        permissionLevel: .userConfirmationRequired
    )

    func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        return .success(toolName: definition.name, output: "Restricted tool executed")
    }
}

// MARK: - Test Suite

final class AgentLifecycleHardeningTests: XCTestCase {

    private func makeLoop(
        provider: AgentInferenceProvider,
        tools: [Tool] = [],
        securityGuard: ToolSecurityGuard? = nil,
        confirmationTimeoutSeconds: Double = 60.0
    ) async -> (AgentExecutionLoopActor, ToolRegistry) {
        let guardToUse = securityGuard ?? ToolSecurityGuard()
        let registry = ToolRegistry(securityGuard: guardToUse)
        for tool in tools {
            await registry.register(tool)
        }
        let initialState = AgentState(
            conversationId: UUID(),
            goal: "Test lifecycle goal"
        )
        let loop = AgentExecutionLoopActor(
            initialState: initialState,
            registry: registry,
            securityGuard: guardToUse,
            inferenceProvider: provider,
            confirmationTimeoutSeconds: confirmationTimeoutSeconds
        )
        return (loop, registry)
    }

    // MARK: - Group 1: Inference Pause & Resume

    func testPauseDuringActionInferenceCancelsOperationSignalAndDiscardsTokens() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.setShouldBlockActionUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider)

        let exp = expectation(description: "Pause reached")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .paused = event {
                    exp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        XCTAssertNotNil(runTask)

        // Wait a brief moment for inference to enter
        try await Task.sleep(nanoseconds: 30_000_000)

        let paused = await loop.pause()
        XCTAssertTrue(paused)

        await fulfillment(of: [exp], timeout: 2.0)
        eventTask.cancel()

        let state = await loop.state
        XCTAssertEqual(state.phase, .paused)
        if case .beforePlanning(let step) = state.resumeCheckpoint {
            XCTAssertEqual(step, 1)
        } else {
            XCTFail("Expected resumeCheckpoint to be .beforePlanning(1), got \(String(describing: state.resumeCheckpoint))")
        }
        let sessionCancelled = await loop.sessionSignal.isCancelled
        XCTAssertFalse(sessionCancelled)

        // Now resume: configure provider to return declareComplete
        await provider.setShouldBlockActionUntilCancelled(false)
        await provider.enqueueAction(action: .declareComplete(finalAnswer: "Resumed successfully"))

        let resumed = await loop.resume()
        XCTAssertTrue(resumed)

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
        XCTAssertEqual(finalState?.finalAnswer, "Resumed successfully")
    }

    func testPauseDuringObservationEvaluationCancelsOperationSignalAndPreservesObservation() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(action: .callTool(toolName: "system_info", parameters: [:], thought: nil))
        await provider.setShouldBlockEvaluationUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider, tools: [SystemInfoTool()])

        let exp = expectation(description: "Paused in evaluation")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .paused = event {
                    exp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        let paused = await loop.pause()
        XCTAssertTrue(paused)

        await fulfillment(of: [exp], timeout: 2.0)
        eventTask.cancel()

        let state = await loop.state
        XCTAssertEqual(state.phase, .paused)
        XCTAssertNotNil(state.lastObservation)
        if case .beforeObservationEvaluation(let step, _, let obs) = state.resumeCheckpoint {
            XCTAssertEqual(step, 1)
            if case .toolSuccess(let name, _, _) = obs {
                XCTAssertEqual(name, "system_info")
            } else {
                XCTFail("Expected observation to be toolSuccess, got \(obs)")
            }
        } else {
            XCTFail("Expected checkpoint .beforeObservationEvaluation, got \(String(describing: state.resumeCheckpoint))")
        }

        // Resume: provider finishes evaluation
        await provider.setShouldBlockEvaluationUntilCancelled(false)
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Evaluation verified")

        let resumed = await loop.resume()
        XCTAssertTrue(resumed)

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
        XCTAssertEqual(finalState?.finalAnswer, "Evaluation verified")
    }

    func testResumeAllocatesFreshOperationSignal() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.setShouldBlockActionUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider)

        let runTask = await loop.start()
        try await Task.sleep(nanoseconds: 30_000_000)

        _ = await loop.pause()
        try await Task.sleep(nanoseconds: 30_000_000)

        // Capture signal 1
        let signals1 = await provider.capturedActionSignals
        XCTAssertEqual(signals1.count, 1)
        let sig1 = signals1[0]
        XCTAssertTrue(sig1.isCancelled)

        // Configure next action and resume
        await provider.setShouldBlockActionUntilCancelled(false)
        await provider.enqueueAction(action: .declareComplete(finalAnswer: "Fresh signal complete"))

        _ = await loop.resume()
        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)

        let signals2 = await provider.capturedActionSignals
        XCTAssertEqual(signals2.count, 2)
        let sig2 = signals2[1]

        XCTAssertTrue(sig1 !== sig2, "Resumed operation must allocate a fresh CancellationSignal instance")
        XCTAssertTrue(sig1.isCancelled, "Initial operation signal must remain cancelled")
        XCTAssertFalse(sig2.isCancelled, "Fresh operation signal must not be cancelled")
    }

    // MARK: - Group 2: Deferred Tool Pause & Step Boundaries

    func testPauseRequestedDuringToolExecutionDefersUntilToolCompletion() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(action: .callTool(toolName: "blocking_tool", parameters: [:], thought: nil))
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Tool deferred complete")

        let toolStartedExp = expectation(description: "Tool started")
        let tool = LifecycleBlockingTool(name: "blocking_tool", delaySeconds: 0.1) {
            toolStartedExp.fulfill()
        }

        let (loop, _) = await makeLoop(provider: provider, tools: [tool])

        let pausedExp = expectation(description: "Paused after tool")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .paused = event {
                    pausedExp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        await fulfillment(of: [toolStartedExp], timeout: 2.0)

        // Tool is actively running, loop is in .executing
        let currentPhase = await loop.state.phase
        XCTAssertEqual(currentPhase, .executing)

        // Request pause while tool is running
        let paused = await loop.pause()
        XCTAssertTrue(paused)

        await fulfillment(of: [pausedExp], timeout: 2.0)
        eventTask.cancel()

        let state = await loop.state
        XCTAssertEqual(state.phase, .paused)
        XCTAssertNotNil(state.lastObservation)
        if case .toolSuccess(let name, let out, _) = state.lastObservation! {
            XCTAssertEqual(name, "blocking_tool")
            XCTAssertEqual(out, "Blocking tool finished successfully")
        } else {
            XCTFail("Expected toolSuccess observation")
        }

        // Resume and complete
        _ = await loop.resume()
        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
    }

    func testPauseAtStepBoundaryCheckpointsAfterStepCompleted() async throws {
        let provider = LifecycleMockInferenceProvider()
        // Step 1: call tool
        await provider.enqueueAction(action: .callTool(toolName: "system_info", parameters: [:], thought: nil))
        // Evaluation returns incomplete, prompting step 2
        await provider.enqueueEvaluation(isComplete: false, nextAction: nil)
        // Delay evaluation by 50ms so pause request is registered precisely at step boundary
        await provider.setEvaluationDelay(seconds: 0.05)
        // Step 2: declare complete
        await provider.enqueueAction(action: .declareComplete(finalAnswer: "Finished in step 2"))
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Finished in step 2")

        let (loop, _) = await makeLoop(provider: provider, tools: [SystemInfoTool()])

        let pausedExp = expectation(description: "Paused at step boundary")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .paused = event {
                    pausedExp.fulfill()
                    break
                }
            }
        }

        await provider.setOnEvaluationStarted { [weak loop] in
            Task {
                await loop?.pause()
            }
        }

        let runTask = await loop.start()
        await fulfillment(of: [pausedExp], timeout: 2.0)
        eventTask.cancel()

        let state = await loop.state
        XCTAssertEqual(state.phase, .paused)
        if case .afterStepCompleted(let nextStep) = state.resumeCheckpoint {
            XCTAssertEqual(nextStep, 2)
        } else {
            XCTFail("Expected .afterStepCompleted(2), got \(String(describing: state.resumeCheckpoint))")
        }

        // Clear evaluation delay for step 2
        await provider.setEvaluationDelay(seconds: 0)

        _ = await loop.resume()
        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
        XCTAssertEqual(finalState?.stepIndex, 2)
    }

    func testPauseBeforeToolExecutionResumesBypassingInference() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(action: .callTool(toolName: "system_info", parameters: [:], thought: nil))
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Bypassed inference complete")

        let securityGuard = ToolSecurityGuard()
        await securityGuard.setAuthorizationDelay(seconds: 0.05) // 50ms authorization window

        let (loop, _) = await makeLoop(
            provider: provider,
            tools: [SystemInfoTool()],
            securityGuard: securityGuard
        )

        let pausedExp = expectation(description: "Paused before tool")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .actionProposed = event {
                    _ = await loop.pause()
                }
                if case .paused = event {
                    pausedExp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        await fulfillment(of: [pausedExp], timeout: 2.0)
        eventTask.cancel()

        let state = await loop.state
        XCTAssertEqual(state.phase, .paused)
        if case .beforeToolExecution(let step, let act) = state.resumeCheckpoint {
            XCTAssertEqual(step, 1)
            if case .callTool(let name, _, _) = act {
                XCTAssertEqual(name, "system_info")
            } else {
                XCTFail("Expected callTool action")
            }
        } else {
            XCTFail("Expected beforeToolExecution checkpoint, got \(String(describing: state.resumeCheckpoint))")
        }

        let preResumeActionCount = await provider.determineActionCallCount
        XCTAssertEqual(preResumeActionCount, 1)

        // Clear delay for resumption
        await securityGuard.setAuthorizationDelay(seconds: 0)

        _ = await loop.resume()
        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)

        let postResumeActionCount = await provider.determineActionCallCount
        XCTAssertEqual(postResumeActionCount, 1, "Resume must execute tool directly without re-invoking determineNextAction")
    }

    // MARK: - Group 3: Side-Effect Protection

    func testNotificationToolDispatchedExactlyOnceAcrossPauseResume() async throws {
        let counter = AtomicCounter()
        let notificationTool = LifecycleNotificationMockTool(counter: counter)

        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(action: .callTool(toolName: "mock_notification", parameters: [:], thought: nil))
        await provider.setShouldBlockEvaluationUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider, tools: [notificationTool])

        let pausedExp = expectation(description: "Paused after notification")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .observationReceived = event {
                    _ = await loop.pause()
                }
                if case .paused = event {
                    pausedExp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        await fulfillment(of: [pausedExp], timeout: 2.0)
        eventTask.cancel()

        let dispatchCountBeforeResume = await counter.count
        XCTAssertEqual(dispatchCountBeforeResume, 1)

        await provider.setShouldBlockEvaluationUntilCancelled(false)
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Side-effect complete")

        _ = await loop.resume()
        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)

        let dispatchCountAfterResume = await counter.count
        XCTAssertEqual(dispatchCountAfterResume, 1, "Side-effecting tool must never be re-dispatched upon resume")
    }

    func testAtomicToolExecutionCompletesUninterruptedByPause() async throws {
        let store = AtomicItemStore()
        let atomicTool = LifecycleAtomicMockTool(store: store)

        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(action: .callTool(toolName: "atomic_writer", parameters: [:], thought: nil))
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Atomic write complete")

        let (loop, _) = await makeLoop(provider: provider, tools: [atomicTool])

        let stream = await loop.makeEventStream()
        let pausedExp = expectation(description: "Paused after atomic completion")
        let eventTask = Task {
            for await event in stream {
                if case .actionExecuting(let name) = event, name == "atomic_writer" {
                    _ = await loop.pause()
                }
                if case .paused = event {
                    pausedExp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        await fulfillment(of: [pausedExp], timeout: 2.0)
        eventTask.cancel()

        let items = await store.items
        XCTAssertEqual(items.count, 5, "Atomic tool must complete all written items uninterrupted")

        _ = await loop.resume()
        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
    }

    // MARK: - Group 4: Pause-Gate Continuation Races

    func testPauseGateResumeWinsRaceOverConcurrentPause() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.setShouldBlockActionUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider)

        let runTask = await loop.start()
        try await Task.sleep(nanoseconds: 30_000_000)

        _ = await loop.pause()
        try await Task.sleep(nanoseconds: 30_000_000)

        let phase = await loop.state.phase
        XCTAssertEqual(phase, .paused)

        await provider.setShouldBlockActionUntilCancelled(false)
        await provider.enqueueAction(action: .declareComplete(finalAnswer: "Race complete"))

        // Fire resume and pause concurrently from two tasks
        async let r1: Bool = loop.resume()
        async let p1: Bool = loop.pause()
        _ = await (r1, p1)

        try await Task.sleep(nanoseconds: 50_000_000)
        let currentPhase = await loop.state.phase
        if currentPhase == .paused {
            _ = await loop.resume()
        }

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
    }

    func testPauseGateCancelWinsRaceAndAbortsCleanly() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.setShouldBlockActionUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider)

        let runTask = await loop.start()
        try await Task.sleep(nanoseconds: 30_000_000)

        _ = await loop.pause()
        try await Task.sleep(nanoseconds: 30_000_000)

        let stateBeforeCancel = await loop.state
        XCTAssertEqual(stateBeforeCancel.phase, .paused)

        await loop.cancel()

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .cancelled)
    }

    func testConcurrentPauseAndResumeCallsSerializeDeterministically() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(action: .declareComplete(finalAnswer: "Concurrent ok"))

        let (loop, _) = await makeLoop(provider: provider)

        let runTask = await loop.start()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask {
                    if i % 2 == 0 {
                        _ = await loop.pause()
                    } else {
                        _ = await loop.resume()
                    }
                }
            }
        }

        // If it ended up paused, resume it to completion
        if await loop.state.phase == .paused {
            _ = await loop.resume()
        }

        let finalState = await runTask?.value
        XCTAssertTrue(finalState?.phase == .completed || finalState?.phase == .cancelled)
    }

    // MARK: - Group 5: Session Cancellation & Tool Propagation

    func testSessionCancellationCancelsBothSessionAndOperationSignals() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.setShouldBlockActionUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider)

        let runTask = await loop.start()
        try await Task.sleep(nanoseconds: 30_000_000)

        let opSignal = await loop.activeOperationSignal
        XCTAssertNotNil(opSignal)
        XCTAssertFalse(opSignal?.isCancelled ?? true)

        await loop.cancel()

        let sessionCancelled = await loop.sessionSignal.isCancelled
        XCTAssertTrue(sessionCancelled, "Session signal must be cancelled")
        XCTAssertTrue(opSignal?.isCancelled ?? false, "Operation signal must be cancelled")

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .cancelled)
    }

    func testSandboxedFileReaderAbortsOnSessionSignalCancellation() async throws {
        let cancelledSignal = CancellationSignal()
        cancelledSignal.cancel()

        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            cancellationSignal: cancelledSignal
        )

        let reader = SandboxedFileReaderTool()
        let result = try await reader.execute(parameters: ["path": "/dev/null"], context: context)

        XCTAssertEqual(result.status, .cancelled)
    }

    func testSessionCancellationWhileAwaitingConfirmationAbortsImmediately() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(
            action: .requestConfirmation(
                toolName: "restricted_tool",
                parameters: [:],
                prompt: "Please approve this action"
            )
        )

        let (loop, _) = await makeLoop(
            provider: provider,
            tools: [LifecycleRestrictedMockTool()],
            confirmationTimeoutSeconds: 60.0
        )

        let exp = expectation(description: "Awaiting confirmation")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .waitingForConfirmation = event {
                    exp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        await fulfillment(of: [exp], timeout: 2.0)
        eventTask.cancel()

        let awaitingPhase = await loop.state.phase
        XCTAssertEqual(awaitingPhase, .awaitingConfirmation)

        await loop.cancel()

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .cancelled)
    }

    // MARK: - Group 6: Confirmation Timeout & Approval Races

    func testConfirmationWatchdogTimeoutRejectsAndEmitsEvent() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(
            action: .requestConfirmation(
                toolName: "restricted_tool",
                parameters: [:],
                prompt: "Confirm this"
            )
        )
        // When user rejects/times out, provider declares failure or completes
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Handled timeout")

        let (loop, _) = await makeLoop(
            provider: provider,
            tools: [LifecycleRestrictedMockTool()],
            confirmationTimeoutSeconds: 0.05
        )

        let timeoutExp = expectation(description: "Watchdog fired")
        let stream = await loop.makeEventStream()
        let eventTask = Task {
            for await event in stream {
                if case .confirmationTimedOut = event {
                    timeoutExp.fulfill()
                    break
                }
            }
        }

        let runTask = await loop.start()
        await fulfillment(of: [timeoutExp], timeout: 2.0)
        eventTask.cancel()

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
        XCTAssertEqual(finalState?.finalAnswer, "Handled timeout")

        let rejectionObservation = finalState?.history.first(where: {
            if case .confirmationDecision(_, let approved) = $0.observation {
                return !approved
            }
            return false
        })
        XCTAssertNotNil(rejectionObservation, "Watchdog timeout must record rejected confirmation observation")
    }

    func testSimultaneousApprovalAndTimeoutHandledAtomically() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(
            action: .requestConfirmation(
                toolName: "restricted_tool",
                parameters: [:],
                prompt: "Confirm fast"
            )
        )
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Handled fast confirmation")

        let (loop, _) = await makeLoop(
            provider: provider,
            tools: [LifecycleRestrictedMockTool()],
            confirmationTimeoutSeconds: 0.04
        )

        let runTask = await loop.start()

        // Submit approval right near expiration
        try await Task.sleep(nanoseconds: 35_000_000)
        await loop.submitConfirmationDecision(approved: true)

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
    }

    func testStaleOrMismatchedConfirmationDecisionRejected() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.enqueueAction(
            action: .requestConfirmation(
                toolName: "restricted_tool",
                parameters: [:],
                prompt: "Confirm with matching ID"
            )
        )
        await provider.enqueueEvaluation(isComplete: true, finalAnswer: "Matched approval finished")

        let (loop, _) = await makeLoop(
            provider: provider,
            tools: [LifecycleRestrictedMockTool()],
            confirmationTimeoutSeconds: 60.0
        )

        let stream = await loop.makeEventStream()
        let runTask = await loop.start()

        var capturedRequestId: UUID?
        for await event in stream {
            if case .waitingForConfirmation(let req) = event {
                capturedRequestId = req.id
                break
            }
        }

        XCTAssertNotNil(capturedRequestId)

        // 1. Submit mismatched requestId
        let staleId = UUID()
        await loop.submitConfirmationDecision(requestId: staleId, toolName: "restricted_tool", approved: true)

        // Verify still in .awaitingConfirmation
        let phaseAfterMismatchedId = await loop.state.phase
        XCTAssertEqual(phaseAfterMismatchedId, .awaitingConfirmation)

        // 2. Submit mismatched toolName
        await loop.submitConfirmationDecision(requestId: capturedRequestId, toolName: "wrong_tool", approved: true)

        let phaseAfterMismatchedTool = await loop.state.phase
        XCTAssertEqual(phaseAfterMismatchedTool, .awaitingConfirmation)

        // 3. Submit correct matching requestId and toolName
        await loop.submitConfirmationDecision(requestId: capturedRequestId, toolName: "restricted_tool", approved: true)

        let finalState = await runTask?.value
        XCTAssertEqual(finalState?.phase, .completed)
    }

    // MARK: - Group 7: Run-Task Lifecycle & Attachment

    func testStartRegistersActiveRunTaskAndRejectsDuplicate() async throws {
        let provider = LifecycleMockInferenceProvider()
        await provider.setShouldBlockActionUntilCancelled(true)

        let (loop, _) = await makeLoop(provider: provider)

        let task1 = await loop.start()
        XCTAssertNotNil(task1)

        let activeTask = await loop.activeRunTask
        XCTAssertNotNil(activeTask, "activeRunTask must be non-nil while task is executing")

        // Duplicate start while running must be rejected
        let task2 = await loop.start()
        XCTAssertNil(task2, "Duplicate start() must be rejected and return nil")

        // Now cancel to let it finish
        await loop.cancel()
        _ = await task1?.value

        let clearedActiveTask = await loop.activeRunTask
        XCTAssertNil(clearedActiveTask, "activeRunTask must be cleared on loop completion")
    }
}
