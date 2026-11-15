import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Native Application Tool Suite Factory

public enum NativeApplicationTools {
    public static func allTools(
        sessionManager: ApplicationSessionManager = .shared,
        directoryManager: AuthorizedDirectoryManager? = nil
    ) -> [any Tool] {
        [
            OpenApplicationTool(sessionManager: sessionManager),
            QuitApplicationTool(),
            ActivateApplicationTool(),
            SwitchApplicationTool(),
            OpenFileWithDefaultAppTool(directoryManager: directoryManager),
            OpenFolderInFinderTool(directoryManager: directoryManager)
        ]
    }
}

// MARK: - 1. open_application

public struct OpenApplicationTool: Tool, Sendable {
    public let sessionManager: ApplicationSessionManager

    public init(sessionManager: ApplicationSessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "open_application",
            description: "Launches or activates a macOS desktop application such as Safari, Finder, Notes, Calculator, TextEdit, or System Settings.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Name of the macOS application to launch (e.g. 'Safari', 'Finder', 'Notes', 'Calculator', 'TextEdit').", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let appName = parameters["app_name"], !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'app_name'.")
        }

        do {
            let app = try await sessionManager.launchApplication(appName: appName)
            return .success(
                toolName: definition.name,
                output: "Successfully launched or activated '\(app.name)' (PID: \(app.pid), Bundle: \(app.bundleId)).",
                metadata: ["appName": app.name, "pid": "\(app.pid)", "bundleId": app.bundleId]
            )
        } catch {
            return .failure(toolName: definition.name, error: "Failed to open application '\(appName)': \(error.localizedDescription)")
        }
    }
}

// MARK: - 2. quit_application

public struct QuitApplicationTool: Tool, Sendable {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "quit_application",
            description: "Gracefully terminates a running macOS application.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Name or bundle ID of the running application to quit.", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .userConfirmationRequired
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let appName = parameters["app_name"], !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'app_name'.")
        }

        #if canImport(AppKit)
        let apps = NSWorkspace.shared.runningApplications
        if let target = apps.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
        }) {
            let terminated = target.terminate()
            if terminated {
                return .success(toolName: definition.name, output: "Successfully sent quit signal to '\(appName)'.")
            } else {
                return .failure(toolName: definition.name, error: "Application '\(appName)' did not terminate.")
            }
        }
        return .failure(toolName: definition.name, error: "Application '\(appName)' is not currently running.")
        #else
        return .failure(toolName: definition.name, error: "AppKit is unavailable on this platform.")
        #endif
    }
}

// MARK: - 3. activate_application

public struct ActivateApplicationTool: Tool, Sendable {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "activate_application",
            description: "Brings an active running macOS application to the frontmost window position.",
            parameters: [
                ToolParameter(name: "app_name", type: .string, description: "Name of the running application to bring to front.", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let appName = parameters["app_name"], !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'app_name'.")
        }

        #if canImport(AppKit)
        let apps = NSWorkspace.shared.runningApplications
        if let target = apps.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
        }) {
            target.activate(options: [.activateIgnoringOtherApps])
            return .success(toolName: definition.name, output: "Successfully activated '\(appName)' and brought it to the foreground.")
        }
        return .failure(toolName: definition.name, error: "Application '\(appName)' is not currently running.")
        #else
        return .failure(toolName: definition.name, error: "AppKit is unavailable.")
        #endif
    }
}

// MARK: - 4. switch_application

public struct SwitchApplicationTool: Tool, Sendable {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "switch_application",
            description: "Switches focus from the current application to another target macOS application.",
            parameters: [
                ToolParameter(name: "to_app", type: .string, description: "Name of the application to switch focus to.", isRequired: true),
                ToolParameter(name: "from_app", type: .string, description: "Optional name of the current application being switched away from.", isRequired: false)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let toApp = parameters["to_app"], !toApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'to_app'.")
        }

        #if canImport(AppKit)
        let apps = NSWorkspace.shared.runningApplications
        if let target = apps.first(where: {
            $0.localizedName?.caseInsensitiveCompare(toApp) == .orderedSame ||
            $0.bundleIdentifier?.localizedCaseInsensitiveContains(toApp) == true
        }) {
            target.activate(options: [.activateIgnoringOtherApps])
            return .success(toolName: definition.name, output: "Successfully switched active focus to '\(toApp)'.")
        }
        return .failure(toolName: definition.name, error: "Application '\(toApp)' is not currently running.")
        #else
        return .failure(toolName: definition.name, error: "AppKit is unavailable.")
        #endif
    }
}

// MARK: - 5. open_file_with_default_application

public struct OpenFileWithDefaultAppTool: Tool, Sendable {
    public let directoryManager: AuthorizedDirectoryManager?

    public init(directoryManager: AuthorizedDirectoryManager? = nil) {
        self.directoryManager = directoryManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "open_file_with_default_application",
            description: "Opens an authorized local file using its default macOS associated application (e.g. opens images in Preview, code in Xcode/TextEdit).",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Authorized filesystem path of the file to open.", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .userConfirmationRequired
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let path = parameters["path"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'path'.")
        }

        #if canImport(AppKit)
        var fileURL: URL
        if let dm = directoryManager {
            do {
                let (canonical, _) = try await dm.validateAndResolve(path: path)
                fileURL = canonical
            } catch {
                return .denied(toolName: definition.name, reason: error.localizedDescription)
            }
        } else {
            fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failure(toolName: definition.name, error: "File not found at '\(fileURL.path)'.")
        }

        let opened = NSWorkspace.shared.open(fileURL)
        if opened {
            return .success(toolName: definition.name, output: "Successfully opened '\(fileURL.lastPathComponent)' with its default application.")
        } else {
            return .failure(toolName: definition.name, error: "Failed to open file '\(fileURL.lastPathComponent)' with default application.")
        }
        #else
        return .failure(toolName: definition.name, error: "AppKit is unavailable.")
        #endif
    }
}

// MARK: - 6. open_folder_in_finder

public struct OpenFolderInFinderTool: Tool, Sendable {
    public let directoryManager: AuthorizedDirectoryManager?

    public init(directoryManager: AuthorizedDirectoryManager? = nil) {
        self.directoryManager = directoryManager
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "open_folder_in_finder",
            description: "Opens and reveals an authorized folder in a native macOS Finder window.",
            parameters: [
                ToolParameter(name: "path", type: .string, description: "Authorized filesystem path of the folder to open in Finder.", isRequired: true)
            ],
            category: .desktopApp,
            permissionLevel: .safeReadOnly
        )
    }

    public func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        guard let path = parameters["path"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(toolName: definition.name, error: "Missing required parameter 'path'.")
        }

        #if canImport(AppKit)
        var folderURL: URL
        if let dm = directoryManager {
            do {
                let (canonical, _) = try await dm.validateAndResolve(path: path)
                folderURL = canonical
            } catch {
                return .denied(toolName: definition.name, reason: error.localizedDescription)
            }
        } else {
            folderURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(toolName: definition.name, error: "Path '\(folderURL.path)' is not a valid existing directory.")
        }

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderURL.path)
        return .success(toolName: definition.name, output: "Opened folder '\(folderURL.path)' in Finder.")
        #else
        return .failure(toolName: definition.name, error: "AppKit is unavailable.")
        #endif
    }
}

