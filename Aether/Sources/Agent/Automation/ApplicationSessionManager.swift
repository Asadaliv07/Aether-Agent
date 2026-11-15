import Foundation

/// Central coordinator managing desktop application automation and session state.
public actor ApplicationSessionManager {
    public static let shared = ApplicationSessionManager()

    private var activeProvider: any DesktopAutomationProvider
    public private(set) var directoryManager: AuthorizedDirectoryManager?

    public init(provider: (any DesktopAutomationProvider)? = nil, directoryManager: AuthorizedDirectoryManager? = nil) {
        if let custom = provider {
            self.activeProvider = custom
        } else {
            self.activeProvider = NativeDesktopAutomationProvider.shared
        }
        self.directoryManager = directoryManager
    }

    /// Sets the directory manager for path containment and relative path resolution.
    public func setDirectoryManager(_ manager: AuthorizedDirectoryManager?) {
        self.directoryManager = manager
    }

    /// Replaces the active desktop automation provider (e.g. with a mock during testing).
    public func setProvider(_ provider: any DesktopAutomationProvider) {
        self.activeProvider = provider
    }

    /// Accesses the active provider.
    public func getProvider() -> any DesktopAutomationProvider {
        self.activeProvider
    }

    // MARK: - Forwarding API

    public func listRunningApplications(filter: String? = nil) async throws -> [DesktopRunningApp] {
        try await activeProvider.listRunningApplications(filter: filter)
    }

    public func getFrontmostApplication() async throws -> DesktopRunningApp? {
        try await activeProvider.getFrontmostApplication()
    }

    public func launchApplication(appName: String) async throws -> DesktopRunningApp {
        try await activeProvider.launchApplication(appName: appName)
    }

    public func getWindows(appName: String? = nil) async throws -> [DesktopWindowInfo] {
        try await activeProvider.getWindows(appName: appName)
    }

    public func getAccessibilityTree(appName: String? = nil, maxDepth: Int = 3) async throws -> AccessibilityElementInfo {
        try await activeProvider.getAccessibilityTree(appName: appName, maxDepth: maxDepth)
    }

    public func findElement(appName: String? = nil, query: String, role: String? = nil) async throws -> [AccessibilityElementInfo] {
        try await activeProvider.findElement(appName: appName, query: query, role: role)
    }

    public func clickElement(elementId: String, appName: String? = nil) async throws -> String {
        try await activeProvider.clickElement(elementId: elementId, appName: appName)
    }

    public func typeText(text: String, appName: String? = nil) async throws -> String {
        try await activeProvider.typeText(text: text, appName: appName)
    }

    public func pressKey(key: String, appName: String? = nil) async throws -> String {
        try await activeProvider.pressKey(key: key, appName: appName)
    }

    public func scroll(direction: String, amount: Int? = nil, appName: String? = nil) async throws -> String {
        try await activeProvider.scroll(direction: direction, amount: amount, appName: appName)
    }

    public func getElementValue(elementId: String, appName: String? = nil) async throws -> String {
        try await activeProvider.getElementValue(elementId: elementId, appName: appName)
    }

    public func setElementValue(elementId: String, value: String, appName: String? = nil) async throws -> String {
        try await activeProvider.setElementValue(elementId: elementId, value: value, appName: appName)
    }

    public func captureScreenshot(appName: String? = nil, savePath: String? = nil) async throws -> String {
        var resolvedPath = savePath
        if let path = savePath, !path.isEmpty {
            if let dm = directoryManager {
                let (canonicalURL, _) = try await dm.validateAndResolve(path: path)
                resolvedPath = canonicalURL.path
            }
        }
        return try await activeProvider.captureScreenshot(appName: appName, savePath: resolvedPath)
    }

    public func clickMenuItem(menuItem: String, appName: String? = nil) async throws -> String {
        try await activeProvider.clickMenuItem(menuItem: menuItem, appName: appName)
    }

    public func waitForElement(query: String, role: String? = nil, appName: String? = nil, timeoutSeconds: Double = 5.0) async throws -> Bool {
        try await activeProvider.waitForElement(query: query, role: role, appName: appName, timeoutSeconds: timeoutSeconds)
    }

    public func quitApplication(appName: String) async throws -> String {
        try await activeProvider.quitApplication(appName: appName)
    }

    public func dismissAlert(action: String? = nil, appName: String? = nil) async throws -> String {
        try await activeProvider.dismissAlert(action: action, appName: appName)
    }
}

