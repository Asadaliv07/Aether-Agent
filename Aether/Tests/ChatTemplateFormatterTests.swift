import XCTest
@testable import Aether

final class ChatTemplateFormatterTests: XCTestCase {

    func testSingleTurnChatMLFormatting() throws {
        let messages = [
            PromptMessage(role: .user, content: "Hello Aether!")
        ]

        let prompt = try ChatTemplateFormatter.apply(
            template: nil,
            messages: messages,
            addAssistantPrompt: true,
            modelArchitecture: "chatml"
        )

        XCTAssertTrue(prompt.contains("<|im_start|>user\nHello Aether!<|im_end|>"))
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n"))
    }

    func testMultiTurnConversationPreservesChronologicalOrder() throws {
        let messages = [
            PromptMessage(role: .system, content: "You are a concise assistant."),
            PromptMessage(role: .user, content: "What is 2 + 2?"),
            PromptMessage(role: .assistant, content: "4"),
            PromptMessage(role: .user, content: "And multiply by 3?")
        ]

        let prompt = try ChatTemplateFormatter.apply(
            template: nil,
            messages: messages,
            addAssistantPrompt: true,
            modelArchitecture: "chatml"
        )

        // Verify order of markers
        let sysRange = prompt.range(of: "<|im_start|>system")
        let user1Range = prompt.range(of: "What is 2 + 2?")
        let assistRange = prompt.range(of: "<|im_start|>assistant\n4<|im_end|>")
        let user2Range = prompt.range(of: "And multiply by 3?")
        let finalAssistRange = prompt.range(of: "<|im_start|>assistant\n", options: .backwards)

        XCTAssertNotNil(sysRange)
        XCTAssertNotNil(user1Range)
        XCTAssertNotNil(assistRange)
        XCTAssertNotNil(user2Range)
        XCTAssertNotNil(finalAssistRange)

        if let s = sysRange, let u1 = user1Range, let a = assistRange, let u2 = user2Range, let fa = finalAssistRange {
            XCTAssertTrue(s.lowerBound < u1.lowerBound)
            XCTAssertTrue(u1.lowerBound < a.lowerBound)
            XCTAssertTrue(a.lowerBound < u2.lowerBound)
            XCTAssertTrue(u2.lowerBound < fa.lowerBound)
        }
    }

    func testLlama3FallbackFormatting() throws {
        let messages = [
            PromptMessage(role: .system, content: "System rule."),
            PromptMessage(role: .user, content: "User query.")
        ]

        let prompt = try ChatTemplateFormatter.apply(
            template: nil,
            messages: messages,
            addAssistantPrompt: true,
            modelArchitecture: "llama-3"
        )

        XCTAssertTrue(prompt.contains("<|start_header_id|>system<|end_header_id|>\n\nSystem rule.<|eot_id|>"))
        XCTAssertTrue(prompt.contains("<|start_header_id|>user<|end_header_id|>\n\nUser query.<|eot_id|>"))
        XCTAssertTrue(prompt.hasSuffix("<|start_header_id|>assistant<|end_header_id|>\n\n"))
    }

    func testUnsupportedArchitectureThrowsError() {
        let messages = [
            PromptMessage(role: .user, content: "Hi")
        ]

        XCTAssertThrowsError(
            try ChatTemplateFormatter.apply(
                template: nil,
                messages: messages,
                addAssistantPrompt: true,
                modelArchitecture: "unsupported_unknown_arch_xyz"
            )
        ) { error in
            guard case ChatTemplateError.unsupportedTemplate(let desc) = error else {
                XCTFail("Expected unsupportedTemplate, got: \(error)")
                return
            }
            XCTAssertTrue(desc.contains("lacks embedded chat template"))
        }
    }

    func testEmptyMessagesThrowsError() {
        XCTAssertThrowsError(
            try ChatTemplateFormatter.apply(
                template: nil,
                messages: [],
                addAssistantPrompt: true,
                modelArchitecture: "chatml"
            )
        ) { error in
            guard case ChatTemplateError.emptyMessages = error else {
                XCTFail("Expected emptyMessages error, got: \(error)")
                return
            }
        }
    }

    func testAddAssistantPromptFalseOmitsTrailingTrigger() throws {
        let messages = [
            PromptMessage(role: .user, content: "Evaluate this.")
        ]

        let prompt = try ChatTemplateFormatter.apply(
            template: nil,
            messages: messages,
            addAssistantPrompt: false,
            modelArchitecture: "chatml"
        )

        XCTAssertTrue(prompt.contains("<|im_start|>user\nEvaluate this.<|im_end|>"))
        XCTAssertFalse(prompt.hasSuffix("<|im_start|>assistant\n"))
    }
}
