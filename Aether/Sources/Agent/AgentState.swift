import Foundation

// MARK: - 1. Agent Phase & Lifecycle

/// High-level lifecycle phases of the agent execution state machine.
public enum AgentPhase: String, Sendable, Codable, Equatable, CaseIterable {
    /// Initial dormant state before a task is started.
    case idle
    /// Analyzing user request and identifying intent, parameters, and constraints.
    case understanding
    /// Formulating a structured execution plan or decomposing goals into subtasks.
    case planning
    /// Dispatching and executing a concrete tool action.
    case executing
    /// Processing and normalizing the raw output from a tool or environment action.
    case observing
    /// Evaluating whether the observation satisfies the plan or requires replanning.
    case evaluating
    /// Paused waiting for interactive user confirmation on a restricted or sensitive operation.
    case awaitingConfirmation
    /// Execution paused at a safe step boundary by user request.
    case paused
    /// Successfully finished with a validated final response.
    case completed
    /// Execution terminated due to unrecoverable failure or circuit breaker.
    case failed
    /// Execution was cancelled cooperatively by user request.
    case cancelled

    /// Whether this phase represents a terminal state where the execution loop terminates.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .idle, .understanding, .planning, .executing, .observing, .evaluating, .awaitingConfirmation, .paused:
            return false
        }
    }
}

// MARK: - 2. Strongly Typed Actions (Agent Intent)

/// Decoupled, strongly typed representations of an agent's intended action.
public enum AgentAction: Sendable, Codable, Equatable {
    /// Intends to invoke a registered tool with parameters.
    case callTool(toolName: String, parameters: [String: String], thought: String?)
    /// Intends to request interactive user confirmation for a sensitive action.
    case requestConfirmation(toolName: String, parameters: [String: String], prompt: String)
    /// Intends to declare the overall objective complete with a final answer.
    case declareComplete(finalAnswer: String)
    /// Intends to abort execution due to an unresolvable roadblock or missing requirement.
    case declareFailure(reason: String)

    public var toolName: String? {
        switch self {
        case .callTool(let name, _, _): return name
        case .requestConfirmation(let name, _, _): return name
        case .declareComplete, .declareFailure: return nil
        }
    }
}

// MARK: - 3. Strongly Typed Observations (Environment Results)

/// Decoupled, strongly typed observations returned from the environment or tool execution.
public enum AgentObservation: Sendable, Codable, Equatable {
    /// Tool executed successfully with textual or structured output.
    case toolSuccess(toolName: String, output: String, durationSeconds: Double)
    /// Tool execution failed with an error description.
    case toolFailure(toolName: String, error: String, durationSeconds: Double)
    /// User responded to an interactive confirmation request.
    case confirmationDecision(toolName: String, approved: Bool)
    /// Tool execution timed out.
    case toolTimedOut(toolName: String, timeoutSeconds: Double)
    /// Tool execution was denied by security policy.
    case securityDenied(toolName: String, reason: String)
    /// Generic environment observation.
    case info(String)

    public var isSuccess: Bool {
        switch self {
        case .toolSuccess: return true
        case .confirmationDecision(_, let approved): return approved
        case .info: return true
        case .toolFailure, .toolTimedOut, .securityDenied: return false
        }
    }

    public var summary: String {
        switch self {
        case .toolSuccess(let name, let out, _):
            return "[\(name)] Success: \(out.prefix(120))"
        case .toolFailure(let name, let err, _):
            return "[\(name)] Failed: \(err)"
        case .confirmationDecision(let name, let approved):
            return "[\(name)] User \(approved ? "Approved" : "Rejected")"
        case .toolTimedOut(let name, let s):
            return "[\(name)] Timed out after \(s)s"
        case .securityDenied(let name, let r):
            return "[\(name)] Denied: \(r)"
        case .info(let text):
            return text
        }
    }
}

// MARK: - 4. Step Snapshot & History

/// An immutable record of a single execution step within an agent session.
public struct AgentStepRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let stepIndex: Int
    public let phase: AgentPhase
    public let thought: String?
    public let action: AgentAction?
    public let observation: AgentObservation?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        stepIndex: Int,
        phase: AgentPhase,
        thought: String? = nil,
        action: AgentAction? = nil,
        observation: AgentObservation? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.stepIndex = stepIndex
        self.phase = phase
        self.thought = thought
        self.action = action
        self.observation = observation
        self.timestamp = timestamp
    }
}

// MARK: - 4b. Step-Boundary Resumption Checkpoints

/// Strongly typed resumption checkpoints capturing exact step boundaries for lossless pause and resume.
public enum AgentResumeCheckpoint: Sendable, Codable, Equatable {
    /// Paused during initial goal analysis, before step 1 planning starts.
    case beforeUnderstanding
    /// Paused before running inference to plan the stepIndex action.
    case beforePlanning(stepIndex: Int)
    /// Paused after an action was proposed, but before the tool was committed or dispatched.
    case beforeToolExecution(stepIndex: Int, action: AgentAction)
    /// Paused after tool execution captured an observation, but before goal evaluation inference.
    case beforeObservationEvaluation(stepIndex: Int, action: AgentAction, observation: AgentObservation)
    /// Paused after evaluation determined the goal is incomplete; ready to begin next step.
    case afterStepCompleted(nextStepIndex: Int)
}

// MARK: - 5. Agent Execution State Machine Snapshot

/// Complete, immutable snapshot of the agent execution state machine at a given point in time.
public struct AgentState: Sendable, Codable, Equatable {
    /// Unique identifier for this agent run.
    public let sessionId: UUID
    /// Associated conversation identifier.
    public let conversationId: UUID
    /// Current high-level lifecycle phase.
    public var phase: AgentPhase
    /// Current zero-indexed step count.
    public var stepIndex: Int
    /// Configured maximum steps allowed before triggering the circuit breaker.
    public let maxSteps: Int
    /// User's initial objective or prompt.
    public let goal: String
    /// Working thoughts or summary formulated during reasoning.
    public var currentThought: String?
    /// The most recent action proposed or dispatched.
    public var lastAction: AgentAction?
    /// The most recent observation received.
    public var lastObservation: AgentObservation?
    /// Final answer synthesized upon successful completion.
    public var finalAnswer: String?
    /// Failure reason if terminated in the failed phase.
    public var errorDescription: String?
    /// Active pause resumption checkpoint if paused.
    public var resumeCheckpoint: AgentResumeCheckpoint?
    /// Complete chronological history of execution steps.
    public var history: [AgentStepRecord]

    public init(
        sessionId: UUID = UUID(),
        conversationId: UUID,
        phase: AgentPhase = .idle,
        stepIndex: Int = 0,
        maxSteps: Int = 10,
        goal: String,
        currentThought: String? = nil,
        lastAction: AgentAction? = nil,
        lastObservation: AgentObservation? = nil,
        finalAnswer: String? = nil,
        errorDescription: String? = nil,
        resumeCheckpoint: AgentResumeCheckpoint? = nil,
        history: [AgentStepRecord] = []
    ) {
        self.sessionId = sessionId
        self.conversationId = conversationId
        self.phase = phase
        self.stepIndex = stepIndex
        self.maxSteps = maxSteps
        self.goal = goal
        self.currentThought = currentThought
        self.lastAction = lastAction
        self.lastObservation = lastObservation
        self.finalAnswer = finalAnswer
        self.errorDescription = errorDescription
        self.resumeCheckpoint = resumeCheckpoint
        self.history = history
    }

    // MARK: - State Transition Validator

    /// Validates whether a proposed phase transition is legal in the deterministic state graph.
    public static func isValidTransition(from current: AgentPhase, to next: AgentPhase) -> Bool {
        // Any non-terminal phase may transition to cancelled
        if next == .cancelled && !current.isTerminal {
            return true
        }

        // Any non-terminal phase may transition to failed
        if next == .failed && !current.isTerminal {
            return true
        }

        // Active phases may transition to paused (Option B: awaitingConfirmation cannot be paused)
        if next == .paused {
            return current == .understanding || current == .planning || current == .executing || current == .observing || current == .evaluating
        }

        switch current {
        case .idle:
            return next == .understanding

        case .understanding:
            return next == .planning || next == .executing || next == .completed

        case .planning:
            return next == .executing || next == .awaitingConfirmation || next == .observing || next == .completed

        case .executing:
            return next == .observing || next == .awaitingConfirmation

        case .awaitingConfirmation:
            // Once confirmed or rejected, returns to executing or advances to observing
            return next == .executing || next == .observing

        case .observing:
            return next == .evaluating

        case .evaluating:
            // Cycle back for next action, or finish
            return next == .executing || next == .awaitingConfirmation || next == .planning || next == .completed

        case .paused:
            // Resuming from pause restores the recorded checkpoint phase or transitions to terminal
            return next == .understanding || next == .planning || next == .executing || next == .observing || next == .evaluating || next == .completed

        case .completed, .failed, .cancelled:
            // Terminal states cannot transition further
            return false
        }
    }
}

// MARK: - 6. Streamable Agent Execution Events

/// Lifecycle events published asynchronously by the execution loop for UI and telemetry observers.
public enum AgentExecutionEvent: Sendable, Equatable {
    case stateChanged(from: AgentPhase, to: AgentPhase)
    case stepStarted(stepIndex: Int, phase: AgentPhase)
    case thoughtEmitted(String)
    case actionProposed(AgentAction)
    case waitingForConfirmation(ToolConfirmationRequest)
    case actionExecuting(toolName: String)
    case observationReceived(AgentObservation)
    case completed(finalAnswer: String, totalSteps: Int)
    case failed(reason: String)
    case cancelled
    case paused(prePausePhase: AgentPhase)
    case resumed(restoredPhase: AgentPhase)
    case confirmationTimedOut(toolName: String, requestId: UUID)
}

