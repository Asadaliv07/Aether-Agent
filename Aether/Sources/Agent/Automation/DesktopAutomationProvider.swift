import Foundation

/// Defines the contract for macOS desktop application automation backends.
public protocol DesktopAutomationProvider: Sendable {
    /// Lists running accessible macOS applications.
    func listRunningApplications(filter: String?) async throws -> [DesktopRunningApp]

    /// Identifies the currently frontmost active application.
    func getFrontmostApplication() async throws -> DesktopRunningApp?

    /// Launches or brings to the front a permitted application.
    func launchApplication(appName: String) async throws -> DesktopRunningApp

    /// Retrieves visible application windows.
    func getWindows(appName: String?) async throws -> [DesktopWindowInfo]

    /// Inspects and returns the accessible UI element tree for the specified application.
    func getAccessibilityTree(appName: String?, maxDepth: Int) async throws -> AccessibilityElementInfo

    /// Searches for UI controls matching query by title, value, role, or identifier.
    func findElement(appName: String?, query: String, role: String?) async throws -> [AccessibilityElementInfo]

    /// Clicks an identified accessible control (e.g. button, menu item, checkbox).
    func clickElement(elementId: String, appName: String?) async throws -> String

    /// Enters text into the focused accessible field of the application.
    func typeText(text: String, appName: String?) async throws -> String

    /// Sends a restricted keyboard key action (e.g. return, escape, tab).
    func pressKey(key: String, appName: String?) async throws -> String

    /// Scrolls an accessible region in the application interface.
    func scroll(direction: String, amount: Int?, appName: String?) async throws -> String

    /// Reads the current value of an accessible UI element.
    func getElementValue(elementId: String, appName: String?) async throws -> String

    /// Sets the value of an accessible UI element.
    func setElementValue(elementId: String, value: String, appName: String?) async throws -> String

    /// Captures a screenshot of the application's main window.
    func captureScreenshot(appName: String?, savePath: String?) async throws -> String

    /// Clicks an application menu bar item (e.g. 'File', 'New').
    func clickMenuItem(menuItem: String, appName: String?) async throws -> String

    /// Bounded poll waiting for an accessible UI element to appear.
    func waitForElement(query: String, role: String?, appName: String?, timeoutSeconds: Double) async throws -> Bool

    /// Terminates/quits a specified application.
    func quitApplication(appName: String) async throws -> String

    /// Dismisses active modal alert or dialog in an application.
    func dismissAlert(action: String?, appName: String?) async throws -> String
}

/// Errors occurring during desktop application automation.
public enum DesktopAutomationError: LocalizedError, Equatable {
    case permissionRequired(String)
    case applicationNotFound(String)
    case applicationLaunchFailed(String)
    case elementNotFound(String)
    case actionNotSupported(String)
    case windowNotFound(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .permissionRequired(let msg):
            return "macOS Permission Denied: \(msg)"
        case .applicationNotFound(let name):
            return "Application '\(name)' could not be located or is not running."
        case .applicationLaunchFailed(let reason):
            return "Failed to launch application: \(reason)"
        case .elementNotFound(let id):
            return "Accessible element '\(id)' was not found."
        case .actionNotSupported(let action):
            return "Action '\(action)' is not supported by this UI element."
        case .windowNotFound(let app):
            return "No accessible windows found for application '\(app)'."
        case .timeout(let details):
            return "Application operation timed out: \(details)"
        }
    }
}

