import Foundation

/// Central coordinator managing the active browser automation engine and session state.
public actor BrowserSessionManager {
    public static let shared = BrowserSessionManager()

    private var customProvider: (any BrowserAutomationProvider)?

    public private(set) var directoryManager: AuthorizedDirectoryManager?

    public init(provider: (any BrowserAutomationProvider)? = nil, directoryManager: AuthorizedDirectoryManager? = nil) {
        self.customProvider = provider
        self.directoryManager = directoryManager
    }

    /// Sets the directory manager for path containment and relative path resolution.
    public func setDirectoryManager(_ manager: AuthorizedDirectoryManager?) {
        self.directoryManager = manager
    }

    /// Replaces the active browser engine (e.g. for testing with mock provider).
    public func setProvider(_ provider: any BrowserAutomationProvider) {
        self.customProvider = provider
    }

    /// Accesses the active provider.
    public func getProvider() async -> any BrowserAutomationProvider {
        await resolveProvider()
    }

    private func resolveProvider() async -> any BrowserAutomationProvider {
        if let custom = customProvider {
            return custom
        }
        return await MainActor.run {
            WebKitBrowserAutomationProvider.shared
        }
    }

    // MARK: - Forwarding API

    public func open(url: URL) async throws -> BrowserPageMetadata {
        try await resolveProvider().open(url: url)
    }

    public func getPageContent(format: String = "markdown", maxLength: Int? = nil) async throws -> String {
        try await resolveProvider().getPageContent(format: format, maxLength: maxLength)
    }

    public func getPageMetadata() async throws -> BrowserPageMetadata {
        try await resolveProvider().getPageMetadata()
    }

    public func findElement(query: String, by: String = "text") async throws -> [BrowserElementInfo] {
        try await resolveProvider().findElement(query: query, by: by)
    }

    public func click(elementId: String) async throws -> String {
        try await resolveProvider().click(elementId: elementId)
    }

    public func typeText(text: String, elementId: String? = nil) async throws -> String {
        try await resolveProvider().typeText(text: text, elementId: elementId)
    }

    public func fillForm(fields: [String: String]) async throws -> String {
        try await resolveProvider().fillForm(fields: fields)
    }

    public func scroll(direction: BrowserScrollDirection, amount: Int? = nil) async throws -> String {
        try await resolveProvider().scroll(direction: direction, amount: amount)
    }

    public func goBack() async throws -> BrowserPageMetadata {
        try await resolveProvider().goBack()
    }

    public func goForward() async throws -> BrowserPageMetadata {
        try await resolveProvider().goForward()
    }

    public func refresh() async throws -> BrowserPageMetadata {
        try await resolveProvider().refresh()
    }

    public func takeScreenshot(savePath: String? = nil) async throws -> String {
        var resolvedPath = savePath
        if let path = savePath, !path.isEmpty {
            if let dm = directoryManager {
                let (canonicalURL, _) = try await dm.validateAndResolve(path: path)
                resolvedPath = canonicalURL.path
            }
        }
        return try await resolveProvider().takeScreenshot(savePath: resolvedPath)
    }

    public func listTabs() async throws -> [BrowserTabInfo] {
        try await resolveProvider().listTabs()
    }

    public func closeTab(tabId: UUID? = nil) async throws -> String {
        try await resolveProvider().closeTab(tabId: tabId)
    }

    public func waitForElement(selector: String, timeoutSeconds: Double = 5.0) async throws -> Bool {
        try await resolveProvider().waitForElement(selector: selector, timeoutSeconds: timeoutSeconds)
    }

    public func hover(elementId: String) async throws -> String {
        try await resolveProvider().hover(elementId: elementId)
    }

    public func pressKey(key: String, elementId: String? = nil) async throws -> String {
        try await resolveProvider().pressKey(key: key, elementId: elementId)
    }

    public func selectOption(elementId: String, value: String) async throws -> String {
        try await resolveProvider().selectOption(elementId: elementId, value: value)
    }

    public func getHTML(selector: String? = nil) async throws -> String {
        try await resolveProvider().getHTML(selector: selector)
    }

    public func evaluate(script: String) async throws -> String {
        try await resolveProvider().evaluate(script: script)
    }
}
