import XCTest
@testable import Aether

final class ToolDiscoveryTests: XCTestCase {
    var directoryManager: AuthorizedDirectoryManager!
    var tempDirectory: URL!
    var registry: ToolRegistry!
    var mcpServer: MCPFilesystemServer!
    var mcpClient: MCPClient!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempDirectory = fm.temporaryDirectory.appendingPathComponent("AetherDiscovery_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        directoryManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        try await directoryManager.authorizeDirectory(url: tempDirectory)

        let mockBrowser = MockBrowserAutomationProvider()
        let browserSession = BrowserSessionManager(provider: mockBrowser, directoryManager: directoryManager)

        let mockDesktop = MockDesktopAutomationProvider()
        let appSession = ApplicationSessionManager(provider: mockDesktop, directoryManager: directoryManager)

        registry = ToolRegistry()
        await registry.securityGuard.setDirectoryManager(directoryManager)
        await registry.registerAllDefaultTools(
            directoryManager: directoryManager,
            browserSession: browserSession,
            appSession: appSession
        )

        // Setup MCP Filesystem server and adapter tools
        mcpServer = MCPFilesystemServer(directoryManager: directoryManager)
        let (clientT, serverT) = MCPInMemoryTransport.createPair()
        await mcpServer.start(transport: serverT)
        mcpClient = MCPClient()
        await mcpClient.connect(transport: clientT)
        _ = try await mcpClient.initialize(clientInfo: MCPImplementation(name: "TestDiscoveryClient", version: "1.0.0"))
        let mcpTools = try await mcpClient.listTools()
        for mcpTool in mcpTools {
            let adapter = MCPToolAdapter(mcpTool: mcpTool, client: mcpClient)
            await registry.register(adapter)
        }
    }

    override func tearDown() async throws {
        await mcpServer.stop()
        let fm = FileManager.default
        if let temp = tempDirectory {
            try? fm.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - 1. Complete Inventory Audit

    func testCompleteToolInventoryAndCategoryCounts() async throws {
        let defs = await registry.definitions
        XCTAssertGreaterThanOrEqual(defs.count, 70, "Registry must register all supported ecosystem tools")

        let browserTools = await registry.definitions(in: .browser)
        let filesystemTools = await registry.definitions(in: .filesystem)
        let desktopTools = await registry.definitions(in: .desktopApp)
        let systemInfoTools = await registry.definitions(in: .systemInfo)
        let computationTools = await registry.definitions(in: .computation)
        let notificationTools = await registry.definitions(in: .notification)

        XCTAssertEqual(browserTools.count, 32, "Must have 32 registered browser tools")
        XCTAssertEqual(filesystemTools.count, 20, "Must have 20 filesystem tools (18 MCP + 2 Native)")
        XCTAssertEqual(desktopTools.count, 28, "Must have 28 desktop tools (22 automation + 6 native app)")
        XCTAssertEqual(systemInfoTools.count, 2, "Must have 2 system info tools (system_info, current_date_time)")
        XCTAssertEqual(computationTools.count, 1, "Must have 1 computation tool (calculator)")
        XCTAssertEqual(notificationTools.count, 1, "Must have 1 notification tool (system_notification)")

        // Verify zero duplicate tool names
        let toolNames = defs.map { $0.name }
        let uniqueNames = Set(toolNames)
        XCTAssertEqual(toolNames.count, uniqueNames.count, "No duplicate tool names permitted in registry")
    }

    // MARK: - 2. Schema and Parameter Validity

    func testEveryToolHasValidSchemaAndRequiredParameters() async {
        let defs = await registry.definitions
        for def in defs {
            XCTAssertFalse(def.name.isEmpty, "Tool name cannot be empty")
            XCTAssertFalse(def.description.isEmpty, "Tool description cannot be empty for '\(def.name)'")

            for param in def.parameters {
                XCTAssertFalse(param.name.isEmpty, "Parameter name cannot be empty in tool '\(def.name)'")
                XCTAssertFalse(param.description.isEmpty, "Parameter description cannot be empty for '\(param.name)' in '\(def.name)'")
            }

            // Check JSON schema export
            let schema = def.toJSONSchema()
            XCTAssertEqual(schema["name"] as? String, def.name)
            XCTAssertNotNil(schema["parameters"])
        }
    }

    // MARK: - 3. Model Prompt Synchronization

    func testEveryToolAppearsInFormattedModelPrompt() async {
        let xmlPrompt = await registry.formatToolsForPrompt(style: .xmlTags)
        let defs = await registry.definitions

        for def in defs {
            let tag = "<name>\(def.name)</name>"
            XCTAssertTrue(xmlPrompt.contains(tag), "Prompt XML must include tool tag for '\(def.name)'")
        }
    }

    // MARK: - 4. Execution Handler Presence & Dispatch

    func testEveryRegisteredToolHasFunctioningExecutionHandler() async throws {
        let defs = await registry.definitions
        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            timeoutSeconds: 5.0,
            isInteractiveApprovalGranted: true
        )

        for def in defs {
            let tool = await registry.tool(named: def.name)
            XCTAssertNotNil(tool, "Tool handler must exist for '\(def.name)'")

            // Execute with empty parameters or safe dummy parameters
            // Key requirement: Result MUST NOT be "Tool '...' is not registered."
            let result = await registry.execute(toolName: def.name, parameters: [:], context: context)
            if let err = result.errorDescription {
                XCTAssertFalse(err.contains("is not registered"), "Tool '\(def.name)' reported unregistered in dispatcher")
            }
        }
    }

    // MARK: - 5. Native Application Launching & Finder Integration

    func testNativeApplicationLaunchAndFinderTools() async throws {
        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            timeoutSeconds: 5.0,
            isInteractiveApprovalGranted: true
        )

        // Test open_folder_in_finder
        let finderResult = await registry.execute(
            toolName: "open_folder_in_finder",
            parameters: ["path": tempDirectory.path],
            context: context
        )
        XCTAssertTrue(finderResult.isSuccess, "open_folder_in_finder must succeed: \(finderResult.errorDescription ?? "")")

        // Test open_application with Finder (always present on macOS)
        let appResult = await registry.execute(
            toolName: "open_application",
            parameters: ["app_name": "Finder"],
            context: context
        )
        XCTAssertTrue(appResult.isSuccess, "open_application with Finder must succeed: \(appResult.errorDescription ?? "")")

        // Test activate_application with Finder
        let activateResult = await registry.execute(
            toolName: "activate_application",
            parameters: ["app_name": "Finder"],
            context: context
        )
        XCTAssertTrue(activateResult.isSuccess, "activate_application with Finder must succeed")
    }

    // MARK: - 6. Browser Navigation & URL Execution

    func testBrowserOpenURLAndNavigationTools() async throws {
        let mockBrowser = MockBrowserAutomationProvider()
        let browserSession = BrowserSessionManager(provider: mockBrowser, directoryManager: directoryManager)

        // Register custom session browser tools
        let customRegistry = ToolRegistry()
        await customRegistry.register(contentsOf: BrowserAutomationTools.allTools(sessionManager: browserSession))

        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            timeoutSeconds: 5.0,
            isInteractiveApprovalGranted: true
        )

        // Test open_url
        let openUrlResult = await customRegistry.execute(
            toolName: "open_url",
            parameters: ["url": "https://example.com"],
            context: context
        )
        XCTAssertTrue(openUrlResult.isSuccess, "open_url must succeed: \(openUrlResult.errorDescription ?? "")")
        let actions = await mockBrowser.executedActions
        XCTAssertTrue(actions.contains("open:https://example.com"))

        // Test navigate_browser
        let navResult = await customRegistry.execute(
            toolName: "navigate_browser",
            parameters: ["url": "https://developer.apple.com"],
            context: context
        )
        XCTAssertTrue(navResult.isSuccess)

        // Test browser_get_current_url
        let currentUrlResult = await customRegistry.execute(
            toolName: "browser_get_current_url",
            parameters: [:],
            context: context
        )
        XCTAssertTrue(currentUrlResult.isSuccess)
    }

    // MARK: - 7. Safe Calculator & Date/Time Execution

    func testSafeCalculatorAndDateTimeExecution() async {
        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            timeoutSeconds: 5.0,
            isInteractiveApprovalGranted: true
        )

        // 125 * 48 = 6000
        let calcResult = await registry.execute(
            toolName: "calculator",
            parameters: ["expression": "125 * 48"],
            context: context
        )
        XCTAssertTrue(calcResult.isSuccess)
        XCTAssertEqual(calcResult.output, "6000")

        // current_date_time
        let timeResult = await registry.execute(
            toolName: "current_date_time",
            parameters: [:],
            context: context
        )
        XCTAssertTrue(timeResult.isSuccess)
        XCTAssertTrue(timeResult.output.contains("ISO-8601"))
    }

    // MARK: - 8. Filesystem Authorization Management Workflow

    func testFilesystemPermissionManagementWorkflow() async throws {
        let mgr = AuthorizedDirectoryManager(restorePersistedBookmarks: false)

        // Initially empty
        var infos = await mgr.listAuthorizedDirectoryInfos()
        XCTAssertTrue(infos.isEmpty)

        // Authorize directory
        try await mgr.authorizeDirectory(url: tempDirectory)
        infos = await mgr.listAuthorizedDirectoryInfos()
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos.first?.path, tempDirectory.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertFalse(infos.first?.isReadOnly ?? true)

        // Toggle Read-Only
        await mgr.toggleReadOnly(for: tempDirectory)
        infos = await mgr.listAuthorizedDirectoryInfos()
        XCTAssertTrue(infos.first?.isReadOnly ?? false)

        // Toggle back to Read/Write
        await mgr.toggleReadOnly(for: tempDirectory)
        infos = await mgr.listAuthorizedDirectoryInfos()
        XCTAssertFalse(infos.first?.isReadOnly ?? true)

        // Revoke
        await mgr.revokeDirectory(url: tempDirectory)
        infos = await mgr.listAuthorizedDirectoryInfos()
        XCTAssertTrue(infos.isEmpty)

        // Error message when empty
        do {
            _ = try await mgr.validateAndResolve(path: "Desktop/TestFolder")
            XCTFail("Must fail closed when no roots authorized")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Aether Settings > Filesystem Permissions"))
        }
    }

    // MARK: - 9. New Filesystem Tools (edit_file, directory_tree, read_multiple_files)

    func testFilesystemNewToolsExecution() async throws {
        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            timeoutSeconds: 5.0,
            isInteractiveApprovalGranted: true
        )

        // 1. Create file with initial content
        let testFile = tempDirectory.appendingPathComponent("note.txt")
        try "Hello World from Aether".write(to: testFile, atomically: true, encoding: .utf8)

        // 2. Test edit_file
        let editRes = await registry.execute(
            toolName: "edit_file",
            parameters: [
                "path": testFile.path,
                "target": "World",
                "replacement": "macOS Agent"
            ],
            context: context
        )
        XCTAssertTrue(editRes.isSuccess, "edit_file should succeed: \(editRes.errorDescription ?? "")")
        let editedContent = try String(contentsOf: testFile, encoding: .utf8)
        XCTAssertEqual(editedContent, "Hello macOS Agent from Aether")

        // 3. Test directory_tree
        let treeRes = await registry.execute(
            toolName: "directory_tree",
            parameters: ["path": tempDirectory.path],
            context: context
        )
        XCTAssertTrue(treeRes.isSuccess, "directory_tree should succeed: \(treeRes.errorDescription ?? "")")
        XCTAssertTrue(treeRes.output.contains("note.txt"))

        // 4. Test read_multiple_files
        let secondFile = tempDirectory.appendingPathComponent("second.txt")
        try "Second file content".write(to: secondFile, atomically: true, encoding: .utf8)

        let multiRes = await registry.execute(
            toolName: "read_multiple_files",
            parameters: ["paths": "\(testFile.path), \(secondFile.path)"],
            context: context
        )
        XCTAssertTrue(multiRes.isSuccess, "read_multiple_files should succeed: \(multiRes.errorDescription ?? "")")
        XCTAssertTrue(multiRes.output.contains("Hello macOS Agent"))
        XCTAssertTrue(multiRes.output.contains("Second file content"))
    }

    // MARK: - 10. New Browser Tools Execution

    func testBrowserNewToolsExecution() async throws {
        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            timeoutSeconds: 5.0,
            isInteractiveApprovalGranted: true
        )

        // Test browser_hover
        let hoverRes = await registry.execute(
            toolName: "browser_hover",
            parameters: ["element_id": "el_search"],
            context: context
        )
        XCTAssertTrue(hoverRes.isSuccess)

        // Test browser_press_key
        let keyRes = await registry.execute(
            toolName: "browser_press_key",
            parameters: ["key": "Enter"],
            context: context
        )
        XCTAssertTrue(keyRes.isSuccess)

        // Test browser_get_html
        let htmlRes = await registry.execute(
            toolName: "browser_get_html",
            parameters: [:],
            context: context
        )
        XCTAssertTrue(htmlRes.isSuccess)

        // Test browser_evaluate
        let evalRes = await registry.execute(
            toolName: "browser_evaluate",
            parameters: ["script": "2 + 2"],
            context: context
        )
        XCTAssertTrue(evalRes.isSuccess)
    }

    // MARK: - 11. New Desktop Automation Tools Execution

    func testDesktopNewToolsExecution() async throws {
        let context = ToolExecutionContext(
            conversationId: UUID(),
            executionId: UUID(),
            timeoutSeconds: 5.0,
            isInteractiveApprovalGranted: true
        )

        // Test app_activate
        let actRes = await registry.execute(
            toolName: "app_activate",
            parameters: ["app_name": "TextEdit"],
            context: context
        )
        XCTAssertTrue(actRes.isSuccess)

        // Test app_inspect
        let inspectRes = await registry.execute(
            toolName: "app_inspect",
            parameters: ["app_name": "TextEdit"],
            context: context
        )
        XCTAssertTrue(inspectRes.isSuccess)

        // Test app_type
        let typeRes = await registry.execute(
            toolName: "app_type",
            parameters: ["text": "Automated note", "app_name": "TextEdit"],
            context: context
        )
        XCTAssertTrue(typeRes.isSuccess)

        // Test app_menu_click
        let menuRes = await registry.execute(
            toolName: "app_menu_click",
            parameters: ["menu_item": "Save", "app_name": "TextEdit"],
            context: context
        )
        XCTAssertTrue(menuRes.isSuccess)

        // Test app_dismiss_alert
        let alertRes = await registry.execute(
            toolName: "app_dismiss_alert",
            parameters: ["action": "OK", "app_name": "TextEdit"],
            context: context
        )
        XCTAssertTrue(alertRes.isSuccess)
    }
}

