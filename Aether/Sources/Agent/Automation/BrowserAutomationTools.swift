import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Browser Tool Suite Factory

public enum BrowserAutomationTools {
    public static func allTools(sessionManager: BrowserSessionManager = .shared) -> [any Tool] {
        [
            BrowserOpenTool(sessionManager: sessionManager),
            BrowserGetPageContentTool(sessionManager: sessionManager),
            BrowserGetPageMetadataTool(sessionManager: sessionManager),
            BrowserFindElementTool(sessionManager: sessionManager),
            BrowserClickTool(sessionManager: sessionManager),
            BrowserTypeTool(sessionManager: sessionManager),
            BrowserFillFormTool(sessionManager: sessionManager),
            BrowserScrollTool(sessionManager: sessionManager),
            BrowserGoBackTool(sessionManager: sessionManager),
            BrowserGoForwardTool(sessionManager: sessionManager),
            BrowserRefreshTool(sessionManager: sessionManager),
            BrowserGetScreenshotTool(sessionManager: sessionManager),
            BrowserListTabsTool(sessionManager: sessionManager),
            BrowserCloseTabTool(sessionManager: sessionManager),
            BrowserWaitForElementTool(sessionManager: sessionManager),
            OpenURLTool(sessionManager: sessionManager),
            NavigateBrowserTool(sessionManager: sessionManager),
            BrowserBackTool(sessionManager: sessionManager),
            BrowserForwardTool(sessionManager: sessionManager),
            BrowserGetCurrentURLTool(sessionManager: sessionManager),
            BrowserWaitForPageTool(sessionManager: sessionManager),
            BrowserNavigateAliasTool(sessionManager: sessionManager),
            BrowserHoverTool(sessionManager: sessionManager),
            BrowserPressKeyTool(sessionManager: sessionManager),
            BrowserSelectTool(sessionManager: sessionManager),
            BrowserExtractTool(sessionManager: sessionManager),
            BrowserGetTextTool(sessionManager: sessionManager),
            BrowserGetHTMLTool(sessionManager: sessionManager),
            BrowserWaitTool(sessionManager: sessionManager),
            BrowserScreenshotTool(sessionManager: sessionManager),
            BrowserEvaluateTool(sessionManager: sessionManager),
            BrowserCloseTool(sessionManager: sessionManager)
        ]
    }
}

// MARK: - 1. browser_open

public struct BrowserOpenTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_open",
            description: "Navigates the browser to the specified web URL.",
            parameters: [
                ToolParameter(name: "url", type: .string, description: "Full destination URL starting with http:// or https://", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let urlStr = parameters["url"], let url = URL(string: urlStr) else {
            return .failure(toolName: definition.name, error: "Missing or invalid 'url' parameter.")
        }
        let startTime = Date()
        do {
            let meta = try await sessionManager.open(url: url)
            let duration = Date().timeIntervalSince(startTime)
            let output = """
            Successfully opened '\(meta.url)'
            Title: \(meta.title)
            \(meta.pageDescription != nil ? "Description: \(meta.pageDescription!)" : "")
            """
            return .success(toolName: definition.name, output: output, duration: duration, metadata: ["url": meta.url, "title": meta.title])
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 2. browser_get_page_content

public struct BrowserGetPageContentTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_get_page_content",
            description: "Extracts readable text or semantic markdown content from the currently open webpage.",
            parameters: [
                ToolParameter(name: "format", type: .string, description: "Output format: 'markdown' (structured with links/buttons) or 'text'", isRequired: false, defaultValue: "markdown", allowedValues: ["markdown", "text"]),
                ToolParameter(name: "max_length", type: .integer, description: "Maximum characters to return to conserve context budget", isRequired: false, defaultValue: "4000")
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let format = parameters["format"] ?? "markdown"
        let maxLen = parameters["max_length"].flatMap { Int($0) } ?? 4000
        let startTime = Date()

        do {
            let content = try await sessionManager.getPageContent(format: format, maxLength: maxLen)
            let duration = Date().timeIntervalSince(startTime)
            return .success(toolName: definition.name, output: content, duration: duration, metadata: ["format": format, "length": "\(content.count)"])
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 3. browser_get_page_metadata

public struct BrowserGetPageMetadataTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_get_page_metadata",
            description: "Retrieves title, current URL, and metadata from the loaded webpage.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        do {
            let meta = try await sessionManager.getPageMetadata()
            let output = """
            Title: \(meta.title)
            URL: \(meta.url)
            Status: \(meta.statusCode ?? 200)
            \(meta.pageDescription != nil ? "Description: \(meta.pageDescription!)" : "")
            """
            return .success(toolName: definition.name, output: output, metadata: ["title": meta.title, "url": meta.url])
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 4. browser_find_element

public struct BrowserFindElementTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_find_element",
            description: "Finds interactive elements on the webpage matching a query by text, accessible label, role, or CSS selector.",
            parameters: [
                ToolParameter(name: "query", type: .string, description: "Text, label, or selector to search for", isRequired: true),
                ToolParameter(name: "by", type: .string, description: "Search strategy: 'text', 'label', 'role', 'css', or 'xpath'", isRequired: false, defaultValue: "text", allowedValues: ["text", "label", "role", "css", "xpath"])
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let query = parameters["query"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'query'.")
        }
        let by = parameters["by"] ?? "text"

        do {
            let elements = try await sessionManager.findElement(query: query, by: by)
            if elements.isEmpty {
                return .success(toolName: definition.name, output: "No interactive elements found matching '\(query)' using strategy '\(by)'.")
            }

            var lines = ["Discovered \(elements.count) matching element(s):"]
            for el in elements {
                let clickStr = el.isClickable ? " [Clickable]" : ""
                let inputStr = el.isInput ? " [Input]" : ""
                lines.append("- ID: \(el.id) | <\(el.tagName)> \(el.text)\(clickStr)\(inputStr)")
            }
            return .success(toolName: definition.name, output: lines.joined(separator: "\n"))
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 5. browser_click

public struct BrowserClickTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_click",
            description: "Clicks an identified element on the webpage (using element_id returned from browser_find_element).",
            parameters: [
                ToolParameter(name: "element_id", type: .string, description: "The element ID, name, or text to click", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let elementId = parameters["element_id"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'element_id'.")
        }

        do {
            let result = try await sessionManager.click(elementId: elementId)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 6. browser_type

public struct BrowserTypeTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_type",
            description: "Enters text into an identified input element or the active focused field.",
            parameters: [
                ToolParameter(name: "text", type: .string, description: "Text content to type into the field", isRequired: true),
                ToolParameter(name: "element_id", type: .string, description: "Optional target element ID. If omitted, types into currently focused element", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let text = parameters["text"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'text'.")
        }
        let elementId = parameters["element_id"]

        do {
            let result = try await sessionManager.typeText(text: text, elementId: elementId)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 7. browser_fill_form

public struct BrowserFillFormTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_fill_form",
            description: "Fills multiple form fields in a single operation using a JSON object of field_name: value pairs.",
            parameters: [
                ToolParameter(name: "fields", type: .string, description: "JSON string mapping field names/placeholders to values, e.g. {\"username\": \"alice\", \"email\": \"alice@example.com\"}", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .userConfirmationRequired
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let fieldsJson = parameters["fields"],
              let data = fieldsJson.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return .failure(toolName: definition.name, error: "Parameter 'fields' must be a valid JSON dictionary of strings.")
        }

        do {
            let result = try await sessionManager.fillForm(fields: dict)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 8. browser_scroll

public struct BrowserScrollTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_scroll",
            description: "Scrolls the webpage in the specified direction.",
            parameters: [
                ToolParameter(name: "direction", type: .string, description: "Direction to scroll: 'up', 'down', 'top', or 'bottom'", isRequired: true, allowedValues: ["up", "down", "top", "bottom"]),
                ToolParameter(name: "amount", type: .integer, description: "Pixels to scroll (default 500)", isRequired: false, defaultValue: "500")
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let dirStr = parameters["direction"], let dir = BrowserScrollDirection(rawValue: dirStr.lowercased()) else {
            return .failure(toolName: definition.name, error: "Missing or invalid 'direction' parameter. Allowed: up, down, top, bottom.")
        }
        let amount = parameters["amount"].flatMap { Int($0) }

        do {
            let result = try await sessionManager.scroll(direction: dir, amount: amount)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 9. browser_go_back

public struct BrowserGoBackTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_go_back",
            description: "Navigates backward in browser history.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        do {
            let meta = try await sessionManager.goBack()
            return .success(toolName: definition.name, output: "Navigated back to '\(meta.title)' (\(meta.url)).")
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 10. browser_go_forward

public struct BrowserGoForwardTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_go_forward",
            description: "Navigates forward in browser history.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        do {
            let meta = try await sessionManager.goForward()
            return .success(toolName: definition.name, output: "Navigated forward to '\(meta.title)' (\(meta.url)).")
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 11. browser_refresh

public struct BrowserRefreshTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_refresh",
            description: "Refreshes the current webpage.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        do {
            let meta = try await sessionManager.refresh()
            return .success(toolName: definition.name, output: "Refreshed '\(meta.title)' (\(meta.url)).")
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 12. browser_get_screenshot

public struct BrowserGetScreenshotTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_get_screenshot",
            description: "Captures a visual snapshot of the webpage for inspection.",
            parameters: [
                ToolParameter(name: "save_path", type: .string, description: "Optional local file path to save PNG image file", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let savePath = parameters["save_path"]
        do {
            let result = try await sessionManager.takeScreenshot(savePath: savePath)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 13. browser_list_tabs

public struct BrowserListTabsTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_list_tabs",
            description: "Lists all open browser tabs managed by Aether.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        do {
            let tabs = try await sessionManager.listTabs()
            if tabs.isEmpty {
                return .success(toolName: definition.name, output: "No browser tabs are currently open.")
            }
            var lines = ["Open browser tabs (\(tabs.count)):"]
            for tab in tabs {
                let activeStr = tab.isActive ? " [Active]" : ""
                lines.append("- [\(tab.id.uuidString)] '\(tab.title)' -> \(tab.url)\(activeStr)")
            }
            return .success(toolName: definition.name, output: lines.joined(separator: "\n"))
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 14. browser_close_tab

public struct BrowserCloseTabTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_close_tab",
            description: "Closes a specific browser tab or the active tab.",
            parameters: [
                ToolParameter(name: "tab_id", type: .string, description: "UUID of tab to close. If omitted, closes active tab", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let tabId = parameters["tab_id"].flatMap { UUID(uuidString: $0) }
        do {
            let result = try await sessionManager.closeTab(tabId: tabId)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 15. browser_wait_for_element

public struct BrowserWaitForElementTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_wait_for_element",
            description: "Waits until a specific element selector appears in the DOM within a bounded timeout.",
            parameters: [
                ToolParameter(name: "selector", type: .string, description: "CSS selector of element to wait for", isRequired: true),
                ToolParameter(name: "timeout_seconds", type: .number, description: "Maximum seconds to wait (default 5.0)", isRequired: false, defaultValue: "5.0")
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let selector = parameters["selector"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'selector'.")
        }
        let timeout = parameters["timeout_seconds"].flatMap { Double($0) } ?? 5.0

        do {
            let found = try await sessionManager.waitForElement(selector: selector, timeoutSeconds: timeout)
            if found {
                return .success(toolName: definition.name, output: "Element matching '\(selector)' appeared in DOM.")
            } else {
                return .failure(toolName: definition.name, error: "Timed out waiting for element '\(selector)' after \(timeout)s.")
            }
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 16. open_url

public struct OpenURLTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "open_url",
            description: "Opens a web URL in the browser (supports in-app WebKit browser or Safari).",
            parameters: [
                ToolParameter(name: "url", type: .string, description: "Full destination URL starting with http:// or https:// (e.g. 'https://www.google.com').", isRequired: true),
                ToolParameter(name: "browser", type: .string, description: "Target browser: 'in-app' (programmatic WebKit session) or 'Safari' (macOS system browser).", isRequired: false, defaultValue: "in-app", allowedValues: ["in-app", "Safari", "default"])
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let urlStr = parameters["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure(toolName: definition.name, error: "Invalid URL '\(parameters["url"] ?? "")'. Only http:// and https:// URLs are supported.")
        }

        let targetBrowser = parameters["browser"]?.lowercased() ?? "in-app"

        if targetBrowser == "safari" || targetBrowser == "default" || targetBrowser == "system" {
            #if canImport(AppKit)
            let opened = NSWorkspace.shared.open(url)
            if opened {
                return .success(toolName: definition.name, output: "Successfully opened URL '\(url.absoluteString)' in Safari.", metadata: ["url": url.absoluteString, "browser": "Safari"])
            } else {
                return .failure(toolName: definition.name, error: "Failed to open URL in Safari.")
            }
            #else
            return .failure(toolName: definition.name, error: "AppKit is unavailable on this platform.")
            #endif
        }

        let startTime = Date()
        do {
            let meta = try await sessionManager.open(url: url)
            let duration = Date().timeIntervalSince(startTime)
            let output = """
            Successfully opened '\(meta.url)'
            Title: \(meta.title)
            \(meta.pageDescription != nil ? "Description: \(meta.pageDescription!)" : "")
            """
            return .success(toolName: definition.name, output: output, duration: duration, metadata: ["url": meta.url, "title": meta.title])
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 17. navigate_browser

public struct NavigateBrowserTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "navigate_browser",
            description: "Navigates the browser to the specified web URL.",
            parameters: [
                ToolParameter(name: "url", type: .string, description: "Full destination URL starting with http:// or https://", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await BrowserOpenTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 18. browser_back

public struct BrowserBackTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_back",
            description: "Navigates back to the previous webpage in browser history.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await BrowserGoBackTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 19. browser_forward

public struct BrowserForwardTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_forward",
            description: "Navigates forward to the next webpage in browser history.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await BrowserGoForwardTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 20. browser_get_current_url

public struct BrowserGetCurrentURLTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_get_current_url",
            description: "Retrieves the current loaded URL and page title in the active browser tab.",
            parameters: [],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        do {
            let meta = try await sessionManager.getPageMetadata()
            let output = "Current URL: \(meta.url)\nTitle: \(meta.title)"
            return .success(toolName: definition.name, output: output, metadata: ["url": meta.url, "title": meta.title])
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 21. browser_wait_for_page

public struct BrowserWaitForPageTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_wait_for_page",
            description: "Waits for the active webpage to complete loading or rendering.",
            parameters: [
                ToolParameter(name: "timeout_seconds", type: .number, description: "Maximum seconds to wait (default: 5.0, max: 30.0)", isRequired: false, defaultValue: "5.0")
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let timeout = min(30.0, max(1.0, parameters["timeout_seconds"].flatMap { Double($0) } ?? 5.0))
        do {
            try await Task.sleep(nanoseconds: UInt64(min(timeout, 2.0) * 1_000_000_000))
            let meta = try await sessionManager.getPageMetadata()
            return .success(toolName: definition.name, output: "Page ready: '\(meta.title)' (\(meta.url)).", metadata: ["url": meta.url])
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 22. browser_navigate

public struct BrowserNavigateAliasTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_navigate",
            description: "Navigates the browser to the specified web URL.",
            parameters: [
                ToolParameter(name: "url", type: .string, description: "Full destination URL starting with http:// or https://", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await BrowserOpenTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 23. browser_hover

public struct BrowserHoverTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_hover",
            description: "Moves mouse cursor over an interactive element on the webpage (dispatches mouseover/mouseenter events).",
            parameters: [
                ToolParameter(name: "element_id", type: .string, description: "Element ID to hover over", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let elementId = parameters["element_id"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'element_id'.")
        }
        do {
            let result = try await sessionManager.hover(elementId: elementId)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 24. browser_press_key

public struct BrowserPressKeyTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_press_key",
            description: "Dispatches a keyboard key event (e.g. 'Enter', 'Tab', 'Escape', 'ArrowDown') to an identified element or active element.",
            parameters: [
                ToolParameter(name: "key", type: .string, description: "Key name to press (e.g. 'Enter', 'Tab', 'Escape')", isRequired: true),
                ToolParameter(name: "element_id", type: .string, description: "Optional target element ID. If omitted, sends to focused element", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let key = parameters["key"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'key'.")
        }
        let elementId = parameters["element_id"]
        do {
            let result = try await sessionManager.pressKey(key: key, elementId: elementId)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 25. browser_select

public struct BrowserSelectTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_select",
            description: "Selects an option in a <select> dropdown element by value or text.",
            parameters: [
                ToolParameter(name: "element_id", type: .string, description: "Select element ID", isRequired: true),
                ToolParameter(name: "value", type: .string, description: "Option value or visible text to select", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let elementId = parameters["element_id"], let value = parameters["value"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'element_id' or 'value'.")
        }
        do {
            let result = try await sessionManager.selectOption(elementId: elementId, value: value)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 26. browser_extract

public struct BrowserExtractTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_extract",
            description: "Extracts readable text or structured markdown content from the loaded webpage.",
            parameters: [
                ToolParameter(name: "format", type: .string, description: "Output format: 'markdown' or 'text'", isRequired: false, defaultValue: "markdown", allowedValues: ["markdown", "text"]),
                ToolParameter(name: "max_length", type: .integer, description: "Max characters to return", isRequired: false, defaultValue: "4000")
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await BrowserGetPageContentTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 27. browser_get_text

public struct BrowserGetTextTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_get_text",
            description: "Extracts plain text content from the current webpage body.",
            parameters: [
                ToolParameter(name: "max_length", type: .integer, description: "Max characters to return", isRequired: false, defaultValue: "4000")
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        var params = parameters
        params["format"] = "text"
        return try await BrowserGetPageContentTool(sessionManager: sessionManager).execute(parameters: params, context: context)
    }
}

// MARK: - 28. browser_get_html

public struct BrowserGetHTMLTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_get_html",
            description: "Retrieves raw HTML source for the entire document or a specific element selector.",
            parameters: [
                ToolParameter(name: "selector", type: .string, description: "Optional CSS selector to scope HTML extraction", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let selector = parameters["selector"]
        do {
            let html = try await sessionManager.getHTML(selector: selector)
            let truncated = html.count > 10000 ? String(html.prefix(10000)) + "\n... [Truncated at 10,000 chars]" : html
            return .success(toolName: definition.name, output: truncated, metadata: ["length": "\(html.count)"])
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 29. browser_wait

public struct BrowserWaitTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_wait",
            description: "Waits for a webpage condition: either element appearance or page stabilization timeout.",
            parameters: [
                ToolParameter(name: "selector", type: .string, description: "Optional CSS selector of element to wait for", isRequired: false),
                ToolParameter(name: "timeout_seconds", type: .number, description: "Maximum seconds to wait (default 5.0)", isRequired: false, defaultValue: "5.0")
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        if let sel = parameters["selector"], !sel.isEmpty {
            return try await BrowserWaitForElementTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
        } else {
            return try await BrowserWaitForPageTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
        }
    }
}

// MARK: - 30. browser_screenshot

public struct BrowserScreenshotTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_screenshot",
            description: "Captures a visual screenshot of the current active webpage.",
            parameters: [
                ToolParameter(name: "save_path", type: .string, description: "Optional file path to save PNG", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await BrowserGetScreenshotTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 31. browser_evaluate

public struct BrowserEvaluateTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_evaluate",
            description: "Evaluates custom JavaScript expression in the context of the active webpage.",
            parameters: [
                ToolParameter(name: "script", type: .string, description: "JavaScript code string to evaluate", isRequired: true)
            ],
            category: .browser,
            permissionLevel: .userConfirmationRequired
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let script = parameters["script"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'script'.")
        }
        do {
            let result = try await sessionManager.evaluate(script: script)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 32. browser_close

public struct BrowserCloseTool: Tool, Sendable {
    public let sessionManager: BrowserSessionManager

    public init(sessionManager: BrowserSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_close",
            description: "Closes the active browser tab or specified tab ID.",
            parameters: [
                ToolParameter(name: "tab_id", type: .string, description: "Optional tab ID to close", isRequired: false)
            ],
            category: .browser,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await BrowserCloseTabTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

