import XCTest
@testable import Aether

final class AuthorizedRootProtectionTests: XCTestCase {
    var rootDirectory: URL!
    var nestedRootDirectory: URL!
    var authorizedManager: AuthorizedDirectoryManager!
    var securityGuard: ToolSecurityGuard!
    var server: MCPFilesystemServer!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        rootDirectory = fm.temporaryDirectory.appendingPathComponent("AetherRootTest_\(UUID().uuidString)")
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        nestedRootDirectory = rootDirectory.appendingPathComponent("NestedRoot")
        try fm.createDirectory(at: nestedRootDirectory, withIntermediateDirectories: true)

        authorizedManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        try await authorizedManager.authorizeDirectory(url: rootDirectory)
        try await authorizedManager.authorizeDirectory(url: nestedRootDirectory)

        securityGuard = ToolSecurityGuard(directoryManager: authorizedManager)
        server = MCPFilesystemServer(directoryManager: authorizedManager)
    }

    override func tearDown() async throws {
        let fm = FileManager.default
        if let root = rootDirectory {
            try? fm.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testCopyFileTargetingRootAsDestinationDenied() async throws {
        let fm = FileManager.default
        let subFile = rootDirectory.appendingPathComponent("sample.txt")
        try "sample content".write(to: subFile, atomically: true, encoding: .utf8)

        // 1. ToolSecurityGuard check
        let copyTool = ToolDefinition(
            name: "copy_file",
            description: "Copies file",
            parameters: [
                ToolParameter(name: "source_path", type: .string, description: "source"),
                ToolParameter(name: "destination_path", type: .string, description: "destination")
            ],
            category: .filesystem,
            permissionLevel: .userConfirmationRequired
        )

        let params = [
            "source_path": subFile.path,
            "destination_path": rootDirectory.path
        ]
        let context = ToolExecutionContext(conversationId: UUID())
        let decision = await securityGuard.authorize(tool: copyTool, parameters: params, context: context)
        guard case .denied(let reason) = decision else {
            XCTFail("copy_file targeting root as destination must be denied, got: \(decision)")
            return
        }
        XCTAssertTrue(reason.contains("authorized root directory itself"))

        // 2. MCPFilesystemServer independent enforcement
        let args: [String: AnyCodableSendable] = [
            "source_path": AnyCodableSendable(subFile.path),
            "destination_path": AnyCodableSendable(rootDirectory.path)
        ]
        let mcpResult = await server.executeTool(name: "copy_file", arguments: args)
        XCTAssertEqual(mcpResult.isError, true)
        XCTAssertTrue(fm.fileExists(atPath: rootDirectory.path), "Root directory must not be removed by copy_file")
    }

    func testMoveFileTargetingRootAsDestinationDenied() async throws {
        let fm = FileManager.default
        let subFile = rootDirectory.appendingPathComponent("sample2.txt")
        try "sample content 2".write(to: subFile, atomically: true, encoding: .utf8)

        let moveTool = ToolDefinition(
            name: "move_file",
            description: "Moves file",
            parameters: [
                ToolParameter(name: "source_path", type: .string, description: "source"),
                ToolParameter(name: "destination_path", type: .string, description: "destination")
            ],
            category: .filesystem,
            permissionLevel: .userConfirmationRequired
        )

        let params = [
            "source_path": subFile.path,
            "destination_path": rootDirectory.path
        ]
        let context = ToolExecutionContext(conversationId: UUID())
        let decision = await securityGuard.authorize(tool: moveTool, parameters: params, context: context)
        guard case .denied = decision else {
            XCTFail("move_file targeting root as destination must be denied")
            return
        }

        let args: [String: AnyCodableSendable] = [
            "source_path": AnyCodableSendable(subFile.path),
            "destination_path": AnyCodableSendable(rootDirectory.path)
        ]
        let mcpResult = await server.executeTool(name: "move_file", arguments: args)
        XCTAssertEqual(mcpResult.isError, true)
        XCTAssertTrue(fm.fileExists(atPath: rootDirectory.path), "Root directory must not be removed by move_file")
    }

    func testDeleteFileTargetingRootDenied() async throws {
        let fm = FileManager.default
        let deleteTool = ToolDefinition(
            name: "delete_file",
            description: "Deletes file",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "path")
            ],
            category: .filesystem,
            permissionLevel: .restricted
        )

        let params = ["path": rootDirectory.path]
        let context = ToolExecutionContext(conversationId: UUID())
        let decision = await securityGuard.authorize(tool: deleteTool, parameters: params, context: context)
        guard case .denied = decision else {
            XCTFail("delete_file targeting root must be denied")
            return
        }

        let args: [String: AnyCodableSendable] = ["path": AnyCodableSendable(rootDirectory.path)]
        let mcpResult = await server.executeTool(name: "delete_file", arguments: args)
        XCTAssertEqual(mcpResult.isError, true)
        XCTAssertTrue(fm.fileExists(atPath: rootDirectory.path), "Root directory must not be deleted")
    }

    func testNestedAuthorizedRootProtection() async throws {
        let fm = FileManager.default
        let deleteTool = ToolDefinition(
            name: "delete_file",
            description: "Deletes file",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "path")
            ],
            category: .filesystem,
            permissionLevel: .restricted
        )

        // Targeting nested root directory directly
        let params = ["path": nestedRootDirectory.path]
        let context = ToolExecutionContext(conversationId: UUID())
        let decision = await securityGuard.authorize(tool: deleteTool, parameters: params, context: context)
        guard case .denied(let reason) = decision else {
            XCTFail("delete_file targeting nested root must be denied")
            return
        }
        XCTAssertTrue(reason.contains("authorized root directory itself"))

        let args: [String: AnyCodableSendable] = ["path": AnyCodableSendable(nestedRootDirectory.path)]
        let mcpResult = await server.executeTool(name: "delete_file", arguments: args)
        XCTAssertEqual(mcpResult.isError, true)
        XCTAssertTrue(fm.fileExists(atPath: nestedRootDirectory.path), "Nested root directory must not be deleted")
    }
}
