import Foundation

/// Result of context budgeting and sliding-window pruning.
public struct ContextBudgetResult: Sendable, Equatable {
    /// The surviving messages ordered chronologically and guaranteed to fit within the budget.
    public let budgetedMessages: [PromptMessage]

    /// Whether any historical turns were pruned to respect context capacity.
    public let didPrune: Bool

    /// The estimated token count of the budgeted messages (excluding output reservation).
    public let estimatedPromptTokens: Int

    /// Original count of messages submitted for budgeting.
    public let originalMessageCount: Int

    /// Count of messages retained after budgeting.
    public let budgetedMessageCount: Int

    public init(
        budgetedMessages: [PromptMessage],
        didPrune: Bool,
        estimatedPromptTokens: Int,
        originalMessageCount: Int,
        budgetedMessageCount: Int
    ) {
        self.budgetedMessages = budgetedMessages
        self.didPrune = didPrune
        self.estimatedPromptTokens = estimatedPromptTokens
        self.originalMessageCount = originalMessageCount
        self.budgetedMessageCount = budgetedMessageCount
    }

    /// Number of individual messages pruned during budgeting.
    public var prunedMessageCount: Int {
        originalMessageCount - budgetedMessageCount
    }

    /// Number of complete conversational turns (pairs) pruned.
    public var turnsTrimmed: Int {
        max(0, prunedMessageCount / 2)
    }

    /// Total tokens estimated for the prompt.
    public var totalTokens: Int {
        estimatedPromptTokens
    }
}

/// Algorithmic context budgeter enforcing sliding-window turn pruning while preserving system instructions.
///
/// Adapted from Continue (`core/llm/countTokens.ts:compileChatMessages`), Apache License 2.0.
/// Copyright (c) 2023-2024 Continue Dev, Inc.
public enum ContextBudgeter {
    /// Default safety margin in tokens allocated for template delimiters, BOS/EOS tokens, and role headers.
    public static let defaultSafetyMargin: Int = 64

    /// Prunes conversation history using a sliding-window strategy to guarantee prompt tokens fit within context.
    ///
    /// Invariants:
    /// 1. System instructions (if present at index 0) are permanently pinned and never pruned.
    /// 2. The most recent user prompt (last message) is non-negotiable and never pruned.
    /// 3. Older intermediate turns are pruned from oldest to newest in complete conversational turn pairs.
    /// 4. If even the system instruction and active user prompt exceed capacity, throws `InferenceError.contextExhausted`.
    /// 5. Persisted SQLite records are never modified; pruning applies strictly to the in-memory prompt pipeline.
    ///
    /// - Parameters:
    ///   - messages: Chronologically ordered messages to budget.
    ///   - contextLength: Total context window capacity of the loaded model.
    ///   - maxTokens: Tokens reserved for the model's generated response.
    ///   - safetyMargin: Additional token margin for formatting overhead (default: 0).
    ///   - tokenizer: Asynchronous token counting closure utilizing the active model's vocabulary.
    /// - Returns: `ContextBudgetResult` containing the budgeted message array and telemetry.
    public static func budget(
        messages: [PromptMessage],
        contextLength: Int,
        maxTokens: Int,
        safetyMargin: Int = 0,
        tokenizer: (String) async throws -> Int
    ) async throws -> ContextBudgetResult {
        guard !messages.isEmpty else {
            return ContextBudgetResult(
                budgetedMessages: [],
                didPrune: false,
                estimatedPromptTokens: 0,
                originalMessageCount: 0,
                budgetedMessageCount: 0
            )
        }

        let maxOutputTokens = maxTokens

        let availableForPrompt = contextLength - maxOutputTokens - safetyMargin
        guard availableForPrompt > 0 else {
            throw InferenceError.invalidConfiguration(
                "Context length (\(contextLength)) insufficient for requested output tokens (\(maxOutputTokens)) plus safety buffer (\(safetyMargin))."
            )
        }

        // 1. Identify permanently pinned system message (if present at index 0)
        let systemMessage: PromptMessage?
        let workingMessages: [PromptMessage]
        if messages.first?.role == "system" {
            systemMessage = messages.first
            workingMessages = Array(messages.dropFirst())
        } else {
            systemMessage = nil
            workingMessages = messages
        }

        // 2. Identify the active (latest) turn
        guard let latestMessage = workingMessages.last else {
            // Only a system message was provided
            if let sys = systemMessage {
                let sysTokens = try await tokenizer(sys.content)
                guard sysTokens <= availableForPrompt else {
                    throw InferenceError.contextExhausted(promptTokens: sysTokens, maxContext: availableForPrompt)
                }
                return ContextBudgetResult(
                    budgetedMessages: [sys],
                    didPrune: false,
                    estimatedPromptTokens: sysTokens,
                    originalMessageCount: messages.count,
                    budgetedMessageCount: 1
                )
            }
            return ContextBudgetResult(
                budgetedMessages: [],
                didPrune: false,
                estimatedPromptTokens: 0,
                originalMessageCount: 0,
                budgetedMessageCount: 0
            )
        }

        // 3. Count non-negotiable fixed tokens: system prompt + active user prompt
        let systemTokens = systemMessage != nil ? try await tokenizer(systemMessage!.content) : 0
        let latestTokens = try await tokenizer(latestMessage.content)
        let fixedTokens = systemTokens + latestTokens

        guard fixedTokens <= availableForPrompt else {
            throw InferenceError.contextExhausted(promptTokens: fixedTokens, maxContext: availableForPrompt)
        }

        // 4. Extract intermediate history (between system and latest message)
        let intermediateHistory = Array(workingMessages.dropLast())
        if intermediateHistory.isEmpty {
            var resultMessages = [PromptMessage]()
            if let sys = systemMessage { resultMessages.append(sys) }
            resultMessages.append(latestMessage)
            return ContextBudgetResult(
                budgetedMessages: resultMessages,
                didPrune: false,
                estimatedPromptTokens: fixedTokens,
                originalMessageCount: messages.count,
                budgetedMessageCount: resultMessages.count
            )
        }

        // 5. Calculate token cost for each intermediate message
        var intermediateWithTokens = [(msg: PromptMessage, tokens: Int)]()
        intermediateWithTokens.reserveCapacity(intermediateHistory.count)
        for msg in intermediateHistory {
            let tokens = try await tokenizer(msg.content)
            intermediateWithTokens.append((msg, tokens))
        }

        // 6. Sliding window pruning: iterate backwards from newest to oldest
        let budgetForHistory = availableForPrompt - fixedTokens
        var accumulatedTokens = 0
        var retainedIntermediate = [PromptMessage]()
        var didPrune = false

        // Group into turn pairs where possible from the back
        var index = intermediateWithTokens.count - 1
        while index >= 0 {
            // Determine turn unit: pair (user + assistant) or single message
            if index >= 1 && intermediateWithTokens[index].msg.role == "assistant" && intermediateWithTokens[index - 1].msg.role == "user" {
                let pairCost = intermediateWithTokens[index].tokens + intermediateWithTokens[index - 1].tokens
                if accumulatedTokens + pairCost <= budgetForHistory {
                    accumulatedTokens += pairCost
                    retainedIntermediate.insert(intermediateWithTokens[index].msg, at: 0)
                    retainedIntermediate.insert(intermediateWithTokens[index - 1].msg, at: 0)
                    index -= 2
                } else {
                    didPrune = true
                    break
                }
            } else {
                let singleCost = intermediateWithTokens[index].tokens
                if accumulatedTokens + singleCost <= budgetForHistory {
                    accumulatedTokens += singleCost
                    retainedIntermediate.insert(intermediateWithTokens[index].msg, at: 0)
                    index -= 1
                } else {
                    didPrune = true
                    break
                }
            }
        }

        // 7. Reassemble surviving conversation
        var budgeted = [PromptMessage]()
        if let sys = systemMessage {
            budgeted.append(sys)
        }
        budgeted.append(contentsOf: retainedIntermediate)
        budgeted.append(latestMessage)

        let totalEstimatedTokens = fixedTokens + accumulatedTokens

        return ContextBudgetResult(
            budgetedMessages: budgeted,
            didPrune: didPrune,
            estimatedPromptTokens: totalEstimatedTokens,
            originalMessageCount: messages.count,
            budgetedMessageCount: budgeted.count
        )
    }
}
