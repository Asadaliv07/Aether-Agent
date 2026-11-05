import XCTest
@testable import Aether

final class AgentOrchestratorTests: XCTestCase {

    func testSystemPromptGenerationInjectsTools() async {
        let registry = ToolRegistry()
        await registry.register(SystemInfoTool())
        await registry.register(SafeCalculatorTool())

        let orchestrator = AgentOrchestrator(registry: registry)
        let prompt = await orchestrator.buildSystemPrompt(baseSystemPrompt: "Custom Base System Prompt")

        XCTAssertTrue(prompt.contains("Custom Base System Prompt"))
        XCTAssertTrue(prompt.contains("<tool>"))
        XCTAssertTrue(prompt.contains("<name>system_info</name>"))
        XCTAssertTrue(prompt.contains("<name>calculator</name>"))
        XCTAssertTrue(prompt.contains("TOOL USAGE RULES:"))
        XCTAssertTrue(prompt.contains("<tool_call>"))
    }

    func testToolCallParsingWithThoughtAndXMLTags() {
        let response = """
        <thought>
        The user wants to calculate the area of a circle with radius 5.
        Formula is pi * r^2.
        </thought>
        <tool_call>
        <name>calculator</name>
        <parameters>
        <expression>3.14159 * 5 ^ 2</expression>
        </parameters>
        </tool_call>
        """

        let invocation = AgentOrchestrator.parseToolCall(from: response)
        XCTAssertNotNil(invocation)
        XCTAssertEqual(invocation?.toolName, "calculator")
        XCTAssertEqual(invocation?.parameters["expression"], "3.14159 * 5 ^ 2")
        XCTAssertTrue(invocation?.rawThought?.contains("Formula is pi * r^2") == true)
    }

    func testToolCallParsingZeroParameters() {
        let response = """
        <thought>
        Let me check system information.
        </thought>
        <tool_call>
        <name>system_info</name>
        <parameters>
        </parameters>
        </tool_call>
        """

        let invocation = AgentOrchestrator.parseToolCall(from: response)
        XCTAssertNotNil(invocation)
        XCTAssertEqual(invocation?.toolName, "system_info")
        XCTAssertTrue(invocation?.parameters.isEmpty == true)
    }

    func testToolCallParsingJSONFallback() {
        let response = """
        I will now inspect the document.
        ```json
        {
          "name": "extract_document_text",
          "parameters": {
            "path": "/tmp/sample.json"
          }
        }
        ```
        """

        let invocation = AgentOrchestrator.parseToolCall(from: response)
        XCTAssertNotNil(invocation)
        XCTAssertEqual(invocation?.toolName, "extract_document_text")
        XCTAssertEqual(invocation?.parameters["path"], "/tmp/sample.json")
    }

    func testToolCallParsingReturnsNilForStandardText() {
        let response = "I am happy to explain how Swift actors preserve thread safety by isolating mutable state."
        let invocation = AgentOrchestrator.parseToolCall(from: response)
        XCTAssertNil(invocation)
    }

    func testFormatToolResponse() {
        let successResult = ToolExecutionResult.success(toolName: "calculator", output: "25.0")
        let formattedSuccess = AgentOrchestrator.formatToolResponse(result: successResult)
        XCTAssertTrue(formattedSuccess.contains("<tool_response name=\"calculator\" status=\"success\">"))
        XCTAssertTrue(formattedSuccess.contains("25.0"))

        let failResult = ToolExecutionResult.failure(toolName: "calculator", error: "Division by zero.")
        let formattedFail = AgentOrchestrator.formatToolResponse(result: failResult)
        XCTAssertTrue(formattedFail.contains("<tool_response name=\"calculator\" status=\"error\">"))
        XCTAssertTrue(formattedFail.contains("Division by zero."))
    }

    func testExecuteToolStepWithAuthorizationGate() async {
        let registry = ToolRegistry()
        await registry.register(SystemInfoTool())
        await registry.register(SandboxedFileReaderTool())

        let orchestrator = AgentOrchestrator(registry: registry)
        let convId = UUID()

        // 1. Safe tool executes immediately
        let callSafe = ToolCallInvocation(toolName: "system_info", parameters: [:])
        let (decSafe, resSafe) = await orchestrator.executeToolStep(
            invocation: callSafe,
            conversationId: convId
        )
        XCTAssertEqual(decSafe, .authorized)
        XCTAssertNotNil(resSafe)
        XCTAssertTrue(resSafe?.isSuccess == true)

        // 2. Confirmation required tool yields requiresUserConfirmation without prior approval
        let callConfirm = ToolCallInvocation(toolName: "file_reader", parameters: ["path": "/tmp/test.txt"])
        let (decConfirm, resConfirm) = await orchestrator.executeToolStep(
            invocation: callConfirm,
            conversationId: convId,
            isInteractiveApprovalGranted: false
        )
        if case .requiresUserConfirmation(let req) = decConfirm {
            XCTAssertEqual(req.toolName, "file_reader")
            XCTAssertNil(resConfirm)
        } else {
            XCTFail("Expected requiresUserConfirmation")
        }

        // 3. Same confirmation-required tool executes when isInteractiveApprovalGranted = true
        let (decApproved, resApproved) = await orchestrator.executeToolStep(
            invocation: callConfirm,
            conversationId: convId,
            isInteractiveApprovalGranted: true
        )
        XCTAssertEqual(decApproved, .authorized)
        XCTAssertNotNil(resApproved)
    }
}
