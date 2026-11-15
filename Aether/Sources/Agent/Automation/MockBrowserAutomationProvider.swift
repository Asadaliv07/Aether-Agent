import Foundation

/// Virtual, deterministic browser automation engine for unit testing and offline verification.
public actor MockBrowserAutomationProvider: BrowserAutomationProvider {
    private var tabs: [UUID: BrowserTabInfo] = [:]
    private var activeTabId: UUID?
    private var historyStack: [String] = []
    private var historyForwardStack: [String] = []

    // Configurable state
    public var currentMetadata: BrowserPageMetadata
    public var currentContent: String
    public var elements: [BrowserElementInfo] = []
    public var shouldFailNavigation: Bool = false
    public var shouldTimeout: Bool = false
    public var shouldThrowElementNotFound: Bool = false
    public var executedActions: [String] = []

    public init(
        initialURL: String = "https://en.wikipedia.org/wiki/Swift_(programming_language)",
        initialTitle: String = "Swift (programming language) - Wikipedia",
        initialContent: String = "# Swift (programming language)\n\nSwift is a powerful and intuitive general-purpose programming language developed by Apple Inc.\n\n[Installation Guide](https://swift.org/install)\n\n[Button: Search]"
    ) {
        let initialId = UUID()
        let tab = BrowserTabInfo(id: initialId, title: initialTitle, url: initialURL, isActive: true)
        self.tabs[initialId] = tab
        self.activeTabId = initialId
        self.currentMetadata = BrowserPageMetadata(title: initialTitle, url: initialURL, pageDescription: "Free encyclopedia article about Swift", statusCode: 200)
        self.currentContent = initialContent
        self.historyStack = [initialURL]
        self.elements = [
            BrowserElementInfo(id: "el_search", tagName: "input", text: "", role: "searchbox", attributes: ["name": "search", "placeholder": "Search Wikipedia"], isClickable: true, isInput: true),
            BrowserElementInfo(id: "el_btn_search", tagName: "button", text: "Search", role: "button", attributes: [:], isClickable: true, isInput: false),
            BrowserElementInfo(id: "el_install_link", tagName: "a", text: "Installation Guide", role: "link", attributes: ["href": "https://swift.org/install"], isClickable: true, isInput: false),
            BrowserElementInfo(id: "el_concurrency", tagName: "a", text: "Concurrency Section", role: "link", attributes: ["href": "#concurrency"], isClickable: true, isInput: false)
        ]
    }

    public func setCustomContent(title: String, url: String, content: String, elements: [BrowserElementInfo] = []) {
        self.currentMetadata = BrowserPageMetadata(title: title, url: url, pageDescription: nil, statusCode: 200)
        self.currentContent = content
        self.elements = elements
        if let id = activeTabId {
            self.tabs[id] = BrowserTabInfo(id: id, title: title, url: url, isActive: true)
        }
    }

    // MARK: - Protocol Implementation

    public func open(url: URL) async throws -> BrowserPageMetadata {
        executedActions.append("open:\(url.absoluteString)")
        if shouldFailNavigation {
            throw BrowserAutomationError.navigationFailed("Simulated network connection failure for \(url.absoluteString).")
        }
        if shouldTimeout {
            throw BrowserAutomationError.timeout("Navigation timed out after 15.0s.")
        }

        let last = url.lastPathComponent.replacingOccurrences(of: "_", with: " ")
        let pageName = (last.isEmpty || last == "/" || last == url.host) ? (url.host ?? "Web Page") : last
        let newTitle = url.host?.contains("wikipedia") == true ? "\(pageName) - Wikipedia" : pageName
        currentMetadata = BrowserPageMetadata(title: newTitle, url: url.absoluteString, pageDescription: "Simulated page content", statusCode: 200)
        historyStack.append(url.absoluteString)
        historyForwardStack.removeAll()

        if let id = activeTabId {
            tabs[id] = BrowserTabInfo(id: id, title: newTitle, url: url.absoluteString, isActive: true)
        }
        return currentMetadata
    }

    public func getPageContent(format: String, maxLength: Int?) async throws -> String {
        executedActions.append("getPageContent:\(format)")
        var text = currentContent
        if let max = maxLength, max > 0, text.count > max {
            text = String(text.prefix(max)) + "\n\n[Truncated]"
        }
        return text
    }

    public func getPageMetadata() async throws -> BrowserPageMetadata {
        executedActions.append("getPageMetadata")
        return currentMetadata
    }

    public func findElement(query: String, by: String) async throws -> [BrowserElementInfo] {
        executedActions.append("findElement:\(query):\(by)")
        let q = query.lowercased()
        return elements.filter {
            $0.text.lowercased().contains(q) ||
            $0.id.lowercased().contains(q) ||
            $0.attributes.values.contains { $0.lowercased().contains(q) }
        }
    }

    public func click(elementId: String) async throws -> String {
        executedActions.append("click:\(elementId)")
        if shouldThrowElementNotFound {
            throw BrowserAutomationError.elementNotFound(elementId)
        }
        guard let el = elements.first(where: { $0.id == elementId || $0.text.lowercased() == elementId.lowercased() }) else {
            throw BrowserAutomationError.elementNotFound(elementId)
        }

        if let href = el.attributes["href"], let u = URL(string: href) {
            _ = try await open(url: u)
        }
        return "Clicked \(el.tagName) '\(el.text)' (id: \(el.id))."
    }

    public func typeText(text: String, elementId: String?) async throws -> String {
        executedActions.append("typeText:\(text):\(elementId ?? "active")")
        return "Successfully entered '\(text)' into field."
    }

    public func fillForm(fields: [String: String]) async throws -> String {
        executedActions.append("fillForm:\(fields.keys.joined(separator: ","))")
        return "Filled form fields: \(fields.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))"
    }

    public func scroll(direction: BrowserScrollDirection, amount: Int?) async throws -> String {
        executedActions.append("scroll:\(direction.rawValue)")
        return "Scrolled \(direction.rawValue) by \(amount ?? 500)px."
    }

    public func goBack() async throws -> BrowserPageMetadata {
        executedActions.append("goBack")
        guard historyStack.count > 1 else { return currentMetadata }
        let current = historyStack.removeLast()
        historyForwardStack.append(current)
        let prev = historyStack.last ?? current
        currentMetadata = BrowserPageMetadata(title: "Previous Page", url: prev, statusCode: 200)
        return currentMetadata
    }

    public func goForward() async throws -> BrowserPageMetadata {
        executedActions.append("goForward")
        guard let next = historyForwardStack.popLast() else { return currentMetadata }
        historyStack.append(next)
        currentMetadata = BrowserPageMetadata(title: "Next Page", url: next, statusCode: 200)
        return currentMetadata
    }

    public func refresh() async throws -> BrowserPageMetadata {
        executedActions.append("refresh")
        return currentMetadata
    }

    public func takeScreenshot(savePath: String?) async throws -> String {
        executedActions.append("takeScreenshot")
        if let path = savePath {
            return "Saved page screenshot to '\(path)'."
        }
        return "Captured page snapshot (1280x800, simulated PNG, 1024 bytes)."
    }

    public func listTabs() async throws -> [BrowserTabInfo] {
        Array(tabs.values)
    }

    public func closeTab(tabId: UUID?) async throws -> String {
        let id = tabId ?? activeTabId
        guard let targetId = id, let tab = tabs.removeValue(forKey: targetId) else {
            throw BrowserAutomationError.tabNotFound(id?.uuidString ?? "active")
        }
        if activeTabId == targetId {
            activeTabId = tabs.keys.first
        }
        return "Closed browser tab '\(tab.title)'."
    }

    public func waitForElement(selector: String, timeoutSeconds: Double) async throws -> Bool {
        executedActions.append("waitForElement:\(selector)")
        if shouldTimeout { return false }
        return elements.contains { $0.id == selector || $0.tagName == selector }
    }

    public func hover(elementId: String) async throws -> String {
        executedActions.append("hover:\(elementId)")
        return "Hovered over element '\(elementId)'."
    }

    public func pressKey(key: String, elementId: String?) async throws -> String {
        executedActions.append("pressKey:\(key):\(elementId ?? "active")")
        return "Dispatched key '\(key)'."
    }

    public func selectOption(elementId: String, value: String) async throws -> String {
        executedActions.append("selectOption:\(elementId):\(value)")
        return "Selected option '\(value)' in '\(elementId)'."
    }

    public func getHTML(selector: String?) async throws -> String {
        executedActions.append("getHTML:\(selector ?? "document")")
        return "<html><body>\(currentContent)</body></html>"
    }

    public func evaluate(script: String) async throws -> String {
        executedActions.append("evaluate:\(script)")
        return "EvaluationResult: success"
    }
}

