import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// Low-level interface to macOS Accessibility APIs (`AXUIElement`) and window imaging.
public final class AccessibilityInspector: @unchecked Sendable {
    public static let shared = AccessibilityInspector()

    private let lock = NSLock()
    private var elementCache: [String: AXUIElement] = [:]
    private var elementCounter: Int = 1

    public init() {}

    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        elementCache.removeAll()
        elementCounter = 1
    }

    // MARK: - Inspection

    /// Traverses the accessibility hierarchy of an application element up to maxDepth.
    public func inspectHierarchy(appElement: AXUIElement, maxDepth: Int = 3) -> AccessibilityElementInfo {
        lock.lock()
        defer { lock.unlock() }
        return traverseNode(element: appElement, currentDepth: 0, maxDepth: maxDepth)
    }

    private func traverseNode(element: AXUIElement, currentDepth: Int, maxDepth: Int) -> AccessibilityElementInfo {
        let role: String = copyAttribute(element: element, attribute: kAXRoleAttribute as CFString) ?? "AXUnknown"
        let title: String? = copyAttribute(element: element, attribute: kAXTitleAttribute as CFString)
        let rawVal = copyAttributeValueRaw(element: element, attribute: kAXValueAttribute as CFString)
        let valueStr: String? = rawVal != nil ? "\(rawVal!)" : nil
        let identifier: String? = copyAttribute(element: element, attribute: kAXIdentifierAttribute as CFString)

        elementCounter += 1
        let elementId = "ax_\(role.replacingOccurrences(of: "AX", with: "").lowercased())_\(elementCounter)"
        elementCache[elementId] = element

        let actions = copyActions(element: element)

        var children: [AccessibilityElementInfo] = []
        let rawChildren: [AXUIElement] = copyChildren(element: element)

        if currentDepth < maxDepth {
            for child in rawChildren.prefix(15) { // Limit breadth to prevent explosion
                children.append(traverseNode(element: child, currentDepth: currentDepth + 1, maxDepth: maxDepth))
            }
        }

        return AccessibilityElementInfo(
            id: elementId,
            role: role,
            title: title,
            value: valueStr,
            identifier: identifier,
            childrenCount: rawChildren.count,
            actions: actions,
            children: children
        )
    }

    // MARK: - Element Search

    public func findElements(appElement: AXUIElement, query: String, role: String?) -> [AccessibilityElementInfo] {
        let tree = inspectHierarchy(appElement: appElement, maxDepth: 4)
        var matches: [AccessibilityElementInfo] = []
        let q = query.lowercased()

        func search(node: AccessibilityElementInfo) {
            let roleMatches = (role == nil) || (node.role.localizedCaseInsensitiveContains(role!))
            let textMatches = (node.title?.lowercased().contains(q) == true) ||
                              (node.value?.lowercased().contains(q) == true) ||
                              (node.identifier?.lowercased().contains(q) == true) ||
                              (node.id.lowercased().contains(q))

            if roleMatches && textMatches {
                matches.append(node)
            }
            for child in node.children {
                search(node: child)
            }
        }

        search(node: tree)
        return matches
    }

    // MARK: - Actions

    public func click(elementId: String) throws -> String {
        lock.lock()
        guard let element = elementCache[elementId] else {
            lock.unlock()
            throw DesktopAutomationError.elementNotFound(elementId)
        }
        lock.unlock()

        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if err == .success {
            return "Successfully clicked accessible element '\(elementId)'."
        } else {
            // Attempt fallback to confirm or pick action
            let fallbackErr = AXUIElementPerformAction(element, "AXConfirm" as CFString)
            if fallbackErr == .success {
                return "Successfully pressed confirmation for element '\(elementId)'."
            }
            throw DesktopAutomationError.actionNotSupported("Action 'AXPress' failed with AXError code \(err.rawValue).")
        }
    }

    public func setElementValue(elementId: String, value: String) throws -> String {
        lock.lock()
        guard let element = elementCache[elementId] else {
            lock.unlock()
            throw DesktopAutomationError.elementNotFound(elementId)
        }
        lock.unlock()

        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if err == .success {
            return "Set value of element '\(elementId)' to '\(value)'."
        } else {
            throw DesktopAutomationError.actionNotSupported("Setting value failed with AXError code \(err.rawValue).")
        }
    }

    public func getElementValue(elementId: String) throws -> String {
        lock.lock()
        guard let element = elementCache[elementId] else {
            lock.unlock()
            throw DesktopAutomationError.elementNotFound(elementId)
        }
        lock.unlock()

        let val = copyAttributeValueRaw(element: element, attribute: kAXValueAttribute as CFString)
        return val != nil ? "\(val!)" : ""
    }

    public func typeTextIntoFocused(appElement: AXUIElement, text: String) throws -> String {
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard err == .success, let focused = focusedElement else {
            throw DesktopAutomationError.elementNotFound("No focused editable UI element found in the application.")
        }
        let focusedUI = focused as! AXUIElement
        let setErr = AXUIElementSetAttributeValue(focusedUI, kAXValueAttribute as CFString, text as CFTypeRef)
        if setErr == .success {
            return "Successfully typed '\(text)' into focused accessible element."
        } else {
            throw DesktopAutomationError.actionNotSupported("Failed to set text on focused element: AXError \(setErr.rawValue).")
        }
    }

    public func sendKey(pid: pid_t, key: String) throws -> String {
        let keyCode: CGKeyCode?
        switch key.lowercased() {
        case "return", "enter": keyCode = 0x24
        case "tab": keyCode = 0x30
        case "space": keyCode = 0x31
        case "escape", "esc": keyCode = 0x35
        default: keyCode = nil
        }

        guard let code = keyCode else {
            throw DesktopAutomationError.actionNotSupported("Key '\(key)' is not in the restricted supported keyboard whitelist.")
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)

        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)

        return "Successfully sent key '\(key)' to PID \(pid)."
    }

    // MARK: - Low-Level Helpers

    private func copyAttribute<T>(element: AXUIElement, attribute: CFString) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let val = value as? T else { return nil }
        return val
    }

    private func copyAttributeValueRaw(element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return result == .success ? value : nil
    }

    private func copyChildren(element: AXUIElement) -> [AXUIElement] {
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard result == .success, let arr = children as? [AXUIElement] else { return [] }
        return arr
    }

    private func copyActions(element: AXUIElement) -> [String] {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success, let actionList = actions as? [String] else { return [] }
        return actionList
    }
}

