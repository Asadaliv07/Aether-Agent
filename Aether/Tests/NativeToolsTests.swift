import XCTest
@testable import Aether

final class NativeToolsTests: XCTestCase {

    func testSystemInfoToolExecution() async throws {
        let tool = SystemInfoTool()
        let context = ToolExecutionContext()

        let result = try await tool.execute(parameters: [:], context: context)
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.output.contains("Platform: Apple Silicon macOS"))
        XCTAssertTrue(result.output.contains("Active CPU Cores:"))
        XCTAssertTrue(result.output.contains("Physical Unified Memory:"))
        XCTAssertTrue(result.output.contains("Sandboxed: true"))
    }

    func testSafeCalculatorToolArithmeticAndFunctions() async throws {
        let tool = SafeCalculatorTool()
        let context = ToolExecutionContext()

        // 1. Basic precedence: 2 + 3 * 4 = 14
        let res1 = try await tool.execute(parameters: ["expression": "2 + 3 * 4"], context: context)
        XCTAssertTrue(res1.isSuccess)
        XCTAssertEqual(res1.output, "14")

        // 2. Parentheses: (2 + 3) * 4 = 20
        let res2 = try await tool.execute(parameters: ["expression": "(2 + 3) * 4"], context: context)
        XCTAssertTrue(res2.isSuccess)
        XCTAssertEqual(res2.output, "20")

        // 3. Exponentiation: 2 ^ 8 = 256
        let res3 = try await tool.execute(parameters: ["expression": "2 ^ 8"], context: context)
        XCTAssertTrue(res3.isSuccess)
        XCTAssertEqual(res3.output, "256")

        // 4. Mathematical function: sqrt(144) + abs(-10) = 22
        let res4 = try await tool.execute(parameters: ["expression": "sqrt(144) + abs(-10)"], context: context)
        XCTAssertTrue(res4.isSuccess)
        XCTAssertEqual(res4.output, "22")

        // 5. Constants: pi
        let res5 = try await tool.execute(parameters: ["expression": "sin(0)"], context: context)
        XCTAssertTrue(res5.isSuccess)
        XCTAssertEqual(res5.output, "0")

        // 6. Division by zero fails gracefully
        let resZero = try await tool.execute(parameters: ["expression": "100 / 0"], context: context)
        XCTAssertFalse(resZero.isSuccess)
        XCTAssertTrue(resZero.errorDescription?.contains("Division by zero") == true)

        // 7. Malformed syntax fails gracefully
        let resSyntax = try await tool.execute(parameters: ["expression": "5 + * 2"], context: context)
        XCTAssertFalse(resSyntax.isSuccess)
        XCTAssertTrue(resSyntax.errorDescription?.contains("Invalid syntax") == true)
    }

    func testSandboxedFileReaderWithTemporaryFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("aether_test_\(UUID().uuidString).txt")
        let fileContent = """
        Line 1: Swift 6 Concurrency
        Line 2: Actor Isolation
        Line 3: App Sandbox Security
        Line 4: Native macOS Apple Silicon
        Line 5: End of file
        """
        try fileContent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let tool = SandboxedFileReaderTool()
        let context = ToolExecutionContext(isInteractiveApprovalGranted: true)

        // Read all lines
        let resultAll = try await tool.execute(parameters: ["path": testFile.path], context: context)
        XCTAssertTrue(resultAll.isSuccess)
        XCTAssertTrue(resultAll.output.contains("Line 1: Swift 6 Concurrency"))
        XCTAssertTrue(resultAll.output.contains("Line 5: End of file"))

        // Read with max_lines limit
        let resultLimit = try await tool.execute(parameters: ["path": testFile.path, "max_lines": "2"], context: context)
        XCTAssertTrue(resultLimit.isSuccess)
        XCTAssertTrue(resultLimit.output.contains("Line 1: Swift 6 Concurrency"))
        XCTAssertTrue(resultLimit.output.contains("Line 2: Actor Isolation"))
        XCTAssertTrue(resultLimit.output.contains("Truncated: showing first 2 of 5 lines"))

        // Non-existent file
        let resultMissing = try await tool.execute(parameters: ["path": "/tmp/non_existent_file_xyz_123.txt"], context: context)
        XCTAssertFalse(resultMissing.isSuccess)
        XCTAssertTrue(resultMissing.errorDescription?.contains("File not found") == true)
    }

    func testDocumentTextExtractorJSONAndMarkdown() async throws {
        let tempDir = FileManager.default.temporaryDirectory

        // 1. JSON test file
        let jsonFile = tempDir.appendingPathComponent("test_doc_\(UUID().uuidString).json")
        let jsonContent = """
        {
            "appName": "Aether",
            "version": "4.0.0",
            "features": ["Inference", "ModelLibrary", "AgentTools"]
        }
        """
        try jsonContent.write(to: jsonFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: jsonFile) }

        let tool = DocumentTextExtractorTool()
        let context = ToolExecutionContext(isInteractiveApprovalGranted: true)

        let resultJSON = try await tool.execute(parameters: ["path": jsonFile.path], context: context)
        XCTAssertTrue(resultJSON.isSuccess)
        XCTAssertTrue(resultJSON.output.contains("Document Type: .json"))
        XCTAssertTrue(resultJSON.output.contains("Root: Object"))
        XCTAssertTrue(resultJSON.output.contains("appName"))
        XCTAssertTrue(resultJSON.output.contains("features"))

        // 2. Markdown test file
        let mdFile = tempDir.appendingPathComponent("test_doc_\(UUID().uuidString).md")
        let mdContent = """
        # Architectural Overview
        ## Subsystem A
        Content A
        ## Subsystem B
        Content B
        """
        try mdContent.write(to: mdFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: mdFile) }

        let resultMD = try await tool.execute(parameters: ["path": mdFile.path], context: context)
        XCTAssertTrue(resultMD.isSuccess)
        XCTAssertTrue(resultMD.output.contains("Document Type: .md"))
        XCTAssertTrue(resultMD.output.contains("Markdown Sections (3 headings)"))
        XCTAssertTrue(resultMD.output.contains("# Architectural Overview"))
    }
}
