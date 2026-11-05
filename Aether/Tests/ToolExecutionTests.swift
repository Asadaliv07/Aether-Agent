import XCTest
@testable import Aether

final class ToolExecutionTests: XCTestCase {

    private struct MockEchoTool: Tool {
        let definition = ToolDefinition(
            name: "echo_tool",
            description: "Echoes back the received message parameter.",
            parameters: [
                ToolParameter(name: "message", type: .string, description: "Text to echo.")
            ],
            category: .custom,
            permissionLevel: .safeReadOnly
        )

        func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
            let msg = parameters["message"] ?? ""
            return .success(toolName: definition.name, output: "Echo: \(msg)")
        }
    }

    private struct MockSlowTool: Tool {
        let definition = ToolDefinition(
            name: "slow_tool",
            description: "A tool that sleeps to test timeout handling.",
            parameters: [],
            category: .developer,
            permissionLevel: .safeReadOnly
        )

        func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            return .success(toolName: definition.name, output: "Finished")
        }
    }

    func testToolDefinitionJSONSchema() {
        let param = ToolParameter(
            name: "query",
            type: .string,
            description: "Search keyword",
            isRequired: true,
            defaultValue: nil,
            allowedValues: ["apple", "banana"]
        )
        let def = ToolDefinition(
            name: "search_fruit",
            description: "Searches fruits",
            parameters: [param],
            category: .computation,
            permissionLevel: .safeReadOnly
        )

        let schema = def.toJSONSchema()
        XCTAssertEqual(schema["name"] as? String, "search_fruit")
        XCTAssertEqual(schema["description"] as? String, "Searches fruits")

        guard let paramsDict = schema["parameters"] as? [String: Any],
              let props = paramsDict["properties"] as? [String: Any],
              let qProp = props["query"] as? [String: Any],
              let reqList = paramsDict["required"] as? [String] else {
            XCTFail("Schema dictionary malformed")
            return
        }

        XCTAssertEqual(qProp["type"] as? String, "string")
        XCTAssertEqual(qProp["description"] as? String, "Search keyword")
        XCTAssertEqual(qProp["enum"] as? [String], ["apple", "banana"])
        XCTAssertTrue(reqList.contains("query"))
    }

    func testToolRegistryRegistrationAndDiscovery() async {
        let registry = ToolRegistry()
        let echo = MockEchoTool()

        await registry.register(echo)
        let found = await registry.tool(named: "echo_tool")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.definition.name, "echo_tool")

        let defs = await registry.definitions
        XCTAssertTrue(defs.contains(where: { $0.name == "echo_tool" }))

        await registry.unregister(named: "echo_tool")
        let missing = await registry.tool(named: "echo_tool")
        XCTAssertNil(missing)
    }

    func testToolRegistryPromptFormatting() async {
        let registry = ToolRegistry()
        await registry.register(MockEchoTool())

        let xmlFormat = await registry.formatToolsForPrompt(style: .xmlTags)
        XCTAssertTrue(xmlFormat.contains("<tools>"))
        XCTAssertTrue(xmlFormat.contains("<name>echo_tool</name>"))
        XCTAssertTrue(xmlFormat.contains("Echoes back the received message parameter."))

        let mdFormat = await registry.formatToolsForPrompt(style: .markdown)
        XCTAssertTrue(mdFormat.contains("### Available Agent Tools"))
        XCTAssertTrue(mdFormat.contains("`echo_tool`"))

        let jsonFormat = await registry.formatToolsForPrompt(style: .jsonSchema)
        XCTAssertTrue(jsonFormat.contains("echo_tool"))
    }

    func testExecutionTimeoutReturnsTimedOutStatus() async {
        let registry = ToolRegistry()
        await registry.register(MockSlowTool())

        // Set timeout to 50ms, while tool sleeps for 500ms
        let context = ToolExecutionContext(
            conversationId: UUID(),
            timeoutSeconds: 0.05,
            isInteractiveApprovalGranted: true
        )

        let result = await registry.execute(
            toolName: "slow_tool",
            parameters: [:],
            context: context
        )

        XCTAssertEqual(result.status, .timedOut)
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorDescription?.contains("timeout") == true)
    }

    func testAuditLoggingAndSecretRedaction() async {
        let auditLogger = ToolAuditLogger()
        let convId = UUID()

        let def = ToolDefinition(
            name: "api_caller",
            description: "Calls external API",
            parameters: [],
            category: .custom,
            permissionLevel: .safeReadOnly
        )

        let sensitiveParams = [
            "api_key": "sk-1234567890abcdef",
            "user_token": "bearer-token-secret",
            "normal_arg": "public_data"
        ]

        let mockResult = ToolExecutionResult.success(toolName: "api_caller", output: "OK")
        await auditLogger.record(
            conversationId: convId,
            tool: def,
            parameters: sensitiveParams,
            result: mockResult
        )

        let entries = await auditLogger.fetchEntries(for: convId)
        XCTAssertEqual(entries.count, 1)

        let entry = entries[0]
        XCTAssertEqual(entry.toolName, "api_caller")
        XCTAssertEqual(entry.parameters["api_key"], "[REDACTED]")
        XCTAssertEqual(entry.parameters["user_token"], "[REDACTED]")
        XCTAssertEqual(entry.parameters["normal_arg"], "public_data")
    }
}
