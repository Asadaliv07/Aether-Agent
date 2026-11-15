import XCTest
@testable import Aether

final class MCPPermissionConsistencyTests: XCTestCase {
    var authorizedManager: AuthorizedDirectoryManager!
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempDirectory = fm.temporaryDirectory.appendingPathComponent("AetherMCPPerm_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        authorizedManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        try await authorizedManager.authorizeDirectory(url: tempDirectory)
    }

    override func tearDown() async throws {
        let fm = FileManager.default
        if let temp = tempDirectory {
            try? fm.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    func testFilesystemToolsHaveAccurateDeclaredPermissions() async throws {
        let server = MCPFilesystemServer(directoryManager: authorizedManager)
        let tools = await server.allToolDefinitions()
        XCTAssertEqual(tools.count, 18, "Must define exactly 18 MCP filesystem tools (including get_file_info alias and new tools)")

        let expectedPermissions: [String: ToolPermissionLevel] = [
            "delete_file": .restricted,
            "create_folder": .userConfirmationRequired,
            "create_file": .userConfirmationRequired,
            "write_file": .userConfirmationRequired,
            "append_file": .userConfirmationRequired,
            "copy_file": .userConfirmationRequired,
            "move_file": .userConfirmationRequired,
            "rename_file": .userConfirmationRequired,
            "rename_folder": .userConfirmationRequired,
            "edit_file": .userConfirmationRequired,
            "list_directory": .safeReadOnly,
            "read_file": .safeReadOnly,
            "search_directories": .safeReadOnly,
            "search_files": .safeReadOnly,
            "get_file_metadata": .safeReadOnly,
            "get_file_info": .safeReadOnly,
            "read_multiple_files": .safeReadOnly,
            "directory_tree": .safeReadOnly
        ]

        let (clientT, _) = MCPInMemoryTransport.createPair()
        let dummyClient = MCPClient()
        await dummyClient.connect(transport: clientT)
        for mcpTool in tools {
            let adapter = MCPToolAdapter(mcpTool: mcpTool, client: dummyClient)
            let expected = expectedPermissions[mcpTool.name]
            XCTAssertNotNil(expected, "Unexpected tool name \(mcpTool.name)")
            XCTAssertEqual(adapter.definition.permissionLevel, expected, "Mismatch in permission level for tool \(mcpTool.name)")
            XCTAssertEqual(adapter.definition.category, ToolCategory.filesystem)
        }
    }

    func testBrowserAutomationToolsHaveAccurateDeclaredPermissions() {
        let tools = BrowserAutomationTools.allTools()
        XCTAssertEqual(tools.count, 32, "Must define 32 browser automation tools")

        for tool in tools {
            XCTAssertEqual(tool.definition.category, .browser)
            if tool.definition.name == "browser_fill_form" || tool.definition.name == "browser_evaluate" {
                XCTAssertEqual(tool.definition.permissionLevel, .userConfirmationRequired)
            } else {
                XCTAssertEqual(tool.definition.permissionLevel, .safeReadOnly)
            }
        }
    }

    func testDesktopAutomationToolsHaveAccurateDeclaredPermissions() {
        let tools = DesktopAutomationTools.allTools()
        XCTAssertEqual(tools.count, 22, "Must define 22 desktop automation tools")

        for tool in tools {
            XCTAssertEqual(tool.definition.category, .desktopApp)
            if tool.definition.name == "app_quit" {
                XCTAssertEqual(tool.definition.permissionLevel, .userConfirmationRequired)
            } else {
                XCTAssertEqual(tool.definition.permissionLevel, .safeReadOnly)
            }
        }
    }

    func testNativeApplicationToolsHaveAccurateDeclaredPermissions() {
        let tools = NativeApplicationTools.allTools(directoryManager: authorizedManager)
        XCTAssertEqual(tools.count, 6, "Must define 6 native application tools")

        let expectedLevels: [String: ToolPermissionLevel] = [
            "open_application": .safeReadOnly,
            "quit_application": .userConfirmationRequired,
            "activate_application": .safeReadOnly,
            "switch_application": .safeReadOnly,
            "open_file_with_default_application": .userConfirmationRequired,
            "open_folder_in_finder": .safeReadOnly
        ]

        for tool in tools {
            XCTAssertEqual(tool.definition.category, .desktopApp)
            let expected = expectedLevels[tool.definition.name]
            XCTAssertNotNil(expected, "Unexpected native app tool: \(tool.definition.name)")
            XCTAssertEqual(tool.definition.permissionLevel, expected)
        }
    }

    func testNativeToolsHaveAccurateDeclaredPermissions() {
        let tools: [any Tool] = [
            SystemInfoTool(),
            DateTimeTool(),
            SandboxedFileReaderTool(),
            DocumentTextExtractorTool(),
            SafeCalculatorTool(),
            SystemNotificationTool()
        ]

        let expectedLevels: [String: ToolPermissionLevel] = [
            "system_info": .safeReadOnly,
            "current_date_time": .safeReadOnly,
            "file_reader": .userConfirmationRequired,
            "extract_document_text": .userConfirmationRequired,
            "calculator": .safeReadOnly,
            "system_notification": .userConfirmationRequired
        ]

        for tool in tools {
            let expected = expectedLevels[tool.definition.name]
            XCTAssertNotNil(expected)
            XCTAssertEqual(tool.definition.permissionLevel, expected)
        }
    }

    func testBrowserAndDesktopScreenshotSavePathResolution() async throws {
        let mockBrowser = MockBrowserAutomationProvider()
        let browserSession = BrowserSessionManager(provider: mockBrowser, directoryManager: authorizedManager)

        let mockDesktop = MockDesktopAutomationProvider()
        let desktopSession = ApplicationSessionManager(provider: mockDesktop, directoryManager: authorizedManager)

        // Pass relative path "shot.png"
        let browserResult = try await browserSession.takeScreenshot(savePath: "shot.png")
        // Mock provider should have received canonical resolved path inside authorized root
        XCTAssertTrue(browserResult.contains(tempDirectory.appendingPathComponent("shot.png").path))

        _ = try await desktopSession.captureScreenshot(appName: "Finder", savePath: "desktop_shot.png")
        let actions = await mockDesktop.executedActions
        XCTAssertEqual(actions.last, "captureScreenshot:Finder")
    }
}
