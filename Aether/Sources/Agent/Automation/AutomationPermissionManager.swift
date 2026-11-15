import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

/// Manages macOS TCC system permissions required for desktop application and screen automation.
///
/// Handles checking, requesting, explaining, and testing accessibility and screen recording permissions.
public actor AutomationPermissionManager {
    public static let shared = AutomationPermissionManager()

    // Test overrides for deterministic unit and lifecycle testing
    private var simulatedAccessibilityGranted: Bool? = nil
    private var simulatedScreenRecordingGranted: Bool? = nil

    public init() {}

    // MARK: - Testing Overrides

    public func setSimulatedPermissions(accessibility: Bool?, screenRecording: Bool?) {
        self.simulatedAccessibilityGranted = accessibility
        self.simulatedScreenRecordingGranted = screenRecording
    }

    public func resetSimulatedPermissions() {
        self.simulatedAccessibilityGranted = nil
        self.simulatedScreenRecordingGranted = nil
    }

    // MARK: - Accessibility Permissions

    /// Checks whether the current process has been granted macOS Accessibility access.
    public func checkAccessibilityPermission() -> Bool {
        if let sim = simulatedAccessibilityGranted {
            return sim
        }
        return AXIsProcessTrusted()
    }

    /// Requests Accessibility permissions from macOS, presenting the system prompt if not yet granted.
    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        if let sim = simulatedAccessibilityGranted {
            return sim
        }
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording Permissions

    /// Checks whether the current process has been granted macOS Screen Recording access.
    public func checkScreenRecordingPermission() -> Bool {
        if let sim = simulatedScreenRecordingGranted {
            return sim
        }
        return CGPreflightScreenCaptureAccess()
    }

    /// Requests Screen Recording permissions from macOS.
    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        if let sim = simulatedScreenRecordingGranted {
            return sim
        }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - Explanations & Settings Direct Links

    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let screenCaptureSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Formats a user-facing explanation when Accessibility permission is required.
    public static func accessibilityPermissionExplanation() -> String {
        """
        macOS Accessibility Permission Required:
        Aether needs Accessibility permission to inspect application windows, read UI controls, and simulate authorized user interactions.

        To grant permission:
        1. Open System Settings → Privacy & Security → Accessibility.
        2. Enable the toggle next to 'Aether'.
        3. Re-run your command.
        """
    }

    /// Formats a user-facing explanation when Screen Recording permission is required.
    public static func screenRecordingPermissionExplanation() -> String {
        """
        macOS Screen Recording Permission Required:
        Aether needs Screen Recording permission to capture window snapshots for visual inspection.

        To grant permission:
        1. Open System Settings → Privacy & Security → Screen Recording.
        2. Enable the toggle next to 'Aether'.
        """
    }

    /// Opens the corresponding macOS System Settings pane for the given permission type.
    @MainActor
    public static func openSystemSettings(for permissionType: AutomationPermissionType) {
        let url: URL
        switch permissionType {
        case .accessibility:
            url = accessibilitySettingsURL
        case .screenRecording:
            url = screenCaptureSettingsURL
        case .automation:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") ?? accessibilitySettingsURL
        }
        NSWorkspace.shared.open(url)
    }
}
