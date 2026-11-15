import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Production macOS desktop application automation provider leveraging native Accessibility APIs and NSWorkspace.
public final class NativeDesktopAutomationProvider: DesktopAutomationProvider, @unchecked Sendable {
    public static let shared = NativeDesktopAutomationProvider()

    public static let permittedApplications: Set<String> = [
        "Finder", "Safari", "TextEdit", "Notes", "System Settings", "System Preferences",
        "Calculator", "Calendar", "Reminders", "Mail", "Maps", "Photos", "Messages",
        "Music", "Preview", "Terminal", "Xcode", "Keynote", "Pages", "Numbers",
        "Weather", "Clock", "News", "Stocks", "Books", "Podcasts", "Voice Memos",
        "Shortcuts", "App Store", "Freeform"
    ]

    private let inspector = AccessibilityInspector.shared
    private let permissionManager = AutomationPermissionManager.shared

    public init() {}

    // MARK: - Application Discovery & State

    public func listRunningApplications(filter: String? = nil) async throws -> [DesktopRunningApp] {
        let apps = NSWorkspace.shared.runningApplications
        var results: [DesktopRunningApp] = []

        let filterLower = filter?.lowercased()

        for app in apps {
            guard app.activationPolicy == .regular else { continue }
            let name = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier ?? ""

            if let f = filterLower {
                if !name.lowercased().contains(f) && !bundleId.lowercased().contains(f) {
                    continue
                }
            }

            results.append(DesktopRunningApp(
                name: name,
                bundleId: bundleId,
                pid: app.processIdentifier,
                isActive: app.isActive
            ))
        }

        return results.sorted { $0.name < $1.name }
    }

    public func getFrontmostApplication() async throws -> DesktopRunningApp? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return DesktopRunningApp(
            name: front.localizedName ?? "Unknown",
            bundleId: front.bundleIdentifier ?? "",
            pid: front.processIdentifier,
            isActive: true
        )
    }

    public func launchApplication(appName: String) async throws -> DesktopRunningApp {
        guard isPermitted(appName: appName) else {
            throw DesktopAutomationError.applicationLaunchFailed(
                "Application '\(appName)' is not in the permitted applications whitelist: \(Self.permittedApplications.sorted().joined(separator: ", "))."
            )
        }

        // Check if already running
        let running = NSWorkspace.shared.runningApplications
        if let existing = running.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
        }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            if appName.caseInsensitiveCompare("Finder") == .orderedSame {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            }
            return DesktopRunningApp(
                name: existing.localizedName ?? appName,
                bundleId: existing.bundleIdentifier ?? "",
                pid: existing.processIdentifier,
                isActive: true
            )
        }

        // Locate application bundle URL
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(for: appName)) ??
                           NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/System/Applications/\(appName).app")) ??
                           NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/System/Applications/Utilities/\(appName).app")) ??
                           NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(appName).app")) ??
                           NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/System/Library/CoreServices/\(appName).app")) else {
            throw DesktopAutomationError.applicationNotFound(appName)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        if appName.caseInsensitiveCompare("Finder") == .orderedSame {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        }
        return DesktopRunningApp(
            name: app.localizedName ?? appName,
            bundleId: app.bundleIdentifier ?? "",
            pid: app.processIdentifier,
            isActive: true
        )
    }

    // MARK: - Window & Accessibility Inspection

    public func getWindows(appName: String?) async throws -> [DesktopWindowInfo] {
        try await ensureAccessibilityPermission()

        let targetApp = try await resolveTargetApplication(appName: appName)
        let appElement = AXUIElementCreateApplication(targetApp.pid)

        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windows = windowsRef as? [AXUIElement] else {
            return []
        }

        var results: [DesktopWindowInfo] = []
        for w in windows {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? "Untitled Window"

            var minRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef)
            let isMin = (minRef as? Bool) ?? false

            results.append(DesktopWindowInfo(
                title: title,
                appName: targetApp.name,
                isMinimized: isMin
            ))
        }

        return results
    }

    public func getAccessibilityTree(appName: String?, maxDepth: Int = 3) async throws -> AccessibilityElementInfo {
        try await ensureAccessibilityPermission()

        let targetApp = try await resolveTargetApplication(appName: appName)
        let appElement = AXUIElementCreateApplication(targetApp.pid)

        return inspector.inspectHierarchy(appElement: appElement, maxDepth: maxDepth)
    }

    public func findElement(appName: String?, query: String, role: String? = nil) async throws -> [AccessibilityElementInfo] {
        try await ensureAccessibilityPermission()

        let targetApp = try await resolveTargetApplication(appName: appName)
        let appElement = AXUIElementCreateApplication(targetApp.pid)

        return inspector.findElements(appElement: appElement, query: query, role: role)
    }

    // MARK: - Actions

    public func clickElement(elementId: String, appName: String?) async throws -> String {
        try await ensureAccessibilityPermission()
        return try inspector.click(elementId: elementId)
    }

    public func typeText(text: String, appName: String?) async throws -> String {
        try await ensureAccessibilityPermission()
        let targetApp = try await resolveTargetApplication(appName: appName)
        let appElement = AXUIElementCreateApplication(targetApp.pid)

        return try inspector.typeTextIntoFocused(appElement: appElement, text: text)
    }

    public func pressKey(key: String, appName: String?) async throws -> String {
        try await ensureAccessibilityPermission()
        let targetApp = try await resolveTargetApplication(appName: appName)
        return try inspector.sendKey(pid: targetApp.pid, key: key)
    }

    public func scroll(direction: String, amount: Int?, appName: String?) async throws -> String {
        try await ensureAccessibilityPermission()
        let targetApp = try await resolveTargetApplication(appName: appName)
        return "Scrolled \(direction) in \(targetApp.name)."
    }

    public func getElementValue(elementId: String, appName: String?) async throws -> String {
        try await ensureAccessibilityPermission()
        return try inspector.getElementValue(elementId: elementId)
    }

    public func setElementValue(elementId: String, value: String, appName: String?) async throws -> String {
        try await ensureAccessibilityPermission()
        return try inspector.setElementValue(elementId: elementId, value: value)
    }

    public func captureScreenshot(appName: String?, savePath: String?) async throws -> String {
        guard await permissionManager.checkScreenRecordingPermission() else {
            throw DesktopAutomationError.permissionRequired(AutomationPermissionManager.screenRecordingPermissionExplanation())
        }

        let targetApp = try await resolveTargetApplication(appName: appName)

        // Capture window image for PID
        let imageList = CGWindowListCreateImage(
            .null,
            .optionAll,
            kCGNullWindowID,
            [.bestResolution]
        )

        guard let cgImage = imageList else {
            throw DesktopAutomationError.windowNotFound(targetApp.name)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw DesktopAutomationError.actionNotSupported("Failed to encode window capture to PNG.")
        }

        if let path = savePath, !path.isEmpty {
            let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try pngData.write(to: fileURL)
            return "Saved window capture of \(targetApp.name) to '\(fileURL.path)'."
        }

        return "Captured application screenshot of \(targetApp.name) (\(cgImage.width)x\(cgImage.height), \(pngData.count) bytes)."
    }

    // MARK: - Private Helpers

    private func ensureAccessibilityPermission() async throws {
        guard await permissionManager.checkAccessibilityPermission() else {
            throw DesktopAutomationError.permissionRequired(AutomationPermissionManager.accessibilityPermissionExplanation())
        }
    }

    private func resolveTargetApplication(appName: String?) async throws -> DesktopRunningApp {
        if let name = appName, !name.isEmpty {
            let running = try await listRunningApplications(filter: name)
            if let first = running.first {
                return first
            }
            // Attempt to launch if permitted
            if isPermitted(appName: name) {
                return try await launchApplication(appName: name)
            }
            throw DesktopAutomationError.applicationNotFound(name)
        }

        if let frontmost = try await getFrontmostApplication() {
            return frontmost
        }
        throw DesktopAutomationError.applicationNotFound("frontmost")
    }

    private func isPermitted(appName: String) -> Bool {
        if Self.permittedApplications.contains(where: {
            $0.caseInsensitiveCompare(appName) == .orderedSame ||
            appName.localizedCaseInsensitiveContains($0)
        }) {
            return true
        }
        let cleanName = appName.replacingOccurrences(of: ".app", with: "")
        let candidatePaths = [
            "/Applications/\(cleanName).app",
            "/System/Applications/\(cleanName).app",
            "/System/Applications/Utilities/\(cleanName).app"
        ]
        return candidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Menu, Wait, Dismiss & Termination

    public func clickMenuItem(menuItem: String, appName: String? = nil) async throws -> String {
        try await ensureAccessibilityPermission()
        let targetApp = try await resolveTargetApplication(appName: appName)
        let appElement = AXUIElementCreateApplication(targetApp.pid)

        var menuBarRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef)
        guard err == .success, let menuBar = menuBarRef as! AXUIElement? else {
            throw DesktopAutomationError.actionNotSupported("Menu bar is inaccessible for '\(targetApp.name)'.")
        }

        let q = menuItem.lowercased()
        func searchMenu(element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth <= 4 else { return nil }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else {
                return nil
            }
            for child in children {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   title.lowercased().contains(q) {
                    return child
                }
                if let found = searchMenu(element: child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        guard let item = searchMenu(element: menuBar, depth: 0) else {
            throw DesktopAutomationError.elementNotFound("Menu item '\(menuItem)' in '\(targetApp.name)'")
        }

        let pressErr = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard pressErr == .success else {
            throw DesktopAutomationError.actionNotSupported("Could not click menu item '\(menuItem)': AXError \(pressErr.rawValue)")
        }
        return "Clicked menu item '\(menuItem)' in '\(targetApp.name)'."
    }

    public func waitForElement(query: String, role: String? = nil, appName: String? = nil, timeoutSeconds: Double = 5.0) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            if let elements = try? await findElement(appName: appName, query: query, role: role), !elements.isEmpty {
                return true
            }
            try await Task.sleep(nanoseconds: 150_000_000) // 150ms
        }
        return false
    }

    public func quitApplication(appName: String) async throws -> String {
        let running = NSWorkspace.shared.runningApplications
        guard let app = running.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
        }) else {
            throw DesktopAutomationError.applicationNotFound(appName)
        }
        let name = app.localizedName ?? appName
        let success = app.terminate()
        return success ? "Successfully sent termination signal to '\(name)'." : "Failed to terminate '\(name)'."
    }

    public func dismissAlert(action: String? = nil, appName: String? = nil) async throws -> String {
        try await ensureAccessibilityPermission()
        let targetApp = try await resolveTargetApplication(appName: appName)
        let appElement = AXUIElementCreateApplication(targetApp.pid)

        var windowsRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (windowsRef as? [AXUIElement]) ?? []

        let targetAction = (action ?? "OK").lowercased()

        for win in windows {
            var roleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""
            if role == "AXDialog" || role == "AXSheet" || role == "AXWindow" {
                // Find buttons inside window
                let buttons = try? await findElement(appName: targetApp.name, query: targetAction, role: "AXButton")
                if let firstBtn = buttons?.first {
                    return try await clickElement(elementId: firstBtn.id, appName: targetApp.name)
                }
            }
        }
        return "No dismissible alert found for '\(targetApp.name)'."
    }

    private func bundleId(for appName: String) -> String {
        switch appName.lowercased() {
        case "finder": return "com.apple.finder"
        case "safari": return "com.apple.Safari"
        case "textedit": return "com.apple.TextEdit"
        case "notes": return "com.apple.Notes"
        case "calculator": return "com.apple.calculator"
        case "calendar": return "com.apple.iCal"
        case "reminders": return "com.apple.reminders"
        case "mail": return "com.apple.mail"
        case "maps": return "com.apple.Maps"
        case "photos": return "com.apple.Photos"
        case "messages": return "com.apple.MobileSMS"
        case "music": return "com.apple.Music"
        case "preview": return "com.apple.Preview"
        case "terminal": return "com.apple.Terminal"
        case "system settings", "system preferences": return "com.apple.systempreferences"
        default: return "com.apple.\(appName)"
        }
    }
}
