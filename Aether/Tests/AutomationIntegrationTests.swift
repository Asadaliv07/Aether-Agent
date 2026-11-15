import XCTest
@testable import Aether

final class AutomationIntegrationTests: XCTestCase {
    private var securityGuard: ToolSecurityGuard!
    private var toolRegistry: ToolRegistry!
    private var mockBrowser: MockBrowserAutomationProvider!
    private var browserSessionManager: BrowserSessionManager!
    private var mockDesktop: MockDesktopAutomationProvider!
    private var desktopSessionManager: ApplicationSessionManager!

    private var candidateModelPath: String? {
        let candidates = [
            "/Users/asadalishaikh/Desktop/qwen2.5-coder/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463",
            "/Users/asadalishaikh/.ollama/models/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463"
        ]
        return candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
    }

    override func setUp() async throws {
        try await super.setUp()

        securityGuard = ToolSecurityGuard()
        toolRegistry = ToolRegistry(securityGuard: securityGuard)

        mockBrowser = MockBrowserAutomationProvider()
        browserSessionManager = BrowserSessionManager(provider: mockBrowser)

        mockDesktop = MockDesktopAutomationProvider()
        desktopSessionManager = ApplicationSessionManager(provider: mockDesktop)

        // Register all browser tools
        for tool in BrowserAutomationTools.allTools(sessionManager: browserSessionManager) {
            await toolRegistry.register(tool)
        }

        // Register all desktop application tools
        for tool in DesktopAutomationTools.allTools(sessionManager: desktopSessionManager) {
            await toolRegistry.register(tool)
        }
    }

    // MARK: - 1. Registration & Schema Validation Tests

    func testAllBrowserAndDesktopToolsRegistered() async {
        let count = (await toolRegistry.definitions).count
        XCTAssertGreaterThanOrEqual(count, 28, "All 15 browser tools and 13 desktop application tools must be registered.")

        let expectedBrowserTools = [
            "browser_open", "browser_get_page_content", "browser_get_page_metadata",
            "browser_find_element", "browser_click", "browser_type", "browser_fill_form",
            "browser_scroll", "browser_go_back", "browser_go_forward", "browser_refresh",
            "browser_get_screenshot", "browser_list_tabs", "browser_close_tab", "browser_wait_for_element"
        ]

        for name in expectedBrowserTools {
            let tool = await await toolRegistry.tool(named: name)
            XCTAssertNotNil(tool, "Browser tool '\(name)' must be registered.")
            XCTAssertEqual(tool?.definition.category, .browser)
            let schema = tool?.definition.toJSONSchema()
            XCTAssertEqual(schema?["name"] as? String, name)
        }

        let expectedDesktopTools = [
            "app_list_running", "app_get_frontmost", "app_launch", "app_get_windows",
            "app_get_accessibility_tree", "app_find_element", "app_click", "app_type_text",
            "app_press_key", "app_scroll", "app_get_element_value", "app_set_element_value",
            "app_capture_screenshot"
        ]

        for name in expectedDesktopTools {
            let tool = await await toolRegistry.tool(named: name)
            XCTAssertNotNil(tool, "Desktop tool '\(name)' must be registered.")
            XCTAssertEqual(tool?.definition.category, .desktopApp)
            let schema = tool?.definition.toJSONSchema()
            XCTAssertEqual(schema?["name"] as? String, name)
        }
    }

    // MARK: - 2. SecurityGuard & Parameter Validation Tests

    func testBrowserURLValidationInSecurityGuard() async {
        let openTool = await toolRegistry.tool(named: "browser_open")!

        // 1. Allowed https scheme
        let decisionValid = await securityGuard.authorize(
            tool: openTool.definition,
            parameters: ["url": "https://en.wikipedia.org"],
            context: ToolExecutionContext()
        )
        XCTAssertEqual(decisionValid, .authorized)

        // 2. Disallowed file scheme
        let decisionFile = await securityGuard.authorize(
            tool: openTool.definition,
            parameters: ["url": "file:///etc/passwd"],
            context: ToolExecutionContext()
        )
        if case .denied(let reason) = decisionFile {
            XCTAssertTrue(reason.contains("Unsafe browser URL scheme"), "Must reject file scheme: \(reason)")
        } else {
            XCTFail("file:// scheme must be denied, got: \(decisionFile)")
        }

        // 3. Disallowed javascript scheme
        let decisionJS = await securityGuard.authorize(
            tool: openTool.definition,
            parameters: ["url": "javascript:alert(1)"],
            context: ToolExecutionContext()
        )
        if case .denied(let reason) = decisionJS {
            XCTAssertTrue(reason.contains("Unsafe browser URL scheme"), "Must reject javascript scheme: \(reason)")
        } else {
            XCTFail("javascript: scheme must be denied, got: \(decisionJS)")
        }

        // 4. Disallowed private cloud metadata IP
        let decisionMetadata = await securityGuard.authorize(
            tool: openTool.definition,
            parameters: ["url": "http://169.254.169.254/latest/meta-data"],
            context: ToolExecutionContext()
        )
        if case .denied(let reason) = decisionMetadata {
            XCTAssertTrue(reason.contains("metadata"), "Must reject metadata IP: \(reason)")
        } else {
            XCTFail("Metadata service URL must be denied, got: \(decisionMetadata)")
        }
    }

    func testDesktopApplicationWhitelistInSecurityGuard() async {
        let launchTool = await toolRegistry.tool(named: "app_launch")!

        // 1. Allowed applications
        for app in ["TextEdit", "Finder", "Safari", "Notes", "System Settings"] {
            let decision = await securityGuard.authorize(
                tool: launchTool.definition,
                parameters: ["app_name": app],
                context: ToolExecutionContext()
            )
            XCTAssertEqual(decision, .authorized, "\(app) must be authorized.")
        }

        // 2. Disallowed applications
        for banned in ["Terminal", "bash", "curl", "rm"] {
            let decision = await securityGuard.authorize(
                tool: launchTool.definition,
                parameters: ["app_name": banned],
                context: ToolExecutionContext()
            )
            if case .denied(let reason) = decision {
                XCTAssertTrue(reason.contains("whitelist"), "Must reject \(banned): \(reason)")
            } else {
                XCTFail("Banned app '\(banned)' must be denied, got: \(decision)")
            }
        }
    }

    // MARK: - 3. Mock Browser Automation End-to-End Tests

    func testBrowserOpenAndMetadataRetrieval() async throws {
        let openTool = await toolRegistry.tool(named: "browser_open")!
        let result = try await openTool.execute(
            parameters: ["url": "https://en.wikipedia.org/wiki/Swift_(programming_language)"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.output.contains("Swift (programming language)"))

        let metaTool = await toolRegistry.tool(named: "browser_get_page_metadata")!
        let metaResult = try await metaTool.execute(parameters: [:], context: ToolExecutionContext())
        XCTAssertTrue(metaResult.isSuccess)
        XCTAssertTrue(metaResult.output.contains("Title: Swift (programming language) - Wikipedia"))
    }

    func testBrowserPageContentExtraction() async throws {
        let contentTool = await toolRegistry.tool(named: "browser_get_page_content")!

        // Markdown format
        let mdResult = try await contentTool.execute(
            parameters: ["format": "markdown", "max_length": "500"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(mdResult.isSuccess)
        XCTAssertTrue(mdResult.output.contains("# Swift (programming language)"))
        XCTAssertTrue(mdResult.output.contains("[Installation Guide]"))

        // Length clamping
        let clampedResult = try await contentTool.execute(
            parameters: ["format": "markdown", "max_length": "20"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(clampedResult.isSuccess)
        XCTAssertTrue(clampedResult.output.contains("[Truncated]"))
    }

    func testBrowserFindAndClickElement() async throws {
        let findTool = await toolRegistry.tool(named: "browser_find_element")!
        let findResult = try await findTool.execute(
            parameters: ["query": "Installation Guide", "by": "text"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(findResult.isSuccess)
        XCTAssertTrue(findResult.output.contains("el_install_link"))

        let clickTool = await toolRegistry.tool(named: "browser_click")!
        let clickResult = try await clickTool.execute(
            parameters: ["element_id": "el_install_link"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(clickResult.isSuccess)
        XCTAssertTrue(clickResult.output.contains("Clicked a 'Installation Guide'"))

        // Verify navigation happened from clicking the link
        let meta = try await mockBrowser.getPageMetadata()
        XCTAssertEqual(meta.url, "https://swift.org/install")
    }

    func testBrowserTypeAndFillForm() async throws {
        let typeTool = await toolRegistry.tool(named: "browser_type")!
        let typeResult = try await typeTool.execute(
            parameters: ["text": "Swift concurrency", "element_id": "el_search"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(typeResult.isSuccess)
        XCTAssertTrue(typeResult.output.contains("Swift concurrency"))

        let formTool = await toolRegistry.tool(named: "browser_fill_form")!
        let formResult = try await formTool.execute(
            parameters: ["fields": "{\"username\": \"aether_tester\", \"query\": \"actors\"}"],
            context: ToolExecutionContext(isInteractiveApprovalGranted: true)
        )
        XCTAssertTrue(formResult.isSuccess)
        XCTAssertTrue(formResult.output.contains("username=aether_tester"))
    }

    func testBrowserScrollHistoryAndTabs() async throws {
        // Scroll
        let scrollTool = await toolRegistry.tool(named: "browser_scroll")!
        let scrollResult = try await scrollTool.execute(
            parameters: ["direction": "down", "amount": "400"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(scrollResult.isSuccess)
        XCTAssertTrue(scrollResult.output.contains("Scrolled down by 400px."))

        // History back
        let backTool = await toolRegistry.tool(named: "browser_go_back")!
        let backResult = try await backTool.execute(parameters: [:], context: ToolExecutionContext())
        XCTAssertTrue(backResult.isSuccess)

        // List tabs
        let tabsTool = await toolRegistry.tool(named: "browser_list_tabs")!
        let tabsResult = try await tabsTool.execute(parameters: [:], context: ToolExecutionContext())
        XCTAssertTrue(tabsResult.isSuccess)
        XCTAssertTrue(tabsResult.output.contains("Open browser tabs"))
    }

    func testBrowserWaitForElementBoundedTimeout() async throws {
        let waitTool = await toolRegistry.tool(named: "browser_wait_for_element")!

        // 1. Existing element
        let successResult = try await waitTool.execute(
            parameters: ["selector": "el_search", "timeout_seconds": "1.0"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(successResult.isSuccess)

        // 2. Missing element with timeout
        await mockBrowser.setCustomContent(title: "Empty", url: "https://empty.test", content: "None", elements: [])
        let failResult = try await waitTool.execute(
            parameters: ["selector": "nonexistent_selector", "timeout_seconds": "0.1"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(failResult.isSuccess)
        XCTAssertTrue(failResult.errorDescription?.contains("Timed out") == true)
    }

    // MARK: - 4. Mock Desktop Application Automation Tests

    func testDesktopAppListRunningAndFrontmost() async throws {
        let listTool = await toolRegistry.tool(named: "app_list_running")!
        let listResult = try await listTool.execute(parameters: ["filter": "TextEdit"], context: ToolExecutionContext())
        XCTAssertTrue(listResult.isSuccess)
        XCTAssertTrue(listResult.output.contains("TextEdit"))

        let frontTool = await toolRegistry.tool(named: "app_get_frontmost")!
        let frontResult = try await frontTool.execute(parameters: [:], context: ToolExecutionContext())
        XCTAssertTrue(frontResult.isSuccess)
        XCTAssertTrue(frontResult.output.contains("TextEdit"))
    }

    func testDesktopAppLaunchAndWindowInspection() async throws {
        let launchTool = await toolRegistry.tool(named: "app_launch")!
        let launchResult = try await launchTool.execute(parameters: ["app_name": "Finder"], context: ToolExecutionContext())
        XCTAssertTrue(launchResult.isSuccess)
        XCTAssertTrue(launchResult.output.contains("Finder"))

        let winTool = await toolRegistry.tool(named: "app_get_windows")!
        let winResult = try await winTool.execute(parameters: ["app_name": "TextEdit"], context: ToolExecutionContext())
        XCTAssertTrue(winResult.isSuccess)
        XCTAssertTrue(winResult.output.contains("Untitled"))
    }

    func testDesktopAppAccessibilityTreeAndElementSearch() async throws {
        let treeTool = await toolRegistry.tool(named: "app_get_accessibility_tree")!
        let treeResult = try await treeTool.execute(parameters: ["app_name": "TextEdit"], context: ToolExecutionContext())
        XCTAssertTrue(treeResult.isSuccess)
        XCTAssertTrue(treeResult.output.contains("AXTextArea"))
        XCTAssertTrue(treeResult.output.contains("AXButton"))

        let findTool = await toolRegistry.tool(named: "app_find_element")!
        let findResult = try await findTool.execute(parameters: ["query": "Save", "app_name": "TextEdit"], context: ToolExecutionContext())
        XCTAssertTrue(findResult.isSuccess)
        XCTAssertTrue(findResult.output.contains("ax_btn_save"))
    }

    func testDesktopAppTypeTextClickAndKey() async throws {
        let typeTool = await toolRegistry.tool(named: "app_type_text")!
        let typeResult = try await typeTool.execute(
            parameters: ["text": "Aether desktop automation test", "app_name": "TextEdit"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(typeResult.isSuccess)
        XCTAssertTrue(typeResult.output.contains("Aether desktop automation test"))

        let valTool = await toolRegistry.tool(named: "app_get_element_value")!
        let valResult = try await valTool.execute(parameters: ["element_id": "ax_textarea_1"], context: ToolExecutionContext())
        XCTAssertTrue(valResult.isSuccess)
        XCTAssertEqual(valResult.output, "Aether desktop automation test")

        let keyTool = await toolRegistry.tool(named: "app_press_key")!
        let keyResult = try await keyTool.execute(parameters: ["key": "return", "app_name": "TextEdit"], context: ToolExecutionContext())
        XCTAssertTrue(keyResult.isSuccess)
        XCTAssertTrue(keyResult.output.contains("return"))

        let clickTool = await toolRegistry.tool(named: "app_click")!
        let clickResult = try await clickTool.execute(parameters: ["element_id": "ax_btn_save"], context: ToolExecutionContext())
        XCTAssertTrue(clickResult.isSuccess)
    }

    func testDesktopAppPermissionDenialHandling() async throws {
        // Set mock to simulate missing Accessibility permission
        await mockDesktop.setThrowPermissionRequired(true)

        let treeTool = await toolRegistry.tool(named: "app_get_accessibility_tree")!
        let treeResult = try await treeTool.execute(parameters: ["app_name": "TextEdit"], context: ToolExecutionContext())
        XCTAssertFalse(treeResult.isSuccess)
        XCTAssertTrue(treeResult.errorDescription?.contains("Permission") == true)
    }

    // MARK: - 5. Real WebKit Native Browser Integration Test

    func testRealWebKitBrowserProvider() async throws {
        let webkitProvider = await WebKitBrowserAutomationProvider.shared

        // Open local about:blank or simple public webpage
        let meta = try await webkitProvider.open(url: URL(string: "https://example.com")!)
        XCTAssertEqual(meta.statusCode, 200)
        XCTAssertFalse(meta.title.isEmpty)

        // Read page content
        let content = try await webkitProvider.getPageContent(format: "markdown", maxLength: 2000)
        XCTAssertTrue(content.localizedCaseInsensitiveContains("Example Domain") || content.localizedCaseInsensitiveContains("Example"))

        // Find elements
        let elements = try await webkitProvider.findElement(query: "Example", by: "text")
        XCTAssertFalse(elements.isEmpty, "Should find at least one element containing 'Example'.")

        // Capture screenshot
        let screenshotResult = try await webkitProvider.takeScreenshot(savePath: nil)
        XCTAssertTrue(screenshotResult.contains("Captured page snapshot"))
    }

    // MARK: - 6. Real Model End-to-End Scenarios (Qwen 2.5 Coder 7B)

    /// Scenario A & B — Open a website and search information using the real LLM
    func testRealModel_BrowserOpenAndSearch() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 8192, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether, an intelligent AI assistant with real browser automation capabilities."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 3)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Open Wikipedia in Aether's browser.",
            conversationId: UUID(),
            inferenceProvider: provider
        )
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "browser_open")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "open_url")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "browser_navigate")

        let state = await loop.run()

        // 1. Verify model proposed browser_open or open_url
        let openSteps = state.history.filter { step in
            if case .callTool(let name, _, _) = step.action {
                return name == "browser_open" || name == "open_url" || name == "browser_navigate"
            }
            return false
        }
        XCTAssertFalse(openSteps.isEmpty, "Model must propose invoking browser_open or open_url.")

        // 2. Verify observation feedback and completion
        if let answer = state.finalAnswer {
            XCTAssertTrue(answer.localizedCaseInsensitiveContains("Wikipedia") || answer.localizedCaseInsensitiveContains("opened"),
                          "Model must confirm website opening based on real tool observation: \(answer)")
        }
    }

    /// Scenario D — Launch TextEdit and enter text using the real LLM
    func testRealModel_DesktopAppTextEdit() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        let provider = ProductionAgentInferenceProvider(
            inferenceService: service,
            configuration: GenerationConfiguration(contextLength: 8192, maxTokens: 256, temperature: 0.0),
            baseSystemPrompt: "You are Aether. You have desktop application automation tools."
        )

        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard, maxSteps: 4)
        let loop = await orchestrator.createExecutionLoop(
            goal: "Open TextEdit and type 'Aether desktop automation test' into the document.",
            conversationId: UUID(),
            inferenceProvider: provider
        )
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "app_launch")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "app_type_text")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "open_application")
        await securityGuard.grantSessionPermission(conversationId: loop.state.conversationId, toolName: "activate_application")

        let state = await loop.run()

        let appSteps = state.history.filter { step in
            if case .callTool(let name, _, _) = step.action {
                return name == "app_launch" || name == "app_type_text" || name == "open_application" || name == "activate_application"
            }
            return false
        }
        XCTAssertFalse(appSteps.isEmpty, "Model must invoke desktop automation tools.")
    }
}

// Extension to allow test toggles on MockDesktopAutomationProvider
extension MockDesktopAutomationProvider {
    func setThrowPermissionRequired(_ throwErr: Bool) {
        self.shouldThrowPermissionRequired = throwErr
    }
}
