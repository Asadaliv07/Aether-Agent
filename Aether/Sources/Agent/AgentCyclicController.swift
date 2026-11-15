import Foundation

/// Pure functional, deterministic, `Sendable` policy component responsible for detecting
/// infinite reasoning loops, repeated failed tool calls, duplicate actions, oscillating patterns,
/// and cognitive stagnation in agent execution runs.
public struct AgentCyclicController: Sendable, Equatable {

    // MARK: - Configuration

    /// Thresholds and tuning parameters for cyclic and stagnation detection.
    public struct Configuration: Sendable, Equatable {
        /// Maximum consecutive identical actions permitted before intervention guidance is emitted (default: 2).
        public var maxConsecutiveIdenticalActions: Int

        /// Hard limit of consecutive identical actions before terminating the loop (default: 3).
        public var maxIdenticalActionsAbortThreshold: Int

        /// Maximum consecutive failures of the same tool permitted before intervention guidance is emitted (default: 2).
        public var maxConsecutiveToolFailures: Int

        /// Hard limit of consecutive failures of the same tool before aborting (default: 3).
        public var maxToolFailuresAbortThreshold: Int

        /// Number of alternating action cycles (e.g. A -> B -> A -> B) before intervention guidance (default: 2).
        public var maxOscillationCycles: Int

        /// Hard limit of alternating action cycles before aborting (default: 3).
        public var maxOscillationAbortThreshold: Int

        /// Maximum consecutive steps with identical or empty thought progress without new actions (default: 3).
        public var maxStagnantThoughts: Int

        public init(
            maxConsecutiveIdenticalActions: Int = 2,
            maxIdenticalActionsAbortThreshold: Int = 3,
            maxConsecutiveToolFailures: Int = 2,
            maxToolFailuresAbortThreshold: Int = 3,
            maxOscillationCycles: Int = 2,
            maxOscillationAbortThreshold: Int = 3,
            maxStagnantThoughts: Int = 3
        ) {
            self.maxConsecutiveIdenticalActions = maxConsecutiveIdenticalActions
            self.maxIdenticalActionsAbortThreshold = maxIdenticalActionsAbortThreshold
            self.maxConsecutiveToolFailures = maxConsecutiveToolFailures
            self.maxToolFailuresAbortThreshold = maxToolFailuresAbortThreshold
            self.maxOscillationCycles = maxOscillationCycles
            self.maxOscillationAbortThreshold = maxOscillationAbortThreshold
            self.maxStagnantThoughts = maxStagnantThoughts
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Detection Results

    /// Diagnostic classification of a detected reasoning cycle or execution failure.
    public enum CycleDetectionResult: Sendable, Equatable {
        /// No cycle or stagnation detected; execution is proceeding healthily.
        case none

        /// Identical action repeated consecutively N times.
        case consecutiveIdenticalActions(action: AgentAction, count: Int)

        /// The same tool failed consecutively N times.
        case repeatedToolFailure(toolName: String, failureCount: Int, lastError: String)

        /// An oscillating sequence of alternating actions detected (e.g. A -> B -> A -> B).
        case oscillatingPattern(actionA: AgentAction, actionB: AgentAction, cycles: Int)

        /// Identical reasoning thoughts repeated across multiple steps without progression.
        case stagnation(thought: String, count: Int)
    }

    // MARK: - Policy Decisions

    /// Policy decision instructing the execution loop or inference provider how to handle the current state.
    public enum PolicyDecision: Sendable, Equatable {
        /// Proceed with execution normally without intervention.
        case allow

        /// Inject self-correction prompt guidance into the agent's observation/prompt history.
        case injectGuidance(guidance: String, result: CycleDetectionResult)

        /// Safely terminate the execution loop to avoid runaway resource depletion.
        case abort(reason: String, result: CycleDetectionResult)
    }

    // MARK: - Parameter & Action Equivalence

    /// Evaluates whether two parameter dictionaries are functionally equivalent,
    /// normalizing for whitespace, key ordering, and potential JSON structure equivalence.
    public func areParametersEquivalent(_ lhs: [String: String], _ rhs: [String: String]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        for (key, val1) in lhs {
            guard let val2 = rhs[key] else { return false }

            let trimmed1 = val1.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed2 = val2.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed1 == trimmed2 {
                continue
            }

            // Attempt JSON normalization comparison if both strings appear to be JSON objects/arrays
            if (trimmed1.hasPrefix("{") && trimmed1.hasSuffix("}")) ||
               (trimmed1.hasPrefix("[") && trimmed1.hasSuffix("]")) {
                if let d1 = trimmed1.data(using: .utf8),
                   let d2 = trimmed2.data(using: .utf8),
                   let obj1 = try? JSONSerialization.jsonObject(with: d1),
                   let obj2 = try? JSONSerialization.jsonObject(with: d2) {
                    if NSDictionary(object: obj1, forKey: "k" as NSString).isEqual(to: [ "k": obj2 ]) {
                        continue
                    }
                }
            }

            return false
        }

        return true
    }

    /// Evaluates whether two `AgentAction` instances represent the same intended operation.
    public func areActionsEquivalent(_ lhs: AgentAction, _ rhs: AgentAction) -> Bool {
        switch (lhs, rhs) {
        case (.callTool(let n1, let p1, _), .callTool(let n2, let p2, _)):
            return n1 == n2 && areParametersEquivalent(p1, p2)

        case (.requestConfirmation(let n1, let p1, _), .requestConfirmation(let n2, let p2, _)):
            return n1 == n2 && areParametersEquivalent(p1, p2)

        case (.declareComplete(let a1), .declareComplete(let a2)):
            return a1.trimmingCharacters(in: .whitespacesAndNewlines) == a2.trimmingCharacters(in: .whitespacesAndNewlines)

        case (.declareFailure(let r1), .declareFailure(let r2)):
            return r1.trimmingCharacters(in: .whitespacesAndNewlines) == r2.trimmingCharacters(in: .whitespacesAndNewlines)

        default:
            return false
        }
    }

    // MARK: - Cycle Analysis

    /// Comprehensive analysis of the step history and optional pending action.
    public func analyze(
        history: [AgentStepRecord],
        pendingAction: AgentAction? = nil
    ) -> CycleDetectionResult {
        // 1. Check for consecutive identical actions (highest priority)
        if let identical = detectConsecutiveIdenticalActions(history: history, pendingAction: pendingAction) {
            return .consecutiveIdenticalActions(action: identical.action, count: identical.count)
        }

        // 2. Check for repeated tool failures
        if let failures = detectRepeatedToolFailures(history: history) {
            return .repeatedToolFailure(
                toolName: failures.toolName,
                failureCount: failures.failureCount,
                lastError: failures.lastError
            )
        }

        // 3. Check for oscillating action patterns (A -> B -> A -> B)
        if let oscillation = detectOscillatingPattern(history: history, pendingAction: pendingAction) {
            return .oscillatingPattern(
                actionA: oscillation.actionA,
                actionB: oscillation.actionB,
                cycles: oscillation.cycles
            )
        }

        // 4. Check for reasoning thought stagnation
        if let stagnation = detectStagnation(history: history) {
            return .stagnation(thought: stagnation.thought, count: stagnation.count)
        }

        return .none
    }

    /// Evaluates the policy and determines whether to allow, inject self-correction guidance, or abort.
    public func evaluatePolicy(
        history: [AgentStepRecord],
        pendingAction: AgentAction? = nil
    ) -> PolicyDecision {
        let result = analyze(history: history, pendingAction: pendingAction)

        switch result {
        case .none:
            return .allow

        case .consecutiveIdenticalActions(let action, let count):
            if count >= configuration.maxIdenticalActionsAbortThreshold {
                let toolDesc = action.toolName ?? "action"
                let reason = "Execution aborted: The model generated identical \(toolDesc) \(count) times consecutively without progress."
                return .abort(reason: reason, result: result)
            } else if count >= configuration.maxConsecutiveIdenticalActions {
                let guidance = generateSelfCorrectionGuidance(for: result)
                return .injectGuidance(guidance: guidance, result: result)
            }
            return .allow

        case .repeatedToolFailure(let toolName, let failureCount, let lastError):
            if failureCount >= configuration.maxToolFailuresAbortThreshold {
                let reason = "Execution aborted: Tool '\(toolName)' failed \(failureCount) consecutive times. Last error: \(lastError)"
                return .abort(reason: reason, result: result)
            } else if failureCount >= configuration.maxConsecutiveToolFailures {
                let guidance = generateSelfCorrectionGuidance(for: result)
                return .injectGuidance(guidance: guidance, result: result)
            }
            return .allow

        case .oscillatingPattern(_, _, let cycles):
            if cycles >= configuration.maxOscillationAbortThreshold {
                let reason = "Execution aborted: Oscillating loop detected across \(cycles) alternating cycles."
                return .abort(reason: reason, result: result)
            } else if cycles >= configuration.maxOscillationCycles {
                let guidance = generateSelfCorrectionGuidance(for: result)
                return .injectGuidance(guidance: guidance, result: result)
            }
            return .allow

        case .stagnation(_, let count):
            if count >= configuration.maxStagnantThoughts {
                let guidance = generateSelfCorrectionGuidance(for: result)
                return .injectGuidance(guidance: guidance, result: result)
            }
            return .allow
        }
    }

    // MARK: - Specialized Detectors

    /// Detects consecutive identical actions at the trailing edge of history.
    public func detectConsecutiveIdenticalActions(
        history: [AgentStepRecord],
        pendingAction: AgentAction? = nil
    ) -> (action: AgentAction, count: Int)? {
        var actions: [AgentAction] = history.compactMap(\.action)
        if let pending = pendingAction {
            actions.append(pending)
        }

        guard let targetAction = actions.last else { return nil }

        var count = 0
        for action in actions.reversed() {
            if areActionsEquivalent(action, targetAction) {
                count += 1
            } else {
                break
            }
        }

        if count >= configuration.maxConsecutiveIdenticalActions {
            return (action: targetAction, count: count)
        }

        return nil
    }

    /// Detects consecutive failures of the same tool at the trailing edge of history.
    public func detectRepeatedToolFailures(
        history: [AgentStepRecord]
    ) -> (toolName: String, failureCount: Int, lastError: String)? {
        guard !history.isEmpty else { return nil }

        // Inspect trailing steps with observations
        var targetToolName: String? = nil
        var lastError: String = ""
        var failureCount = 0

        for step in history.reversed() {
            guard let obs = step.observation else { break }

            switch obs {
            case .toolFailure(let name, let err, _):
                if targetToolName == nil {
                    targetToolName = name
                    lastError = err
                    failureCount = 1
                } else if targetToolName == name {
                    failureCount += 1
                } else {
                    // Different tool failure encountered; break chain
                    return failureCount >= configuration.maxConsecutiveToolFailures
                        ? (toolName: targetToolName!, failureCount: failureCount, lastError: lastError)
                        : nil
                }

            case .toolTimedOut(let name, let seconds):
                let err = "Timed out after \(seconds)s"
                if targetToolName == nil {
                    targetToolName = name
                    lastError = err
                    failureCount = 1
                } else if targetToolName == name {
                    failureCount += 1
                } else {
                    return failureCount >= configuration.maxConsecutiveToolFailures
                        ? (toolName: targetToolName!, failureCount: failureCount, lastError: lastError)
                        : nil
                }

            case .securityDenied(let name, let reason):
                let err = "Security policy denied execution: \(reason)"
                if targetToolName == nil {
                    targetToolName = name
                    lastError = err
                    failureCount = 1
                } else if targetToolName == name {
                    failureCount += 1
                } else {
                    return failureCount >= configuration.maxConsecutiveToolFailures
                        ? (toolName: targetToolName!, failureCount: failureCount, lastError: lastError)
                        : nil
                }

            case .toolSuccess, .confirmationDecision, .info:
                // Successful or neutral observation breaks the consecutive failure chain
                if let target = targetToolName, failureCount >= configuration.maxConsecutiveToolFailures {
                    return (toolName: target, failureCount: failureCount, lastError: lastError)
                }
                return nil
            }
        }

        if let target = targetToolName, failureCount >= configuration.maxConsecutiveToolFailures {
            return (toolName: target, failureCount: failureCount, lastError: lastError)
        }

        return nil
    }

    /// Detects oscillating alternating patterns (A -> B -> A -> B) at the trailing edge of actions.
    public func detectOscillatingPattern(
        history: [AgentStepRecord],
        pendingAction: AgentAction? = nil
    ) -> (actionA: AgentAction, actionB: AgentAction, cycles: Int)? {
        var actions: [AgentAction] = history.compactMap(\.action)
        if let pending = pendingAction {
            actions.append(pending)
        }

        // Need at least 4 actions to detect 2 cycles of period 2: [A, B, A, B]
        guard actions.count >= 4 else { return nil }

        let n = actions.count
        let b = actions[n - 1]
        let a = actions[n - 2]

        // A and B must be distinct actions
        guard !areActionsEquivalent(a, b) else { return nil }

        var cycles = 1
        var idx = n - 3

        while idx >= 1 {
            let prevB = actions[idx]
            let prevA = actions[idx - 1]

            if areActionsEquivalent(prevB, b) && areActionsEquivalent(prevA, a) {
                cycles += 1
                idx -= 2
            } else {
                break
            }
        }

        if cycles >= configuration.maxOscillationCycles {
            return (actionA: a, actionB: b, cycles: cycles)
        }

        return nil
    }

    /// Detects reasoning stagnation where the agent repeats thoughts without producing new actionable progress.
    public func detectStagnation(
        history: [AgentStepRecord]
    ) -> (thought: String, count: Int)? {
        guard history.count >= configuration.maxStagnantThoughts else { return nil }

        let trailingThoughts = history.compactMap { record -> String? in
            guard let t = record.thought?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
                return nil
            }
            return t
        }

        guard let targetThought = trailingThoughts.last else { return nil }

        var count = 0
        for thought in trailingThoughts.reversed() {
            if thought == targetThought {
                count += 1
            } else {
                break
            }
        }

        if count >= configuration.maxStagnantThoughts {
            return (thought: targetThought, count: count)
        }

        return nil
    }

    // MARK: - Self-Correction Guidance Generation

    /// Generates targeted, non-punitive, prompt-injectable self-correction instructions.
    public func generateSelfCorrectionGuidance(for result: CycleDetectionResult) -> String {
        switch result {
        case .none:
            return ""

        case .consecutiveIdenticalActions(let action, let count):
            let toolName = action.toolName ?? "action"
            return """
            [SYSTEM GUIDANCE: REPETITION DETECTED]
            You have issued the identical '\(toolName)' command \(count) times consecutively without advancing the objective.
            Do NOT repeat this identical invocation.
            Carefully inspect the previous tool output or error. Select a different tool, modify your parameters, or if sufficient information has been obtained, output your final answer directly inside <final_answer>...</final_answer>.
            """

        case .repeatedToolFailure(let toolName, let count, let lastError):
            return """
            [SYSTEM GUIDANCE: REPEATED TOOL FAILURE]
            The tool '\(toolName)' has failed \(count) times in succession.
            Last observed error: "\(lastError)"
            Do NOT repeat the exact same call.
            Analyze the failure reason. Provide missing or corrected arguments, choose an alternative tool, or explain the limitation to the user in your final answer.
            """

        case .oscillatingPattern(let actionA, let actionB, let cycles):
            let nameA = actionA.toolName ?? "Action A"
            let nameB = actionB.toolName ?? "Action B"
            return """
            [SYSTEM GUIDANCE: OSCILLATION DETECTED]
            You are alternating between '\(nameA)' and '\(nameB)' in a repetitive loop (\(cycles) cycles).
            Break this cycle immediately. Do not switch back and forth.
            Synthesize what you have learned from both actions and either proceed to a conclusive step or declare completion with <final_answer>.
            """

        case .stagnation(let thought, let count):
            let preview = thought.prefix(80)
            return """
            [SYSTEM GUIDANCE: REASONING STAGNATION]
            Your internal reasoning has repeated similar statements \(count) times ("\(preview)...") without executing new actions.
            Please take a concrete action: either invoke an available tool with <tool_call> or deliver your final answer inside <final_answer>...</final_answer>.
            """
        }
    }
}

