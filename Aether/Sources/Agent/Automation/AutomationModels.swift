import Foundation
import CoreGraphics

// MARK: - Browser Automation Models

/// Scroll direction for browser navigation.
public enum BrowserScrollDirection: String, Sendable, Codable, CaseIterable {
    case up
    case down
    case top
    case bottom
}

/// Metadata and state representation of an active browser tab.
public struct BrowserTabInfo: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let url: String
    public let isActive: Bool

    public init(id: UUID = UUID(), title: String, url: String, isActive: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

/// Structured metadata extracted from the loaded webpage.
public struct BrowserPageMetadata: Sendable, Codable, Equatable {
    public let title: String
    public let url: String
    public let pageDescription: String?
    public let statusCode: Int?

    public init(title: String, url: String, pageDescription: String? = nil, statusCode: Int? = nil) {
        self.title = title
        self.url = url
        self.pageDescription = pageDescription
        self.statusCode = statusCode
    }
}

/// Structured representation of an interactive or informational webpage element.
public struct BrowserElementInfo: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let tagName: String
    public let text: String
    public let role: String?
    public let attributes: [String: String]
    public let isClickable: Bool
    public let isInput: Bool

    public init(
        id: String,
        tagName: String,
        text: String,
        role: String? = nil,
        attributes: [String: String] = [:],
        isClickable: Bool = false,
        isInput: Bool = false
    ) {
        self.id = id
        self.tagName = tagName
        self.text = text
        self.role = role
        self.attributes = attributes
        self.isClickable = isClickable
        self.isInput = isInput
    }
}

// MARK: - Desktop Application Automation Models

/// Represents a running macOS process identified for automation.
public struct DesktopRunningApp: Sendable, Codable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public let name: String
    public let bundleId: String
    public let pid: Int32
    public let isActive: Bool

    public init(name: String, bundleId: String, pid: Int32, isActive: Bool = false) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.isActive = isActive
    }
}

/// Accessible window metadata belonging to a running application.
public struct DesktopWindowInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(appName)_\(title)_\(windowId ?? 0)" }
    public let windowId: CGWindowID?
    public let title: String
    public let appName: String
    public let isMinimized: Bool

    public init(windowId: CGWindowID? = nil, title: String, appName: String, isMinimized: Bool = false) {
        self.windowId = windowId
        self.title = title
        self.appName = appName
        self.isMinimized = isMinimized
    }
}

/// Node representation in a macOS application accessibility tree.
public struct AccessibilityElementInfo: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let role: String
    public let title: String?
    public let value: String?
    public let identifier: String?
    public let childrenCount: Int
    public let actions: [String]
    public let children: [AccessibilityElementInfo]

    public init(
        id: String,
        role: String,
        title: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        childrenCount: Int = 0,
        actions: [String] = [],
        children: [AccessibilityElementInfo] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.identifier = identifier
        self.childrenCount = childrenCount
        self.actions = actions
        self.children = children
    }
}

// MARK: - Permissions & Security Models

/// Target system permission type for macOS automation.
public enum AutomationPermissionType: String, Sendable, Codable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
    case automation = "AppleEvents Automation"
}

/// Status of a macOS system permission.
public enum AutomationPermissionStatus: String, Sendable, Codable {
    case granted
    case denied
    case notDetermined
    case restricted
}

