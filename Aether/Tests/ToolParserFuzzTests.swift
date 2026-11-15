import XCTest
@testable import Aether

final class ToolParserFuzzTests: XCTestCase {
    var toolDefs: [ToolDefinition]!
    var securityGuard: ToolSecurityGuard!

    override func setUp() async throws {
        try await super.setUp()
        toolDefs = [
            ToolDefinition(
                name: "create_folder",
                description: "Creates folder",
                parameters: [
                    ToolParameter(name: "path", type: .string, description: "path")
                ],
                category: .filesystem,
                permissionLevel: .userConfirmationRequired
            ),
            ToolDefinition(
                name: "write_file",
                description: "Writes file",
                parameters: [
                    ToolParameter(name: "path", type: .string, description: "path"),
                    ToolParameter(name: "content", type: .string, description: "content")
                ],
                category: .filesystem,
                permissionLevel: .userConfirmationRequired
            ),
            ToolDefinition(
                name: "delete_file",
                description: "Deletes file",
                parameters: [
                    ToolParameter(name: "path", type: .string, description: "path")
                ],
                category: .filesystem,
                permissionLevel: .restricted
            )
        ]

        securityGuard = ToolSecurityGuard()
    }

    func testConflictingDuplicateXMLParametersTriggersRejection() async throws {
        let xmlOutput = """
        <thought>Creating folder</thought>
        <tool_call>
        <name>create_folder</name>
        <parameters>
            <path>/Users/alice/Desktop/AetherTest</path>
            <path>/etc/passwd</path>
        </parameters>
        </tool_call>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: xmlOutput, availableTools: toolDefs)
        guard case .callTool(let name, let params, _) = action else {
            XCTFail("Should have parsed callTool")
            return
        }

        XCTAssertEqual(name, "create_folder")
        XCTAssertNotNil(params["__ambiguous_parameter_conflict"])

        // Passing to securityGuard must result in rejection
        let tool = toolDefs.first(where: { $0.name == "create_folder" })!
        do {
            try await securityGuard.validateParameters(tool: tool, parameters: params)
            XCTFail("validateParameters must fail on ambiguous duplicate parameter conflict")
        } catch let err as SecurityValidationError {
            switch err {
            case .disallowedEnumValue(let paramName, _, _):
                XCTAssertEqual(paramName, "parameter_conflict")
            default:
                XCTFail("Expected .disallowedEnumValue, got \(err)")
            }
        }
    }

    func testIdenticalDuplicateXMLParametersAllowed() throws {
        let xmlOutput = """
        <tool_call>
        <name>create_folder</name>
        <parameters>
            <path>Desktop/Projects</path>
            <path>Desktop/Projects</path>
        </parameters>
        </tool_call>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: xmlOutput, availableTools: toolDefs)
        guard case .callTool(let name, let params, _) = action else {
            XCTFail("Should have parsed callTool")
            return
        }

        XCTAssertEqual(name, "create_folder")
        XCTAssertEqual(params["path"], "Desktop/Projects")
        XCTAssertNil(params["__ambiguous_parameter_conflict"])
    }

    func testToolCallPrioritizedOverPrematureFinalAnswer() throws {
        // Model emits BOTH a tool call and a premature final answer
        let output = """
        <thought>I should create the folder first.</thought>
        <tool_call>
        <name>create_folder</name>
        <parameters>
            <path>Desktop/AetherTest</path>
        </parameters>
        </tool_call>
        <final_answer>I have created the folder on your Desktop.</final_answer>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: output, availableTools: toolDefs)
        // Must prioritize the tool call so work is executed rather than falsely declared complete
        guard case .callTool(let name, let params, _) = action else {
            XCTFail("Premature final answer must not swallow pending tool call! Got: \(action)")
            return
        }

        XCTAssertEqual(name, "create_folder")
        XCTAssertEqual(params["path"], "Desktop/AetherTest")
    }

    func testConflictingXMLAndJSONToolCallsDeclaredFailure() throws {
        let output = """
        <tool_call>
        <name>create_folder</name>
        <parameters><path>FolderA</path></parameters>
        </tool_call>
        ```json
        {
            "name": "delete_file",
            "parameters": {
                "path": "FolderB"
            }
        }
        ```
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: output, availableTools: toolDefs)
        // Conflicting tool calls in single message must be declared failure (ambiguous output)
        guard case .declareFailure(let reason) = action else {
            XCTFail("Conflicting tool calls must trigger declareFailure, got: \(action)")
            return
        }

        XCTAssertTrue(reason.contains("conflicting XML and JSON tool calls"))
    }

    func testMatchingXMLAndJSONToolCallsReturnsSingleToolCall() throws {
        let output = """
        <tool_call>
        <name>create_folder</name>
        <parameters><path>Desktop/AetherTest</path></parameters>
        </tool_call>
        ```json
        {
            "name": "create_folder",
            "parameters": {
                "path": "Desktop/AetherTest"
            }
        }
        ```
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: output, availableTools: toolDefs)
        guard case .callTool(let name, let params, _) = action else {
            XCTFail("Matching XML and JSON should parse cleanly to single callTool")
            return
        }

        XCTAssertEqual(name, "create_folder")
        XCTAssertEqual(params["path"], "Desktop/AetherTest")
    }

    func testNestedXMLTagsAndCDATAUnwrapped() throws {
        let output = """
        <tool_call>
        <name>write_file</name>
        <parameters>
            <path>Desktop/code.swift</path>
            <content><![CDATA[
            import Foundation
            print("<xml>nested</xml>")
            ]]></content>
        </parameters>
        </tool_call>
        """

        let (_, action) = ProductionAgentInferenceProvider.parseModelOutput(from: output, availableTools: toolDefs)
        guard case .callTool(let name, let params, _) = action else {
            XCTFail("Should have parsed callTool")
            return
        }

        XCTAssertEqual(name, "write_file")
        XCTAssertEqual(params["path"], "Desktop/code.swift")
        XCTAssertTrue(params["content"]!.contains("import Foundation"))
        XCTAssertFalse(params["content"]!.contains("<![CDATA["))
    }

    func testUnexpectedParametersRejectedBySecurityGuard() async throws {
        let tool = toolDefs.first(where: { $0.name == "create_folder" })!
        let params = [
            "path": "Desktop/AetherTest",
            "malicious_injected_param": "payload"
        ]

        do {
            try await securityGuard.validateParameters(tool: tool, parameters: params)
            XCTFail("validateParameters must reject unexpected parameter")
        } catch let secError as SecurityValidationError {
            switch secError {
            case .disallowedEnumValue(let name, let val, _):
                XCTAssertEqual(name, "malicious_injected_param")
                XCTAssertEqual(val, "unexpected_parameter")
            default:
                XCTFail("Expected .disallowedEnumValue, got \(secError)")
            }
        }
    }
}
