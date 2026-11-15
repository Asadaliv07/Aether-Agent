import Foundation

/// Defines the contract for browser automation backends (e.g. WebKit WKWebView or in-memory test mocks).
public protocol BrowserAutomationProvider: Sendable {
    /// Navigates the current tab to a specified URL.
    func open(url: URL) async throws -> BrowserPageMetadata

    /// Extracts structured text or semantic markdown content from the loaded page.
    func getPageContent(format: String, maxLength: Int?) async throws -> String

    /// Retrieves current page title, URL, description, and status metadata.
    func getPageMetadata() async throws -> BrowserPageMetadata

    /// Discovers interactive elements matching query by label, role, text, or CSS selector.
    func findElement(query: String, by: String) async throws -> [BrowserElementInfo]

    /// Clicks an identified interactive element and returns post-click state summary.
    func click(elementId: String) async throws -> String

    /// Types text into an identified input element or the active focused element.
    func typeText(text: String, elementId: String?) async throws -> String

    /// Fills multiple form inputs in a single coordinated operation.
    func fillForm(fields: [String: String]) async throws -> String

    /// Scrolls the webpage in the specified direction.
    func scroll(direction: BrowserScrollDirection, amount: Int?) async throws -> String

    /// Navigates backward in browser history.
    func goBack() async throws -> BrowserPageMetadata

    /// Navigates forward in browser history.
    func goForward() async throws -> BrowserPageMetadata

    /// Refreshes the current webpage.
    func refresh() async throws -> BrowserPageMetadata

    /// Captures a screenshot of the current page, optionally saving to disk or returning base64.
    func takeScreenshot(savePath: String?) async throws -> String

    /// Lists all managed browser tabs.
    func listTabs() async throws -> [BrowserTabInfo]

    /// Closes a specified tab or the current active tab.
    func closeTab(tabId: UUID?) async throws -> String

    /// Bounded poll waiting for a specified selector to appear in the DOM.
    func waitForElement(selector: String, timeoutSeconds: Double) async throws -> Bool

    /// Dispatches mouseover and mouseenter events to simulate hovering over an element.
    func hover(elementId: String) async throws -> String

    /// Sends a keyboard key action (e.g. 'Enter', 'Tab', 'Escape', 'ArrowDown') to an element or active element.
    func pressKey(key: String, elementId: String?) async throws -> String

    /// Selects an option in a <select> element by value or text.
    func selectOption(elementId: String, value: String) async throws -> String

    /// Retrieves raw HTML content of the page or a specified selector.
    func getHTML(selector: String?) async throws -> String

    /// Evaluates custom JavaScript in the active page context.
    func evaluate(script: String) async throws -> String
}

/// Common errors encountered during browser automation.
public enum BrowserAutomationError: LocalizedError, Equatable {
    case invalidURL(String)
    case navigationFailed(String)
    case timeout(String)
    case elementNotFound(String)
    case tabNotFound(String)
    case javascriptExecutionFailed(String)
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid browser destination URL: '\(url)'."
        case .navigationFailed(let reason):
            return "Browser navigation failed: \(reason)"
        case .timeout(let details):
            return "Browser operation timed out: \(details)"
        case .elementNotFound(let query):
            return "Target element not found: '\(query)'."
        case .tabNotFound(let id):
            return "Browser tab not found: '\(id)'."
        case .javascriptExecutionFailed(let err):
            return "Webpage script execution failed: \(err)"
        case .actionFailed(let details):
            return "Browser action failed: \(details)"
        }
    }
}

