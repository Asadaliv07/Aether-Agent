import Foundation

// MARK: - Desktop Application Tool Suite Factory

public enum DesktopAutomationTools {
    public static func allTools(sessionManager: ApplicationSessionManager = .shared) -> [any Tool] {
        [
            AppListRunningTool(sessionManager: sessionManager),
            AppGetFrontmostTool(sessionManager: sessionManager),
            AppLaunchTool(sessionManager: sessionManager),
            AppGetWindowsTool(sessionManager: sessionManager),
            AppGetAccessibilityTreeTool(sessionManager: sessionManager),
            AppFindElementTool(sessionManager: sessionManager),
            AppClickTool(sessionManager: sessionManager),
            AppTypeTextTool(sessionManager: sessionManager),
            AppPressKeyTool(sessionManager: sessionManager),
            AppScrollTool(sessionManager: sessionManager),
            AppGetElementValueTool(sessionManager: sessionManager),
            AppSetElementValueTool(sessionManager: sessionManager),
            AppCaptureScreenshotTool(sessionManager: sessionManager),
            AppActivateTool(sessionManager: sessionManager),
            AppInspectTool(sessionManager: sessionManager),
            AppTypeAliasTool(sessionManager: sessionManager),
            AppMenuClickTool(sessionManager: sessionManager),
            AppWindowListTool(sessionManager: sessionManager),
            AppWaitElementTool(sessionManager: sessionManager),
            AppScreenshotTool(sessionManager: sessionManager),
            AppQuitTool(sessionManager: sessionManager),
            AppDismissAlertTool(sessionManager: sessionManager)
        ]
    }
}

// MARK: - 1. app_list_running

public struct AppListRunningTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_list_running",
            description: "Lists active running desktop applications on macOS.",
            parameters: [
                ToolParameter(name: "filter", type: .string, description: "Optional name or bundle substring to filter applications", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let filter = parameters["filter"]
        do {
            let apps = try await sessionManager.listRunningApplications(filter: filter)
            var lines = ["Running applications (\(apps.count)):"]
            for a in apps {
                let actStr = a.isActive ? " [Frontmost]" : ""
                lines.append("- \(a.name) (PID: \(a.pid), bundle: \(a.bundleId))\(actStr)")
            }
            return .success(toolName: definition.name, output: lines.joined(separator: "\n"))
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 2. app_get_frontmost

public struct AppGetFrontmostTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_get_frontmost",
            description: "Identifies the current frontmost active macOS application.",
            parameters: [],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        do {
            guard let app = try await sessionManager.getFrontmostApplication() else {
                return .success(toolName: definition.name, output: "No active frontmost application detected.")
            }
            return .success(toolName: definition.name, output: "Frontmost application: \(app.name) (PID: \(app.pid), Bundle: \(app.bundleId))")
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 3. app_launch

public struct AppLaunchTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_launch",
            description: "Launches or activates a permitted macOS application (Finder, Safari, TextEdit, Notes, System Settings).",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Name of application to launch (e.g. 'TextEdit', 'Finder', 'Safari', 'Notes')", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let appName = parameters["app_name"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'app_name'.")
        }

        do {
            let app = try await sessionManager.launchApplication(appName: appName)
            return .success(toolName: definition.name, output: "Successfully launched/activated '\(app.name)' (PID: \(app.pid)).")
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 4. app_get_windows

public struct AppGetWindowsTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_get_windows",
            description: "Lists accessible windows belonging to an application or frontmost application.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, checks frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let appName = parameters["app_name"]
        do {
            let windows = try await sessionManager.getWindows(appName: appName)
            if windows.isEmpty {
                return .success(toolName: definition.name, output: "No accessible windows found for '\(appName ?? "frontmost")'.")
            }
            var lines = ["Accessible windows (\(windows.count)):"]
            for w in windows {
                let minStr = w.isMinimized ? " [Minimized]" : ""
                lines.append("- '\(w.title)' (App: \(w.appName))\(minStr)")
            }
            return .success(toolName: definition.name, output: lines.joined(separator: "\n"))
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 5. app_get_accessibility_tree

public struct AppGetAccessibilityTreeTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_get_accessibility_tree",
            description: "Inspects and returns the accessible UI element hierarchy for an application.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, targets frontmost application", isRequired: false),
                ToolParameter(name: "max_depth", type: .integer, description: "Maximum traversal depth (default 3)", isRequired: false, defaultValue: "3")
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let appName = parameters["app_name"]
        let maxDepth = parameters["max_depth"].flatMap { Int($0) } ?? 3

        do {
            let root = try await sessionManager.getAccessibilityTree(appName: appName, maxDepth: maxDepth)
            var lines: [String] = []

            func formatNode(node: AccessibilityElementInfo, depth: Int) {
                let indent = String(repeating: "  ", count: depth)
                let titleStr = node.title != nil ? " \"\(node.title!)\"" : ""
                let valStr = node.value != nil ? " val=\"\(node.value!)\"" : ""
                lines.append("\(indent)- [\(node.id)] \(node.role)\(titleStr)\(valStr)")
                for child in node.children {
                    formatNode(node: child, depth: depth + 1)
                }
            }

            formatNode(node: root, depth: 0)
            return .success(toolName: definition.name, output: lines.joined(separator: "\n"))
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 6. app_find_element

public struct AppFindElementTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_find_element",
            description: "Finds accessible UI controls (buttons, text fields, menu items) matching query text or role.",
            parameters: [
                ToolParameter(name: "query", type: .string, description: "Text, label, title, or identifier to search for", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, searches frontmost application", isRequired: false),
                ToolParameter(name: "role", type: .string, description: "Optional accessibility role filter, e.g. 'AXButton', 'AXTextField'", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let query = parameters["query"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'query'.")
        }
        let appName = parameters["app_name"]
        let role = parameters["role"]

        do {
            let elements = try await sessionManager.findElement(appName: appName, query: query, role: role)
            if elements.isEmpty {
                return .success(toolName: definition.name, output: "No accessible UI elements found matching '\(query)' in '\(appName ?? "frontmost")'.")
            }
            var lines = ["Discovered \(elements.count) matching UI element(s):"]
            for el in elements {
                let title = el.title != nil ? " \"\(el.title!)\"" : ""
                let val = el.value != nil ? " value=\"\(el.value!)\"" : ""
                lines.append("- ID: \(el.id) | \(el.role)\(title)\(val) | Actions: \(el.actions.joined(separator: ", "))")
            }
            return .success(toolName: definition.name, output: lines.joined(separator: "\n"))
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 7. app_click

public struct AppClickTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_click",
            description: "Clicks an accessible UI control (using element_id returned from app_find_element).",
            parameters: [
                ToolParameter(name: "element_id", type: .string, description: "Identifier of accessible element to click", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, uses frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let elementId = parameters["element_id"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'element_id'.")
        }
        let appName = parameters["app_name"]

        do {
            let result = try await sessionManager.clickElement(elementId: elementId, appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 8. app_type_text

public struct AppTypeTextTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_type_text",
            description: "Enters user-provided text into the currently focused field of an application.",
            parameters: [
                ToolParameter(name: "text", type: .string, description: "Text content to type into the field", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, targets frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let text = parameters["text"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'text'.")
        }
        let appName = parameters["app_name"]

        do {
            let result = try await sessionManager.typeText(text: text, appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 9. app_press_key

public struct AppPressKeyTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_press_key",
            description: "Sends a restricted keyboard key action to an application (return, escape, tab, space).",
            parameters: [
                ToolParameter(name: "key", type: .string, description: "Key name to press: 'return', 'escape', 'tab', or 'space'", isRequired: true, allowedValues: ["return", "escape", "tab", "space"]),
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, targets frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let key = parameters["key"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'key'.")
        }
        let appName = parameters["app_name"]

        do {
            let result = try await sessionManager.pressKey(key: key, appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 10. app_scroll

public struct AppScrollTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_scroll",
            description: "Scrolls the accessible region of an application interface.",
            parameters: [
                ToolParameter(name: "direction", type: .string, description: "Scroll direction: 'up', 'down', 'left', or 'right'", isRequired: true, allowedValues: ["up", "down", "left", "right"]),
                ToolParameter(name: "amount", type: .integer, description: "Amount of scroll units", isRequired: false),
                ToolParameter(name: "app_name", type: .string, description: "Target application name", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let dir = parameters["direction"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'direction'.")
        }
        let amount = parameters["amount"].flatMap { Int($0) }
        let appName = parameters["app_name"]

        do {
            let result = try await sessionManager.scroll(direction: dir, amount: amount, appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 11. app_get_element_value

public struct AppGetElementValueTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_get_element_value",
            description: "Reads the current value of an accessible element.",
            parameters: [
                ToolParameter(name: "element_id", type: .string, description: "Element ID to read value from", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let elementId = parameters["element_id"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'element_id'.")
        }
        let appName = parameters["app_name"]

        do {
            let val = try await sessionManager.getElementValue(elementId: elementId, appName: appName)
            return .success(toolName: definition.name, output: val.isEmpty ? "(Value is empty)" : val)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 12. app_set_element_value

public struct AppSetElementValueTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_set_element_value",
            description: "Sets the text value of an accessible element directly.",
            parameters: [
                ToolParameter(name: "element_id", type: .string, description: "Element ID to update", isRequired: true),
                ToolParameter(name: "value", type: .string, description: "New value to assign", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let elementId = parameters["element_id"], let value = parameters["value"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'element_id' or 'value'.")
        }
        let appName = parameters["app_name"]

        do {
            let result = try await sessionManager.setElementValue(elementId: elementId, value: value, appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 13. app_capture_screenshot

public struct AppCaptureScreenshotTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_capture_screenshot",
            description: "Captures a visual screenshot of an application window for inspection.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, captures frontmost application", isRequired: false),
                ToolParameter(name: "save_path", type: .string, description: "Optional local file path to save image", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let appName = parameters["app_name"]
        let savePath = parameters["save_path"]

        do {
            let result = try await sessionManager.captureScreenshot(appName: appName, savePath: savePath)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 14. app_activate

public struct AppActivateTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_activate",
            description: "Brings a running or supported application to the foreground and activates it.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Name of application to activate (e.g. 'Safari', 'Finder', 'Notes')", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await AppLaunchTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 15. app_inspect

public struct AppInspectTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_inspect",
            description: "Inspects and returns the accessible UI element tree for an application or frontmost window.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, targets frontmost application", isRequired: false),
                ToolParameter(name: "max_depth", type: .integer, description: "Maximum traversal depth (default 3)", isRequired: false, defaultValue: "3")
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await AppGetAccessibilityTreeTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 16. app_type

public struct AppTypeAliasTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_type",
            description: "Types user-provided text into the currently focused field of an application.",
            parameters: [
                ToolParameter(name: "text", type: .string, description: "Text content to type into the field", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, targets frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await AppTypeTextTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 17. app_menu_click

public struct AppMenuClickTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_menu_click",
            description: "Clicks a named menu item from the macOS application menu bar (e.g. 'New Note', 'Close Window', 'Save').",
            parameters: [
                ToolParameter(name: "menu_item", type: .string, description: "Name of menu item or action to click", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, targets frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let item = parameters["menu_item"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'menu_item'.")
        }
        let appName = parameters["app_name"]
        do {
            let result = try await sessionManager.clickMenuItem(menuItem: item, appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 18. app_window_list

public struct AppWindowListTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_window_list",
            description: "Lists accessible windows belonging to an application or frontmost application.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, checks frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await AppGetWindowsTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 19. app_wait_element

public struct AppWaitElementTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_wait_element",
            description: "Waits until an accessible UI element appears in the target application.",
            parameters: [
                ToolParameter(name: "query", type: .string, description: "Text, label, or role of element to wait for", isRequired: true),
                ToolParameter(name: "app_name", type: .string, description: "Target application name", isRequired: false),
                ToolParameter(name: "role", type: .string, description: "Optional accessibility role filter", isRequired: false),
                ToolParameter(name: "timeout_seconds", type: .number, description: "Maximum seconds to wait (default 5.0)", isRequired: false, defaultValue: "5.0")
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let query = parameters["query"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'query'.")
        }
        let appName = parameters["app_name"]
        let role = parameters["role"]
        let timeout = parameters["timeout_seconds"].flatMap { Double($0) } ?? 5.0

        do {
            let found = try await sessionManager.waitForElement(query: query, role: role, appName: appName, timeoutSeconds: timeout)
            if found {
                return .success(toolName: definition.name, output: "Element matching '\(query)' appeared in interface.")
            } else {
                return .failure(toolName: definition.name, error: "Timed out waiting for element '\(query)' after \(timeout)s.")
            }
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 20. app_screenshot

public struct AppScreenshotTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_screenshot",
            description: "Captures a screenshot of the application window for visual inspection.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, captures frontmost application", isRequired: false),
                ToolParameter(name: "save_path", type: .string, description: "Optional local file path to save image", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        try await AppCaptureScreenshotTool(sessionManager: sessionManager).execute(parameters: parameters, context: context)
    }
}

// MARK: - 21. app_quit

public struct AppQuitTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_quit",
            description: "Terminates or quits a specified running macOS application.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Name of application to quit", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .userConfirmationRequired
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let appName = parameters["app_name"] else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'app_name'.")
        }
        do {
            let result = try await sessionManager.quitApplication(appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

// MARK: - 22. app_dismiss_alert

public struct AppDismissAlertTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "app_dismiss_alert",
            description: "Dismisses or confirms an active system dialog or modal alert sheet.",
            parameters: [
                ToolParameter(name: "action", type: .string, description: "Button action to press: 'OK', 'Cancel', 'Dismiss', or 'Close'", isRequired: false, defaultValue: "OK"),
                ToolParameter(name: "app_name", type: .string, description: "Target application name. If omitted, uses frontmost application", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let action = parameters["action"] ?? "OK"
        let appName = parameters["app_name"]
        do {
            let result = try await sessionManager.dismissAlert(action: action, appName: appName)
            return .success(toolName: definition.name, output: result)
        } catch {
            return .failure(toolName: definition.name, error: error.localizedDescription)
        }
    }
}

