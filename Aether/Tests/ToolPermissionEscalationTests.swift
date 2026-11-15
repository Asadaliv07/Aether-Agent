import XCTest
@testable import Aether

final class ToolPermissionEscalationTests: XCTestCase {
    var tempDirectory: URL!
    var authorizedManager: AuthorizedDirectoryManager!
    var securityGuard: ToolSecurityGuard!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempDirectory = fm.temporaryDirectory.appendingPathComponent("AetherPermTest_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        authorizedManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        try await authorizedManager.authorizeDirectory(url: tempDirectory)

        securityGuard = ToolSecurityGuard(directoryManager: authorizedManager)
    }

    override func tearDown() async throws {
        let fm = FileManager.default
        if let temp = tempDirectory {
            try? fm.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    func testScreenshotSavePathElevation() async throws {
        let screenshotTool = ToolDefinition(
            name: "browser_get_screenshot",
            description: "Takes screenshot",
            parameters: [
                ToolParameter(name: "save_path", type: .string, description: "save path", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )

        let convId = UUID()
        // Without save_path: safeReadOnly -> authorized
        let noSaveDecision = await securityGuard.authorize(
            tool: screenshotTool,
            parameters: [:],
            context: ToolExecutionContext(conversationId: convId)
        )
        XCTAssertEqual(noSaveDecision, .authorized)

        // With save_path in authorized sandbox: elevates to userConfirmationRequired
        let saveDecision = await securityGuard.authorize(
            tool: screenshotTool,
            parameters: ["save_path": tempDirectory.appendingPathComponent("shot.png").path],
            context: ToolExecutionContext(conversationId: convId)
        )
        guard case .requiresUserConfirmation(let req) = saveDecision else {
            XCTFail("save_path must elevate to userConfirmationRequired, got: \(saveDecision)")
            return
        }
        XCTAssertEqual(req.permissionLevel, .userConfirmationRequired)
    }

    func testScreenshotSavePathUnauthorizedDirectoryDenied() async throws {
        let screenshotTool = ToolDefinition(
            name: "browser_get_screenshot",
            description: "Takes screenshot",
            parameters: [
                ToolParameter(name: "save_path", type: .string, description: "save path", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )

        let decision = await securityGuard.authorize(
            tool: screenshotTool,
            parameters: ["save_path": "/var/root/evil.png"],
            context: ToolExecutionContext(conversationId: UUID())
        )
        guard case .denied = decision else {
            XCTFail("Screenshot save_path outside authorized roots must be denied")
            return
        }
    }

    func testRestrictedOperationCannotBeSessionGranted() async throws {
        let deleteTool = ToolDefinition(
            name: "delete_file",
            description: "Deletes file",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "path")
            ],
            category: .filesystem,
            permissionLevel: .restricted
        )

        let convId = UUID()
        // Simulate previous session grant
        await securityGuard.grantSessionPermission(conversationId: convId, toolName: "delete_file")

        let filePath = tempDirectory.appendingPathComponent("file.txt").path
        let decision = await securityGuard.authorize(
            tool: deleteTool,
            parameters: ["path": filePath],
            context: ToolExecutionContext(conversationId: convId)
        )

        // .restricted operations MUST NOT be auto-authorized by session grants
        guard case .requiresUserConfirmation(let req) = decision else {
            XCTFail("Restricted operation delete_file must still require user confirmation even if granted for session, got: \(decision)")
            return
        }
        XCTAssertEqual(req.permissionLevel, .restricted)
    }

    func testUserConfirmationRequiredCanBeSessionGranted() async throws {
        let createTool = ToolDefinition(
            name: "create_folder",
            description: "Creates folder",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "path")
            ],
            category: .filesystem,
            permissionLevel: .userConfirmationRequired
        )

        let convId = UUID()
        let targetPath = tempDirectory.appendingPathComponent("SubFolder").path

        // First call without session grant requires confirmation
        let firstDecision = await securityGuard.authorize(
            tool: createTool,
            parameters: ["path": targetPath],
            context: ToolExecutionContext(conversationId: convId)
        )
        guard case .requiresUserConfirmation = firstDecision else {
            XCTFail("Initial call must require confirmation")
            return
        }

        // Grant session permission
        await securityGuard.grantSessionPermission(conversationId: convId, toolName: "create_folder")

        // Second call with session grant proceeds
        let secondDecision = await securityGuard.authorize(
            tool: createTool,
            parameters: ["path": targetPath],
            context: ToolExecutionContext(conversationId: convId)
        )
        XCTAssertEqual(secondDecision, .authorized)
    }

    func testInteractiveApprovalWithInvalidParametersStillFails() async throws {
        let writeTool = ToolDefinition(
            name: "write_file",
            description: "Writes file",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "path"),
                ToolParameter(name: "content", type: .string, description: "content")
            ],
            category: .filesystem,
            permissionLevel: .userConfirmationRequired
        )

        // Context has interactive approval, but parameters contain path traversal
        let context = ToolExecutionContext(
            conversationId: UUID(),
            isInteractiveApprovalGranted: true
        )

        let decision = await securityGuard.authorize(
            tool: writeTool,
            parameters: [
                "path": "\(tempDirectory.path)/../../../../etc/shadow",
                "content": "payload"
            ],
            context: context
        )

        // Must still be denied! Interactive approval cannot bypass directory traversal validation.
        guard case .denied = decision else {
            XCTFail("Interactive approval must never bypass path traversal validation")
            return
        }
    }
}

