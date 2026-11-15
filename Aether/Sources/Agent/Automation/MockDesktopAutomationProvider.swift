import Foundation

/// Virtual, deterministic desktop application automation engine for unit testing and offline verification.
public actor MockDesktopAutomationProvider: DesktopAutomationProvider {
    public var runningApps: [DesktopRunningApp]
    public var windows: [DesktopWindowInfo]
    public var accessibilityTree: AccessibilityElementInfo
    public var elements: [AccessibilityElementInfo]
    public var executedActions: [String] = []

    public var shouldThrowPermissionRequired: Bool = false
    public var shouldThrowApplicationNotFound: Bool = false
    public var shouldThrowElementNotFound: Bool = false

    public init() {
        self.runningApps = [
            DesktopRunningApp(name: "Finder", bundleId: "com.apple.finder", pid: 101, isActive: false),
            DesktopRunningApp(name: "TextEdit", bundleId: "com.apple.TextEdit", pid: 102, isActive: true),
            DesktopRunningApp(name: "Safari", bundleId: "com.apple.Safari", pid: 103, isActive: false),
            DesktopRunningApp(name: "Notes", bundleId: "com.apple.Notes", pid: 104, isActive: false),
            DesktopRunningApp(name: "System Settings", bundleId: "com.apple.systempreferences", pid: 105, isActive: false)
        ]

        self.windows = [
            DesktopWindowInfo(windowId: 1, title: "Untitled", appName: "TextEdit", isMinimized: false),
            DesktopWindowInfo(windowId: 2, title: "Documents", appName: "Finder", isMinimized: false)
        ]

        let docArea = AccessibilityElementInfo(
            id: "ax_textarea_1",
            role: "AXTextArea",
            title: "Document Content",
            value: "",
            identifier: "doc_text_area",
            childrenCount: 0,
            actions: ["AXPress", "AXConfirm"]
        )

        let saveBtn = AccessibilityElementInfo(
            id: "ax_btn_save",
            role: "AXButton",
            title: "Save",
            value: nil,
            identifier: "save_button",
            childrenCount: 0,
            actions: ["AXPress"]
        )

        self.elements = [docArea, saveBtn]

        self.accessibilityTree = AccessibilityElementInfo(
            id: "ax_app_textedit",
            role: "AXApplication",
            title: "TextEdit",
            value: nil,
            identifier: "com.apple.TextEdit",
            childrenCount: 2,
            actions: [],
            children: [
                AccessibilityElementInfo(
                    id: "ax_window_1",
                    role: "AXWindow",
                    title: "Untitled",
                    value: nil,
                    identifier: "main_window",
                    childrenCount: 2,
                    actions: [],
                    children: [docArea, saveBtn]
                )
            ]
        )
    }

    public func listRunningApplications(filter: String?) async throws -> [DesktopRunningApp] {
        executedActions.append("listRunningApplications:\(filter ?? "")")
        if let f = filter?.lowercased() {
            return runningApps.filter { $0.name.lowercased().contains(f) || $0.bundleId.lowercased().contains(f) }
        }
        return runningApps
    }

    public func getFrontmostApplication() async throws -> DesktopRunningApp? {
        executedActions.append("getFrontmostApplication")
        return runningApps.first(where: { $0.isActive }) ?? runningApps.first
    }

    public func launchApplication(appName: String) async throws -> DesktopRunningApp {
        executedActions.append("launchApplication:\(appName)")
        if shouldThrowApplicationNotFound {
            throw DesktopAutomationError.applicationNotFound(appName)
        }
        let app = DesktopRunningApp(name: appName, bundleId: "com.apple.\(appName)", pid: 999, isActive: true)
        if !runningApps.contains(where: { $0.name.caseInsensitiveCompare(appName) == .orderedSame }) {
            runningApps.append(app)
        }
        return app
    }

    public func getWindows(appName: String?) async throws -> [DesktopWindowInfo] {
        executedActions.append("getWindows:\(appName ?? "")")
        if shouldThrowPermissionRequired {
            throw DesktopAutomationError.permissionRequired("Accessibility permission required.")
        }
        if let name = appName {
            return windows.filter { $0.appName.caseInsensitiveCompare(name) == .orderedSame }
        }
        return windows
    }

    public func getAccessibilityTree(appName: String?, maxDepth: Int) async throws -> AccessibilityElementInfo {
        executedActions.append("getAccessibilityTree:\(appName ?? "")")
        if shouldThrowPermissionRequired {
            throw DesktopAutomationError.permissionRequired("Accessibility permission required.")
        }
        return accessibilityTree
    }

    public func findElement(appName: String?, query: String, role: String?) async throws -> [AccessibilityElementInfo] {
        executedActions.append("findElement:\(query)")
        if shouldThrowPermissionRequired {
            throw DesktopAutomationError.permissionRequired("Accessibility permission required.")
        }
        let q = query.lowercased()
        return elements.filter {
            ($0.title?.lowercased().contains(q) == true) ||
            ($0.id.lowercased().contains(q)) ||
            ($0.role.lowercased().contains(q))
        }
    }

    public func clickElement(elementId: String, appName: String?) async throws -> String {
        executedActions.append("clickElement:\(elementId)")
        if shouldThrowElementNotFound {
            throw DesktopAutomationError.elementNotFound(elementId)
        }
        return "Clicked accessible control '\(elementId)' in \(appName ?? "active app")."
    }

    public func typeText(text: String, appName: String?) async throws -> String {
        executedActions.append("typeText:\(text)")
        // Update mock document value
        if let idx = elements.firstIndex(where: { $0.id == "ax_textarea_1" }) {
            let old = elements[idx]
            elements[idx] = AccessibilityElementInfo(
                id: old.id,
                role: old.role,
                title: old.title,
                value: text,
                identifier: old.identifier,
                childrenCount: old.childrenCount,
                actions: old.actions
            )
        }
        return "Successfully typed '\(text)' into TextEdit."
    }

    public func pressKey(key: String, appName: String?) async throws -> String {
        executedActions.append("pressKey:\(key)")
        return "Sent key '\(key)' to \(appName ?? "active app")."
    }

    public func scroll(direction: String, amount: Int?, appName: String?) async throws -> String {
        executedActions.append("scroll:\(direction)")
        return "Scrolled \(direction) in \(appName ?? "active app")."
    }

    public func getElementValue(elementId: String, appName: String?) async throws -> String {
        executedActions.append("getElementValue:\(elementId)")
        if let el = elements.first(where: { $0.id == elementId }) {
            return el.value ?? ""
        }
        return ""
    }

    public func setElementValue(elementId: String, value: String, appName: String?) async throws -> String {
        executedActions.append("setElementValue:\(elementId):\(value)")
        if let idx = elements.firstIndex(where: { $0.id == elementId }) {
            let old = elements[idx]
            elements[idx] = AccessibilityElementInfo(
                id: old.id,
                role: old.role,
                title: old.title,
                value: value,
                identifier: old.identifier,
                childrenCount: old.childrenCount,
                actions: old.actions
            )
        }
        return "Set value of '\(elementId)' to '\(value)'."
    }

    public func captureScreenshot(appName: String?, savePath: String?) async throws -> String {
        executedActions.append("captureScreenshot:\(appName ?? "")")
        return "Captured application screenshot of \(appName ?? "frontmost")."
    }

    public func clickMenuItem(menuItem: String, appName: String?) async throws -> String {
        executedActions.append("clickMenuItem:\(menuItem)")
        return "Clicked menu item '\(menuItem)' in \(appName ?? "frontmost")."
    }

    public func waitForElement(query: String, role: String?, appName: String?, timeoutSeconds: Double) async throws -> Bool {
        executedActions.append("waitForElement:\(query)")
        let q = query.lowercased()
        return elements.contains { ($0.title?.lowercased().contains(q) == true) || ($0.id.lowercased().contains(q)) }
    }

    public func quitApplication(appName: String) async throws -> String {
        executedActions.append("quitApplication:\(appName)")
        runningApps.removeAll { $0.name.caseInsensitiveCompare(appName) == .orderedSame }
        return "Successfully terminated '\(appName)'."
    }

    public func dismissAlert(action: String?, appName: String?) async throws -> String {
        executedActions.append("dismissAlert:\(action ?? "OK")")
        return "Dismissed alert in \(appName ?? "frontmost")."
    }
}

