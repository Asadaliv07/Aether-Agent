import Foundation
import os

// MARK: - 1. Agent Inference Abstraction Protocol

/// Decoupled protocol abstracting LLM inference calls from the agent execution loop.
///
/// This separation of concerns allows the execution engine to be tested deterministically with mocks,
/// while seamlessly binding to the production `InferenceService` in the live application.
public protocol AgentInferenceProvider: Sendable {
    /// Determines the next reasoning thought and action based on current state and tool catalog.
    func determineNextAction(
        state: AgentState,
        availableTools: [ToolDefinition],
        cancellationSignal: CancellationSignal?
    ) async throws -> (thought: String?, action: AgentAction)

    /// Evaluates the observation collected from the environment and decides whether to continue or complete.
    func evaluateObservation(
        state: AgentState,
        observation: AgentObservation,
        cancellationSignal: CancellationSignal?
    ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?)

    /// Backward-compatible overload without cancellation signal.
    func determineNextAction(
        state: AgentState,
        availableTools: [ToolDefinition]
    ) async throws -> (thought: String?, action: AgentAction)

    /// Backward-compatible overload without cancellation signal.
    func evaluateObservation(
        state: AgentState,
        observation: AgentObservation
    ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?)
}

public extension AgentInferenceProvider {
    func determineNextAction(
        state: AgentState,
        availableTools: [ToolDefinition],
        cancellationSignal: CancellationSignal?
    ) async throws -> (thought: String?, action: AgentAction) {
        try await determineNextAction(state: state, availableTools: availableTools)
    }

    func determineNextAction(
        state: AgentState,
        availableTools: [ToolDefinition]
    ) async throws -> (thought: String?, action: AgentAction) {
        try await determineNextAction(state: state, availableTools: availableTools, cancellationSignal: nil)
    }

    func evaluateObservation(
        state: AgentState,
        observation: AgentObservation,
        cancellationSignal: CancellationSignal?
    ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?) {
        try await evaluateObservation(state: state, observation: observation)
    }

    func evaluateObservation(
        state: AgentState,
        observation: AgentObservation
    ) async throws -> (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?) {
        try await evaluateObservation(state: state, observation: observation, cancellationSignal: nil)
    }
}

// MARK: - 2. Agent Execution Loop Actor

/// Swift 6 actor-isolated, deterministic execution loop driving multi-step agent reasoning,
/// action execution, observation processing, and evaluation cycles.
public actor AgentExecutionLoopActor {
    /// The current, canonical snapshot of the state machine.
    public private(set) var state: AgentState

    /// Available tools registry.
    public let registry: ToolRegistry

    /// Security guard evaluating authorization decisions.
    public let securityGuard: ToolSecurityGuard

    /// Pluggable inference provider.
    public let inferenceProvider: AgentInferenceProvider

    /// Circuit breaker: maximum execution cycles allowed before halting.
    public let maxSteps: Int

    /// Timeout per individual tool execution.
    public let toolTimeoutSeconds: Double

    /// Timeout for interactive human-in-the-loop confirmation.
    public let confirmationTimeoutSeconds: Double

    /// Session-lifetime authoritative cancellation signal.
    public let sessionSignal = CancellationSignal()

    /// Active operation-scoped cancellation signal for in-flight interruptible inference.
    public private(set) var activeOperationSignal: CancellationSignal?

    /// Active execution run task reference.
    public private(set) var activeRunTask: Task<AgentState, Never>?

    /// Unique token identifying the active execution session to prevent stale cleanups.
    private var activeRunTaskId: UUID?

    /// State of the pause suspension gate.
    private enum PauseGateState {
        case open
        case pauseRequested
        case suspended(CheckedContinuation<Void, Never>)
    }
    private var pauseGateState: PauseGateState = .open

    private var isPauseRequested: Bool {
        if case .pauseRequested = pauseGateState { return true }
        return false
    }

    /// Cooperative cancellation flag.
    private var isCancelled: Bool = false

    /// Pending continuation for interactive human-in-the-loop confirmation.
    private var pendingConfirmationContinuation: CheckedContinuation<Bool, Never>?

    /// Watchdog timer task for confirmation expiration.
    private var confirmationTimeoutTask: Task<Void, Never>?

    /// Active confirmation request ID being awaited, if any.
    public private(set) var activeConfirmationRequestId: UUID?

    /// Active confirmation tool name being awaited, if any.
    public private(set) var activeConfirmationToolName: String?

    /// Active event stream subscribers.
    private var eventContinuations: [UUID: AsyncStream<AgentExecutionEvent>.Continuation] = [:]

    private let logger = Logger(subsystem: "com.aether.Aether", category: "AgentExecutionLoop")

    public init(
        initialState: AgentState,
        registry: ToolRegistry,
        securityGuard: ToolSecurityGuard? = nil,
        inferenceProvider: AgentInferenceProvider,
        maxSteps: Int = 10,
        toolTimeoutSeconds: Double = 30.0,
        confirmationTimeoutSeconds: Double = 60.0
    ) {
        self.state = initialState
        self.registry = registry
        self.securityGuard = securityGuard ?? registry.securityGuard
        self.inferenceProvider = inferenceProvider
        self.maxSteps = maxSteps
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.confirmationTimeoutSeconds = confirmationTimeoutSeconds
    }

    // MARK: - Event Subscription

    /// Creates an asynchronous stream of agent lifecycle events.
    public func makeEventStream() -> AsyncStream<AgentExecutionEvent> {
        let streamId = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeEventContinuation(id: streamId)
                }
            }
            self.eventContinuations[streamId] = continuation
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func emit(_ event: AgentExecutionEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - State Transition Management

    /// Transitions the state machine to a new phase if valid.
    @discardableResult
    private func transition(to nextPhase: AgentPhase, errorDescription: String? = nil, finalAnswer: String? = nil) -> Bool {
        let currentPhase = state.phase
        guard AgentState.isValidTransition(from: currentPhase, to: nextPhase) else {
            logger.error("Illegal state transition rejected: from '\(currentPhase.rawValue)' to '\(nextPhase.rawValue)'")
            return false
        }

        state.phase = nextPhase
        if let err = errorDescription {
            state.errorDescription = err
        }
        if let ans = finalAnswer {
            state.finalAnswer = ans
        }

        emit(.stateChanged(from: currentPhase, to: nextPhase))
        return true
    }

    // MARK: - Single-Winner Pause & Continuation Resolvers

    private enum PauseResolutionAction: String {
        case resume
        case cancel
    }

    @discardableResult
    private func resolvePauseGate(forAction action: PauseResolutionAction) -> Bool {
        switch self.pauseGateState {
        case .suspended(let continuation):
            self.pauseGateState = .open
            continuation.resume()
            logger.debug("Pause gate resolved via \(action.rawValue). Continuation resumed.")
            return true
        case .pauseRequested:
            self.pauseGateState = .open
            return false
        case .open:
            return false
        }
    }

    private func suspendAtPauseGate() async {
        await withCheckedContinuation { continuation in
            if self.isCancelled || self.sessionSignal.isCancelled || Task.isCancelled {
                self.pauseGateState = .open
                continuation.resume()
                return
            }
            self.pauseGateState = .suspended(continuation)
        }
    }

    @discardableResult
    private func resolvePendingConfirmation(approved: Bool) -> Bool {
        guard let continuation = self.pendingConfirmationContinuation else {
            return false
        }
        self.pendingConfirmationContinuation = nil
        self.confirmationTimeoutTask?.cancel()
        self.confirmationTimeoutTask = nil
        self.activeConfirmationRequestId = nil
        self.activeConfirmationToolName = nil
        continuation.resume(returning: approved)
        return true
    }

    // MARK: - Cancellation & Pause Lifecycle Controls

    /// Cooperatively cancels the in-flight execution loop session.
    public func cancel() {
        guard !state.phase.isTerminal else { return }
        isCancelled = true
        sessionSignal.cancel()
        activeOperationSignal?.cancel()
        activeRunTask?.cancel()

        resolvePauseGate(forAction: .cancel)
        resolvePendingConfirmation(approved: false)

        transition(to: .cancelled)
        emit(.cancelled)
        logger.info("Agent execution loop session cancelled by user.")
    }

    /// Requests pausing the execution loop at the next safe step boundary.
    @discardableResult
    public func pause() async -> Bool {
        guard !state.phase.isTerminal && !isCancelled && !sessionSignal.isCancelled else {
            return false
        }
        // Option B: Reject pause while awaiting interactive confirmation
        if state.phase == .awaitingConfirmation {
            logger.warning("Pause rejected: agent is currently awaiting human confirmation.")
            return false
        }
        if state.phase == .paused {
            return true
        }

        pauseGateState = .pauseRequested
        activeOperationSignal?.cancel() // immediately aborts in-flight local inference decode
        logger.info("Pause requested for agent execution loop.")
        return true
    }

    /// Resumes execution from the recorded checkpoint.
    @discardableResult
    public func resume() async -> Bool {
        guard state.phase == .paused, !state.phase.isTerminal, !isCancelled, !sessionSignal.isCancelled else {
            return false
        }

        let targetPhase: AgentPhase
        if let checkpoint = state.resumeCheckpoint {
            switch checkpoint {
            case .beforeUnderstanding:
                targetPhase = .understanding
            case .beforePlanning, .beforeToolExecution, .afterStepCompleted:
                targetPhase = .planning
            case .beforeObservationEvaluation:
                targetPhase = .evaluating
            }
        } else {
            targetPhase = .planning
        }

        guard transition(to: targetPhase) else {
            return false
        }

        emit(.resumed(restoredPhase: targetPhase))
        resolvePauseGate(forAction: .resume)
        logger.info("Agent execution loop resumed to phase '\(targetPhase.rawValue)'.")
        return true
    }

    // MARK: - Human Confirmation Handling

    /// Submits a user authorization decision with request identity and tool validation.
    public func submitConfirmationDecision(
        requestId: UUID?,
        toolName: String? = nil,
        approved: Bool
    ) {
        guard state.phase == .awaitingConfirmation, pendingConfirmationContinuation != nil else {
            logger.warning("Attempted to submit confirmation decision when not awaiting confirmation.")
            return
        }

        if let reqId = requestId {
            guard let activeId = activeConfirmationRequestId, reqId == activeId else {
                logger.warning("Rejected mismatched or stale confirmation decision for requestId: \(reqId), expected: \(String(describing: self.activeConfirmationRequestId))")
                return
            }
        }

        if let name = toolName {
            guard let activeName = activeConfirmationToolName, name == activeName else {
                logger.warning("Rejected mismatched tool confirmation decision for tool: '\(name)', expected: '\(String(describing: self.activeConfirmationToolName))'")
                return
            }
        }

        resolvePendingConfirmation(approved: approved)
    }

    /// Backward-compatible overload submitting a confirmation decision without request ID validation.
    public func submitConfirmationDecision(approved: Bool) {
        submitConfirmationDecision(requestId: nil, toolName: nil, approved: approved)
    }

    /// Awaits human-in-the-loop authorization with watchdog timeout and request identity tracking.
    private func awaitConfirmationDecision(for request: ToolConfirmationRequest) async -> Bool {
        self.activeConfirmationRequestId = request.id
        self.activeConfirmationToolName = request.toolName

        let reqId = request.id
        let toolName = request.toolName
        let timeoutSec = self.confirmationTimeoutSeconds

        self.confirmationTimeoutTask = Task { [weak self] in
            let nanos = UInt64(timeoutSec * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await self?.handleConfirmationTimeout(requestId: reqId, toolName: toolName)
        }

        defer {
            self.activeConfirmationRequestId = nil
            self.activeConfirmationToolName = nil
            self.pendingConfirmationContinuation = nil
            self.confirmationTimeoutTask?.cancel()
            self.confirmationTimeoutTask = nil
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.isCancelled || self.sessionSignal.isCancelled || Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                self.pendingConfirmationContinuation = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.handleTaskCancellationWhileAwaitingConfirmation()
            }
        }
    }

    private func handleConfirmationTimeout(requestId: UUID, toolName: String) {
        guard activeConfirmationRequestId == requestId else { return }
        logger.warning("Confirmation request \(requestId) for tool '\(toolName)' timed out after \(self.confirmationTimeoutSeconds)s.")
        emit(.confirmationTimedOut(toolName: toolName, requestId: requestId))
        resolvePendingConfirmation(approved: false)
    }

    private func handleTaskCancellationWhileAwaitingConfirmation() {
        resolvePendingConfirmation(approved: false)
        if !state.phase.isTerminal {
            transition(to: .cancelled)
            emit(.cancelled)
        }
    }

    // MARK: - Core Execution Engine Loop & Run Task Lifecycle

    /// Atomically launches the agent loop inside an actor-managed `Task`.
    @discardableResult
    public func start() -> Task<AgentState, Never>? {
        guard state.phase == .idle, activeRunTask == nil else {
            logger.warning("Cannot start AgentExecutionLoopActor: already running or phase is not idle (currently: '\(self.state.phase.rawValue)')")
            return nil
        }

        let task = Task { [self] in
            await self.run()
        }

        self.activeRunTask = task
        return task
    }

    /// Executes the agent loop directly in the caller's task context with cooperative cancellation bridging.
    @discardableResult
    public func run() async -> AgentState {
        guard state.phase == .idle else {
            logger.error("Cannot run AgentExecutionLoopActor: initial state must be .idle, currently '\(self.state.phase.rawValue)'")
            return state
        }

        let executionId = activeRunTaskId ?? UUID()
        self.activeRunTaskId = executionId

        return await withTaskCancellationHandler {
            await self.runInternal(executionId: executionId)
        } onCancel: {
            Task { [weak self] in
                await self?.cancel()
            }
        }
    }

    private func runInternal(executionId: UUID) async -> AgentState {
        defer {
            if self.activeRunTaskId == executionId {
                self.activeRunTask = nil
                self.activeRunTaskId = nil
                self.activeOperationSignal = nil
            }
        }

        // 1. Initial Transitions: idle -> understanding -> planning
        if state.phase == .idle {
            guard transition(to: .understanding) else { return state }
            emit(.stepStarted(stepIndex: state.stepIndex, phase: .understanding))

            if isCancelled || sessionSignal.isCancelled || Task.isCancelled {
                transition(to: .cancelled)
                emit(.cancelled)
                return state
            }

            if isPauseRequested {
                state.resumeCheckpoint = .beforeUnderstanding
                transition(to: .paused)
                emit(.paused(prePausePhase: .understanding))
                await suspendAtPauseGate()
            }

            guard transition(to: .planning) else { return state }
            emit(.stepStarted(stepIndex: state.stepIndex, phase: .planning))
        }

        // 2. Cyclic Execution Loop
        while state.stepIndex < maxSteps && !state.phase.isTerminal && !isCancelled && !sessionSignal.isCancelled && !Task.isCancelled {
            // Check for checkpoint resumption jump
            var skipInferenceAndTool = false
            var skipInferenceOnly = false
            var actionToDispatch: AgentAction? = nil
            var observationToEvaluate: AgentObservation? = nil

            if let checkpoint = state.resumeCheckpoint {
                state.resumeCheckpoint = nil
                switch checkpoint {
                case .beforeUnderstanding, .beforePlanning:
                    break
                case .beforeToolExecution(_, let action):
                    skipInferenceOnly = true
                    actionToDispatch = action
                case .beforeObservationEvaluation(_, let action, let obs):
                    skipInferenceAndTool = true
                    actionToDispatch = action
                    observationToEvaluate = obs
                case .afterStepCompleted(let nextStep):
                    state.stepIndex = nextStep - 1
                }
            }

            let thought: String?
            let action: AgentAction

            if skipInferenceAndTool {
                thought = state.currentThought
                action = actionToDispatch ?? (state.lastAction ?? .declareComplete(finalAnswer: "Done"))
            } else if skipInferenceOnly {
                thought = state.currentThought
                action = actionToDispatch ?? (state.lastAction ?? .declareComplete(finalAnswer: "Done"))
            } else {
                state.stepIndex += 1
                emit(.stepStarted(stepIndex: state.stepIndex, phase: .planning))

                // Pre-inference check
                if isCancelled || sessionSignal.isCancelled || Task.isCancelled {
                    transition(to: .cancelled); emit(.cancelled); return state
                }
                if isPauseRequested {
                    state.resumeCheckpoint = .beforePlanning(stepIndex: state.stepIndex)
                    transition(to: .paused); emit(.paused(prePausePhase: .planning))
                    await suspendAtPauseGate()
                    continue
                }

                // A. Request next action from inference provider with fresh operation signal
                let opSignal = CancellationSignal()
                self.activeOperationSignal = opSignal

                let tools = await registry.definitions
                let inferenceResult: (thought: String?, action: AgentAction)

                do {
                    inferenceResult = try await inferenceProvider.determineNextAction(
                        state: state,
                        availableTools: tools,
                        cancellationSignal: opSignal
                    )
                } catch is CancellationError {
                    self.activeOperationSignal = nil
                    if self.sessionSignal.isCancelled || self.isCancelled {
                        transition(to: .cancelled); emit(.cancelled); return state
                    }
                    if self.isPauseRequested {
                        self.state.resumeCheckpoint = .beforePlanning(stepIndex: state.stepIndex)
                        transition(to: .paused); emit(.paused(prePausePhase: .planning))
                        await self.suspendAtPauseGate()
                        continue
                    }
                    transition(to: .cancelled); emit(.cancelled); return state
                } catch {
                    self.activeOperationSignal = nil
                    let err = "Inference failure: \(error.localizedDescription)"
                    transition(to: .failed, errorDescription: err)
                    emit(.failed(reason: err))
                    return state
                }

                self.activeOperationSignal = nil

                // Post-Inference Guard (Discards uncommitted action if pause or cancel arrived)
                if self.sessionSignal.isCancelled || self.isCancelled || Task.isCancelled {
                    transition(to: .cancelled); emit(.cancelled); return state
                }
                if self.isPauseRequested {
                    self.state.resumeCheckpoint = .beforePlanning(stepIndex: state.stepIndex)
                    transition(to: .paused); emit(.paused(prePausePhase: .planning))
                    await self.suspendAtPauseGate()
                    continue
                }

                thought = inferenceResult.thought
                action = inferenceResult.action

                state.currentThought = thought
                state.lastAction = action
                if let t = thought, !t.isEmpty {
                    emit(.thoughtEmitted(t))
                }
                emit(.actionProposed(action))
            }

            // B. Evaluate terminal actions or dispatch proposed action
            let observation: AgentObservation
            if skipInferenceAndTool, let obs = observationToEvaluate {
                observation = obs
            } else {
                switch action {
                case .declareComplete(let finalAnswer):
                    if self.sessionSignal.isCancelled || self.isCancelled || Task.isCancelled {
                        transition(to: .cancelled); emit(.cancelled); return state
                    }
                    if self.isPauseRequested {
                        self.state.resumeCheckpoint = .beforePlanning(stepIndex: state.stepIndex)
                        transition(to: .paused); emit(.paused(prePausePhase: .planning))
                        await self.suspendAtPauseGate()
                        continue
                    }

                    // Autonomous Completion Verification (Phase 6.E)
                    let verification = await AgentCompletionVerifier.verify(state: state, registry: registry)
                    switch verification {
                    case .verified(let details):
                        let step = AgentStepRecord(
                            stepIndex: state.stepIndex,
                            phase: .completed,
                            thought: thought,
                            action: action,
                            observation: .info("Completed and verified: \(details)")
                        )
                        state.history.append(step)
                        transition(to: .completed, finalAnswer: finalAnswer)
                        emit(.completed(finalAnswer: finalAnswer, totalSteps: state.stepIndex))
                        return state

                    case .unverified(let reason):
                        logger.warning("Completion verification failed: \(reason)")
                        let verificationObs = AgentObservation.toolFailure(
                            toolName: "completion_verifier",
                            error: reason,
                            durationSeconds: 0
                        )
                        state.lastObservation = verificationObs
                        emit(.observationReceived(verificationObs))
                        let step = AgentStepRecord(
                            stepIndex: state.stepIndex,
                            phase: .observing,
                            thought: thought,
                            action: action,
                            observation: verificationObs
                        )
                        state.history.append(step)
                        guard transition(to: .observing) else { return state }
                        guard transition(to: .evaluating) else { return state }
                        if state.stepIndex < maxSteps {
                            guard transition(to: .planning) else { return state }
                            emit(.stepStarted(stepIndex: state.stepIndex, phase: .planning))
                            continue
                        } else {
                            transition(to: .failed, errorDescription: reason)
                            emit(.failed(reason: reason))
                            return state
                        }
                    }

                case .declareFailure(let reason):
                    if self.sessionSignal.isCancelled || self.isCancelled || Task.isCancelled {
                        transition(to: .cancelled); emit(.cancelled); return state
                    }
                    let step = AgentStepRecord(
                        stepIndex: state.stepIndex,
                        phase: .failed,
                        thought: thought,
                        action: action,
                        observation: .info("Failed: \(reason)")
                    )
                    state.history.append(step)
                    transition(to: .failed, errorDescription: reason)
                    emit(.failed(reason: reason))
                    return state

                case .requestConfirmation(let toolName, let params, let prompt):
                    if self.sessionSignal.isCancelled || self.isCancelled || Task.isCancelled {
                        transition(to: .cancelled); emit(.cancelled); return state
                    }
                    if self.isPauseRequested {
                        self.state.resumeCheckpoint = .beforePlanning(stepIndex: state.stepIndex)
                        transition(to: .paused); emit(.paused(prePausePhase: .planning))
                        await self.suspendAtPauseGate()
                        continue
                    }

                    let req = ToolConfirmationRequest(
                        toolName: toolName,
                        permissionLevel: .restricted,
                        parameters: params,
                        description: prompt,
                        riskSummary: "Interactive confirmation requested for \(toolName)"
                    )
                    guard transition(to: .awaitingConfirmation) else { return state }
                    emit(.waitingForConfirmation(req))

                    let approved = await awaitConfirmationDecision(for: req)

                    if isCancelled || sessionSignal.isCancelled || Task.isCancelled {
                        if !state.phase.isTerminal {
                            transition(to: .cancelled); emit(.cancelled)
                        }
                        return state
                    }

                    if approved {
                        observation = await executeToolWithSecurity(
                            toolName: toolName,
                            parameters: params,
                            stepIndex: state.stepIndex,
                            preApproved: true
                        )
                    } else {
                        observation = .confirmationDecision(toolName: toolName, approved: false)
                    }

                case .callTool(let toolName, let parameters, _):
                    observation = await executeToolWithSecurity(
                        toolName: toolName,
                        parameters: parameters,
                        stepIndex: state.stepIndex,
                        preApproved: false
                    )
                }
            }

            if isCancelled || sessionSignal.isCancelled || Task.isCancelled || state.phase.isTerminal {
                if !state.phase.isTerminal {
                    transition(to: .cancelled); emit(.cancelled)
                }
                return state
            }

            // D. Process Observation
            if !skipInferenceAndTool {
                guard transition(to: .observing) else { return state }
                state.lastObservation = observation
                emit(.observationReceived(observation))

                let stepRecord = AgentStepRecord(
                    stepIndex: state.stepIndex,
                    phase: .observing,
                    thought: thought,
                    action: action,
                    observation: observation
                )
                state.history.append(stepRecord)
            }

            // Post-observation pause check: if pause was requested while the tool was running,
            // the observation has now been safely recorded. Pause before evaluation.
            if self.isPauseRequested {
                self.state.resumeCheckpoint = .beforeObservationEvaluation(
                    stepIndex: state.stepIndex,
                    action: action,
                    observation: observation
                )
                transition(to: .paused)
                emit(.paused(prePausePhase: .observing))
                await self.suspendAtPauseGate()
            }

            // E. Evaluate Observation against Goal
            if state.phase != .evaluating {
                guard transition(to: .evaluating) else { return state }
            }

            let evalSignal = CancellationSignal()
            self.activeOperationSignal = evalSignal

            let evaluation: (isComplete: Bool, nextAction: AgentAction?, finalAnswer: String?)
            do {
                evaluation = try await inferenceProvider.evaluateObservation(
                    state: state,
                    observation: observation,
                    cancellationSignal: evalSignal
                )
            } catch is CancellationError {
                self.activeOperationSignal = nil
                if self.sessionSignal.isCancelled || self.isCancelled {
                    transition(to: .cancelled); emit(.cancelled); return state
                }
                if self.isPauseRequested {
                    self.state.resumeCheckpoint = .beforeObservationEvaluation(
                        stepIndex: state.stepIndex,
                        action: action,
                        observation: observation
                    )
                    transition(to: .paused); emit(.paused(prePausePhase: .evaluating))
                    await self.suspendAtPauseGate()
                    continue
                }
                transition(to: .cancelled); emit(.cancelled); return state
            } catch {
                self.activeOperationSignal = nil
                let err = "Evaluation failure: \(error.localizedDescription)"
                transition(to: .failed, errorDescription: err)
                emit(.failed(reason: err))
                return state
            }

            self.activeOperationSignal = nil

            // Post-Evaluation Commit Checks
            guard !self.sessionSignal.isCancelled && !self.isCancelled && !Task.isCancelled else {
                transition(to: .cancelled); emit(.cancelled); return state
            }

            if evaluation.isComplete {
                let verification = await AgentCompletionVerifier.verify(state: state, registry: registry)
                switch verification {
                case .verified:
                    let finalAns = evaluation.finalAnswer ?? "Goal completed successfully."
                    transition(to: .completed, finalAnswer: finalAns)
                    emit(.completed(finalAnswer: finalAns, totalSteps: state.stepIndex))
                    return state

                case .unverified(let reason):
                    logger.warning("Evaluation completion verification failed: \(reason)")
                    let verificationObs = AgentObservation.toolFailure(
                        toolName: "completion_verifier",
                        error: reason,
                        durationSeconds: 0
                    )
                    state.lastObservation = verificationObs
                    emit(.observationReceived(verificationObs))
                    let step = AgentStepRecord(
                        stepIndex: state.stepIndex,
                        phase: .observing,
                        thought: nil,
                        action: nil,
                        observation: verificationObs
                    )
                    state.history.append(step)
                    if state.stepIndex < maxSteps {
                        guard transition(to: .planning) else { return state }
                        emit(.stepStarted(stepIndex: state.stepIndex, phase: .planning))
                        continue
                    } else {
                        transition(to: .failed, errorDescription: reason)
                        emit(.failed(reason: reason))
                        return state
                    }
                }
            }

            // Step boundary pause check
            if self.isPauseRequested {
                self.state.resumeCheckpoint = .afterStepCompleted(nextStepIndex: state.stepIndex + 1)
                transition(to: .paused); emit(.paused(prePausePhase: .evaluating))
                await self.suspendAtPauseGate()
            }
        }

        // 3. Final Termination Check
        if isCancelled || sessionSignal.isCancelled || Task.isCancelled {
            if !state.phase.isTerminal {
                transition(to: .cancelled); emit(.cancelled)
            }
        } else if state.stepIndex >= maxSteps && !state.phase.isTerminal {
            let reason = "Circuit breaker triggered: Maximum execution steps (\(maxSteps)) exceeded."
            transition(to: .failed, errorDescription: reason)
            emit(.failed(reason: reason))
        }

        return state
    }

    // MARK: - Tool Security & Asynchronous Dispatch Commit Gate

    private func executeToolWithSecurity(
        toolName: String,
        parameters: [String: String],
        stepIndex: Int,
        preApproved: Bool = false
    ) async -> AgentObservation {
        let startTime = ContinuousClock.now

        // Pre-authorization check
        if self.sessionSignal.isCancelled || self.isCancelled || Task.isCancelled {
            return .securityDenied(toolName: toolName, reason: "Session cancelled prior to tool authorization.")
        }
        if self.isPauseRequested {
            let pendingAction = AgentAction.callTool(toolName: toolName, parameters: parameters, thought: self.state.currentThought)
            self.state.resumeCheckpoint = .beforeToolExecution(stepIndex: stepIndex, action: pendingAction)
            self.transition(to: .paused)
            self.emit(.paused(prePausePhase: .planning))
            await self.suspendAtPauseGate()
            return await executeToolWithSecurity(toolName: toolName, parameters: parameters, stepIndex: stepIndex, preApproved: preApproved)
        }

        guard let tool = await registry.tool(named: toolName) else {
            return .toolFailure(
                toolName: toolName,
                error: "Tool '\(toolName)' is not registered.",
                durationSeconds: 0
            )
        }

        let context = ToolExecutionContext(
            conversationId: state.conversationId,
            executionId: UUID(),
            timeoutSeconds: toolTimeoutSeconds,
            isInteractiveApprovalGranted: preApproved,
            cancellationSignal: sessionSignal
        )

        // Asynchronous Security Authorization (Actor Hop)
        let decision = await securityGuard.authorize(
            tool: tool.definition,
            parameters: parameters,
            context: context
        )

        switch decision {
        case .authorized:
            // =================================================================
            // SYNCHRONOUS DISPATCH COMMIT POINT (Zero intervening awaits)
            // =================================================================
            // 1. Recheck Session Cancellation
            guard !self.sessionSignal.isCancelled && !self.isCancelled && !Task.isCancelled else {
                return .securityDenied(toolName: toolName, reason: "Session cancelled prior to tool execution.")
            }

            // 2. Recheck Pending Pause (arrived while authorization was in flight)
            if self.isPauseRequested {
                let pendingAction = AgentAction.callTool(toolName: toolName, parameters: parameters, thought: self.state.currentThought)
                self.state.resumeCheckpoint = .beforeToolExecution(stepIndex: stepIndex, action: pendingAction)
                self.transition(to: .paused)
                self.emit(.paused(prePausePhase: .planning))
                await self.suspendAtPauseGate()
                return await executeToolWithSecurity(toolName: toolName, parameters: parameters, stepIndex: stepIndex, preApproved: preApproved)
            }

            // 3. Synchronous Commit: Phase changes to .executing only NOW
            self.transition(to: .executing)
            self.emit(.actionExecuting(toolName: toolName))

            // =================================================================
            // POST-COMMIT: Tool Invocation (Deferred tool policy applies)
            // =================================================================
            let result = await registry.execute(
                toolName: toolName,
                parameters: parameters,
                context: context
            )
            let elapsed = Double((ContinuousClock.now - startTime).components.seconds)
            return observationFromResult(result, elapsed: elapsed)

        case .requiresUserConfirmation(let request):
            if self.sessionSignal.isCancelled || self.isCancelled || Task.isCancelled {
                return .securityDenied(toolName: toolName, reason: "Session cancelled prior to user confirmation.")
            }
            if self.isPauseRequested {
                let pendingAction = AgentAction.callTool(toolName: toolName, parameters: parameters, thought: self.state.currentThought)
                self.state.resumeCheckpoint = .beforeToolExecution(stepIndex: stepIndex, action: pendingAction)
                self.transition(to: .paused)
                self.emit(.paused(prePausePhase: .planning))
                await self.suspendAtPauseGate()
                return await executeToolWithSecurity(toolName: toolName, parameters: parameters, stepIndex: stepIndex, preApproved: preApproved)
            }

            guard transition(to: .awaitingConfirmation) else {
                return .securityDenied(toolName: toolName, reason: "Failed to transition to confirmation state.")
            }
            emit(.waitingForConfirmation(request))

            let approved = await awaitConfirmationDecision(for: request)

            if isCancelled || sessionSignal.isCancelled || Task.isCancelled {
                return .securityDenied(toolName: toolName, reason: "Cancelled by user while awaiting confirmation.")
            }

            if approved {
                // Re-enter with preApproved = true through the exact same commit boundary
                return await executeToolWithSecurity(
                    toolName: toolName,
                    parameters: parameters,
                    stepIndex: stepIndex,
                    preApproved: true
                )
            } else {
                return .confirmationDecision(toolName: toolName, approved: false)
            }

        case .denied(let reason):
            return .securityDenied(toolName: toolName, reason: reason)
        }
    }

    private func observationFromResult(_ result: ToolExecutionResult, elapsed: Double) -> AgentObservation {
        switch result.status {
        case .success:
            return .toolSuccess(toolName: result.toolName, output: result.output, durationSeconds: elapsed)
        case .failure:
            return .toolFailure(toolName: result.toolName, error: result.errorDescription ?? "Unknown failure", durationSeconds: elapsed)
        case .permissionDenied:
            return .securityDenied(toolName: result.toolName, reason: result.errorDescription ?? "Permission denied")
        case .userRejected:
            return .confirmationDecision(toolName: result.toolName, approved: false)
        case .timedOut:
            return .toolTimedOut(toolName: result.toolName, timeoutSeconds: toolTimeoutSeconds)
        case .cancelled:
            return .toolFailure(toolName: result.toolName, error: "Tool execution was cancelled.", durationSeconds: elapsed)
        }
    }
}
