import XCTest
@testable import Aether

final class ContextBudgeterTests: XCTestCase {

    // Simple deterministic mock tokenizer (1 token per character)
    private let charTokenizer: @Sendable (String) async throws -> Int = { text in
        return text.count
    }

    func testSingleTurnFitsWithinBudget() async throws {
        let messages = [
            PromptMessage(role: .system, content: "Short sys."),
            PromptMessage(role: .user, content: "Short query.")
        ]

        let result = try await ContextBudgeter.budget(
            messages: messages,
            contextLength: 1000,
            maxTokens: 200,
            tokenizer: charTokenizer
        )

        XCTAssertEqual(result.budgetedMessages.count, 2)
        XCTAssertEqual(result.turnsTrimmed, 0)
        XCTAssertTrue(result.totalTokens <= 800)
    }

    func testOutputTokenReservationReducesAvailableBudget() async throws {
        // Budget available = 100 - 60 = 40 tokens max
        // If system is 15 and user is 30, total = 45 > 40, so it should exceed
        let messages = [
            PromptMessage(role: .system, content: String(repeating: "s", count: 15)),
            PromptMessage(role: .user, content: String(repeating: "u", count: 30))
        ]

        do {
            _ = try await ContextBudgeter.budget(
                messages: messages,
                contextLength: 100,
                maxTokens: 60,
                tokenizer: charTokenizer
            )
            XCTFail("Expected contextExhausted error because 45 > 40")
        } catch let InferenceError.contextExhausted(promptTokens, maxContext) {
            XCTAssertEqual(maxContext, 40)
            XCTAssertTrue(promptTokens >= 45)
        }
    }

    func testCompleteTurnPairPruningFromOldest() async throws {
        // System: 10 chars
        // Turn 1 (Oldest): User 20 chars, Assistant 20 chars (40 total)
        // Turn 2 (Middle): User 20 chars, Assistant 20 chars (40 total)
        // Turn 3 (Newest): User 20 chars
        // Total = 10 + 40 + 40 + 20 = 110 tokens
        // ContextLength = 120, maxTokens = 40 -> available = 80 tokens
        // Must prune Turn 1 to fit: 110 - 40 = 70 <= 80
        let messages = [
            PromptMessage(role: .system, content: "System0001"),
            PromptMessage(role: .user, content: "User1_abcdefghijklmn"),
            PromptMessage(role: .assistant, content: "Asst1_abcdefghijklmn"),
            PromptMessage(role: .user, content: "User2_abcdefghijklmn"),
            PromptMessage(role: .assistant, content: "Asst2_abcdefghijklmn"),
            PromptMessage(role: .user, content: "User3_abcdefghijklmn")
        ]

        let result = try await ContextBudgeter.budget(
            messages: messages,
            contextLength: 120,
            maxTokens: 40,
            tokenizer: charTokenizer
        )

        // Turn 1 was pruned, leaving: System, Turn 2 (User2 + Asst2), Turn 3 (User3)
        XCTAssertEqual(result.turnsTrimmed, 1)
        XCTAssertEqual(result.budgetedMessages.count, 4)
        XCTAssertEqual(result.budgetedMessages[0].role, "system")
        XCTAssertEqual(result.budgetedMessages[0].content, "System0001")
        XCTAssertEqual(result.budgetedMessages[1].content, "User2_abcdefghijklmn")
        XCTAssertEqual(result.budgetedMessages[2].content, "Asst2_abcdefghijklmn")
        XCTAssertEqual(result.budgetedMessages[3].content, "User3_abcdefghijklmn")
    }

    func testSystemPromptPermanenceUnderHeavyPruning() async throws {
        // System: 10 chars
        // 5 turns of 30 chars each = 150 chars
        // Total = 160 chars
        // Available budget = 70 chars
        // Must prune 4 turns, preserving System and Newest Turn
        var messages: [PromptMessage] = [
            PromptMessage(role: .system, content: "PermanentS")
        ]
        for i in 1...4 {
            messages.append(PromptMessage(role: .user, content: "U\(i)_0123456789012"))
            messages.append(PromptMessage(role: .assistant, content: "A\(i)_0123456789012"))
        }
        messages.append(PromptMessage(role: .user, content: "U5_0123456789012"))

        let result = try await ContextBudgeter.budget(
            messages: messages,
            contextLength: 100,
            maxTokens: 30, // Available = 70
            tokenizer: charTokenizer
        )

        XCTAssertEqual(result.budgetedMessages.first?.role, "system")
        XCTAssertEqual(result.budgetedMessages.first?.content, "PermanentS")
        XCTAssertEqual(result.budgetedMessages.last?.role, "user")
        XCTAssertEqual(result.budgetedMessages.last?.content, "U5_0123456789012")
        XCTAssertEqual(result.turnsTrimmed, 3)
    }

    func testOverBudgetNewestMessageThrowsContextExhausted() async {
        // Even with no history, System (20) + User (50) = 70 > available (50)
        let messages = [
            PromptMessage(role: .system, content: String(repeating: "S", count: 20)),
            PromptMessage(role: .user, content: String(repeating: "U", count: 50))
        ]

        do {
            _ = try await ContextBudgeter.budget(
                messages: messages,
                contextLength: 100,
                maxTokens: 50, // Available = 50
                tokenizer: charTokenizer
            )
            XCTFail("Expected contextExhausted")
        } catch let InferenceError.contextExhausted(promptTokens, maxContext) {
            XCTAssertEqual(maxContext, 50)
            XCTAssertEqual(promptTokens, 70)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLongSyntheticConversationBudgeting() async throws {
        // 50 turns
        var messages: [PromptMessage] = [
            PromptMessage(role: .system, content: "System Instruction Header.")
        ]
        for i in 1...25 {
            messages.append(PromptMessage(role: .user, content: "User question number \(i) with some padding."))
            messages.append(PromptMessage(role: .assistant, content: "Assistant response number \(i) with explanation."))
        }
        messages.append(PromptMessage(role: .user, content: "Final user query in long conversation."))

        let result = try await ContextBudgeter.budget(
            messages: messages,
            contextLength: 2048,
            maxTokens: 512,
            tokenizer: charTokenizer
        )

        XCTAssertTrue(result.totalTokens <= (2048 - 512))
        XCTAssertEqual(result.budgetedMessages.first?.role, "system")
        XCTAssertEqual(result.budgetedMessages.last?.content, "Final user query in long conversation.")
        XCTAssertTrue(result.turnsTrimmed > 0)
    }

    func testInvalidConfigurationThrowsWhenMaxTokensExceedsContext() async {
        let messages = [PromptMessage(role: .user, content: "Hi")]
        do {
            _ = try await ContextBudgeter.budget(
                messages: messages,
                contextLength: 512,
                maxTokens: 600,
                tokenizer: charTokenizer
            )
            XCTFail("Expected invalidConfiguration")
        } catch let InferenceError.invalidConfiguration(desc) {
            XCTAssertTrue(desc.contains("insufficient"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
