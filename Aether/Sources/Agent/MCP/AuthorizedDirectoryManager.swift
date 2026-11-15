import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Information record describing an authorized directory root.
public struct AuthorizedDirectoryInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let url: URL
    public let path: String
    public let name: String
    public let isReadOnly: Bool
    public let isAccessible: Bool
    public let isSecurityScoped: Bool

    public init(
        url: URL,
        path: String,
        name: String,
        isReadOnly: Bool,
        isAccessible: Bool,
        isSecurityScoped: Bool
    ) {
        self.id = path
        self.url = url
        self.path = path
        self.name = name
        self.isReadOnly = isReadOnly
        self.isAccessible = isAccessible
        self.isSecurityScoped = isSecurityScoped
    }
}

#if canImport(AppKit)
/// Native macOS directory picker utilizing NSOpenPanel on the MainActor.
@MainActor
public enum DirectoryPicker {
    public static func pickDirectory(title: String = "Authorize Directory for Aether Agent") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Choose a directory that Aether Agent is permitted to read, write, or manage."
        panel.prompt = "Authorize Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }
}
#endif

/// Actor managing user-authorized filesystem roots, security-scoped bookmarks,
/// path canonicalization, and App Sandbox containment for Aether.
public actor AuthorizedDirectoryManager {
    // MARK: - Properties

    private var authorizedRoots: [URL] = []
    private var readOnlyRoots: Set<String> = []
    private var accessingRoots: Set<URL> = []
    private let userDefaultsKey = "com.aether.Aether.AuthorizedDirectoryBookmarks"
    private let readOnlyDefaultsKey = "com.aether.Aether.AuthorizedDirectoryReadOnly"
    private let pathsDefaultsKey = "com.aether.Aether.AuthorizedDirectoryPaths"
    private let logger = Logger(subsystem: "com.aether.Aether", category: "AuthorizedDirectoryManager")

    // MARK: - Initializer

    public init(restorePersistedBookmarks: Bool = true) {
        if restorePersistedBookmarks {
            self.readOnlyRoots = Set(UserDefaults.standard.stringArray(forKey: readOnlyDefaultsKey) ?? [])
            self.authorizedRoots = Self.loadBookmarksFromUserDefaults(
                bookmarkKey: userDefaultsKey,
                pathsKey: pathsDefaultsKey,
                logger: logger
            )
            // Start security scoped access on restored roots
            for root in authorizedRoots {
                if root.startAccessingSecurityScopedResource() {
                    accessingRoots.insert(root)
                }
            }
        } else {
            self.authorizedRoots = []
            self.readOnlyRoots = []
        }
    }

    deinit {
        for root in accessingRoots {
            root.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Bookmark Management

    private static func loadBookmarksFromUserDefaults(
        bookmarkKey: String,
        pathsKey: String,
        logger: Logger
    ) -> [URL] {
        var loadedRoots: [URL] = []
        var pathsToRefresh = false

        // 1. Resolve security-scoped bookmarks
        if let savedDataArray = UserDefaults.standard.array(forKey: bookmarkKey) as? [Data] {
            for bookmarkData in savedDataArray {
                var isStale = false
                do {
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    let canonical = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
                    if !loadedRoots.contains(where: { $0.path == canonical.path }) {
                        loadedRoots.append(canonical)
                    }
                    if isStale {
                        pathsToRefresh = true
                        logger.info("[AuthorizedDirectoryManager] Stale bookmark detected for \(canonical.path); will refresh on save.")
                    }
                } catch {
                    logger.debug("[AuthorizedDirectoryManager] Failed to resolve security-scoped bookmark: \(error.localizedDescription)")
                }
            }
        }

        // 2. Fallback to path persistence (useful for non-sandboxed debug/testing environments)
        if let savedPaths = UserDefaults.standard.stringArray(forKey: pathsKey) {
            for path in savedPaths {
                let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                if FileManager.default.fileExists(atPath: url.path) && !loadedRoots.contains(where: { $0.path == url.path }) {
                    loadedRoots.append(url)
                }
            }
        }

        if pathsToRefresh {
            logger.info("[AuthorizedDirectoryManager] Refreshed loaded roots collection.")
        }
        return loadedRoots
    }

    /// Loads and resolves persisted security-scoped bookmarks from UserDefaults.
    public func loadPersistedBookmarks() {
        self.readOnlyRoots = Set(UserDefaults.standard.stringArray(forKey: readOnlyDefaultsKey) ?? [])
        self.authorizedRoots = Self.loadBookmarksFromUserDefaults(
            bookmarkKey: userDefaultsKey,
            pathsKey: pathsDefaultsKey,
            logger: logger
        )
        for root in authorizedRoots {
            if !accessingRoots.contains(root) && root.startAccessingSecurityScopedResource() {
                accessingRoots.insert(root)
            }
        }
    }

    /// Authorizes a directory URL, creates a persistent security-scoped bookmark, and adds it to the active roots.
    @discardableResult
    public func authorizeDirectory(url: URL, isReadOnly: Bool = false) throws -> URL {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw SecurityValidationError.protectedSystemPath(path: "Directory does not exist or is not a folder: '\(canonicalURL.path)'")
        }

        if !authorizedRoots.contains(where: { $0.path == canonicalURL.path }) {
            authorizedRoots.append(canonicalURL)
        }

        if canonicalURL.startAccessingSecurityScopedResource() {
            accessingRoots.insert(canonicalURL)
        }

        if isReadOnly {
            readOnlyRoots.insert(canonicalURL.path)
        } else {
            readOnlyRoots.remove(canonicalURL.path)
        }

        // Create security-scoped bookmark data if possible and persist
        saveActiveBookmarks()

        logger.info("[AuthorizedDirectoryManager] Successfully authorized directory: \(canonicalURL.path) (readOnly: \(isReadOnly))")
        return canonicalURL
    }

    /// Authorizes standard macOS directories (e.g. .desktopDirectory, .documentDirectory, .downloadsDirectory).
    @discardableResult
    public func authorizeCommonDirectory(_ directory: FileManager.SearchPathDirectory) throws -> URL {
        guard let dirURL = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            throw SecurityValidationError.protectedSystemPath(path: "System directory is unavailable.")
        }
        return try authorizeDirectory(url: dirURL)
    }

    /// Authorizes the standard macOS Desktop directory if available.
    @discardableResult
    public func authorizeDesktopDirectory() throws -> URL {
        try authorizeCommonDirectory(.desktopDirectory)
    }

    /// Authorizes the standard macOS Documents directory if available.
    @discardableResult
    public func authorizeDocumentsDirectory() throws -> URL {
        try authorizeCommonDirectory(.documentDirectory)
    }

    /// Authorizes the standard macOS Downloads directory if available.
    @discardableResult
    public func authorizeDownloadsDirectory() throws -> URL {
        try authorizeCommonDirectory(.downloadsDirectory)
    }

    /// Checks if the macOS Desktop directory is currently authorized.
    public func isDesktopAuthorized() -> Bool {
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL.resolvingSymlinksInPath() else {
            return false
        }
        let desktopPath = desktopURL.path
        return authorizedRoots.contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return rootPath == desktopPath || desktopPath.hasPrefix(rootPath + "/")
        }
    }

    /// Marks an authorized root directory as read-only or read-write.
    public func setReadOnly(url: URL, isReadOnly: Bool) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        if isReadOnly {
            readOnlyRoots.insert(canonical)
        } else {
            readOnlyRoots.remove(canonical)
        }
        saveActiveBookmarks()
    }

    /// Toggles the read-only status of an authorized root directory.
    public func toggleReadOnly(for url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        if readOnlyRoots.contains(canonical) {
            readOnlyRoots.remove(canonical)
        } else {
            readOnlyRoots.insert(canonical)
        }
        saveActiveBookmarks()
    }

    /// Checks whether an authorized directory path is designated as read-only.
    public func isReadOnly(url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        for ro in readOnlyRoots {
            if canonical == ro || canonical.hasPrefix(ro + "/") {
                return true
            }
        }
        return false
    }

    /// Registers a directory directly (e.g. for testing or temporary execution environments).
    public func authorizeTemporaryDirectory(url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if !authorizedRoots.contains(where: { $0.path == canonical.path }) {
            authorizedRoots.append(canonical)
        }
    }

    /// Revokes authorization for a directory root.
    public func revokeDirectory(url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if accessingRoots.contains(canonical) {
            canonical.stopAccessingSecurityScopedResource()
            accessingRoots.remove(canonical)
        }
        authorizedRoots.removeAll(where: { $0.path == canonical.path })
        readOnlyRoots.remove(canonical.path)
        saveActiveBookmarks()
        logger.info("[AuthorizedDirectoryManager] Revoked directory access: \(canonical.path)")
    }

    /// Clears all authorized directory roots.
    public func clearAll() {
        for root in accessingRoots {
            root.stopAccessingSecurityScopedResource()
        }
        accessingRoots.removeAll()
        authorizedRoots.removeAll()
        readOnlyRoots.removeAll()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: readOnlyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: pathsDefaultsKey)
        logger.info("[AuthorizedDirectoryManager] Cleared all authorized directory roots.")
    }

    /// Returns list of all currently authorized roots.
    public func listAuthorizedRoots() -> [URL] {
        authorizedRoots
    }

    /// Returns structured inspection details for all authorized directories.
    public func listAuthorizedDirectoryInfos() -> [AuthorizedDirectoryInfo] {
        authorizedRoots.map { root in
            let path = root.path
            let name = root.lastPathComponent.isEmpty ? path : root.lastPathComponent
            let isRO = readOnlyRoots.contains(path)
            let exists = FileManager.default.fileExists(atPath: path)
            let isAccessing = accessingRoots.contains(root)
            return AuthorizedDirectoryInfo(
                url: root,
                path: path,
                name: name,
                isReadOnly: isRO,
                isAccessible: exists,
                isSecurityScoped: isAccessing
            )
        }
    }

    private func saveActiveBookmarks() {
        var bookmarkArray: [Data] = []
        var pathArray: [String] = []

        for root in authorizedRoots {
            pathArray.append(root.path)
            if let data = try? root.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarkArray.append(data)
            } else if let stdData = try? root.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarkArray.append(stdData)
            }
        }

        UserDefaults.standard.set(bookmarkArray, forKey: userDefaultsKey)
        UserDefaults.standard.set(Array(readOnlyRoots), forKey: readOnlyDefaultsKey)
        UserDefaults.standard.set(pathArray, forKey: pathsDefaultsKey)
    }

    // MARK: - Path Validation & Canonicalization

    /// Validates that the given path is strictly contained within an authorized directory root.
    /// Returns the canonical resolved destination URL and the matching root URL.
    public func validateAndResolve(path rawPath: String) throws -> (canonicalURL: URL, rootURL: URL) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
        }

        // 1. Prohibit null-bytes or percent-encoded null bytes
        if trimmed.contains("\0") || trimmed.contains("%00") {
            throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
        }

        // 1a. Prohibit path traversal components ("..")
        let rawComponents = trimmed.components(separatedBy: "/")
        if rawComponents.contains("..") {
            throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
        }

        // 1b. Prohibit generic placeholder paths (e.g. '/path/to/new/folder')
        if ToolSecurityGuard.isPlaceholderPath(trimmed) {
            throw SecurityValidationError.placeholderPath(path: rawPath)
        }

        guard !authorizedRoots.isEmpty else {
            throw SecurityValidationError.protectedSystemPath(
                path: "No directories have been authorized for agent access. Please authorize folders (such as Desktop, Documents, or Downloads) in Aether Settings > Filesystem Permissions."
            )
        }

        // 2. Resolve relative or absolute path against authorized roots
        var targetURL: URL? = nil

        if trimmed.hasPrefix("/") {
            // Absolute path
            let directURL = URL(fileURLWithPath: trimmed).standardizedFileURL
            targetURL = directURL
        } else if trimmed.hasPrefix("~") {
            // Tilde expansion
            let expanded = (trimmed as NSString).expandingTildeInPath
            targetURL = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            // Relative path resolution:
            // 1. Check if trimmed path explicitly begins with the name of any authorized root
            for root in authorizedRoots {
                let rootName = root.lastPathComponent
                if rootName.caseInsensitiveCompare(trimmed) == .orderedSame {
                    targetURL = root
                    break
                } else if trimmed.lowercased().hasPrefix("\(rootName.lowercased())/") {
                    let relative = String(trimmed.dropFirst(rootName.count + 1))
                    targetURL = relative.isEmpty ? root : root.appendingPathComponent(relative).standardizedFileURL
                    break
                }
            }

            // 2. If no root name matched, check if path exists in any authorized root
            if targetURL == nil {
                for root in authorizedRoots {
                    let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        targetURL = candidate
                        break
                    }
                }
            }

            // 3. Fallback to primary authorized root
            if targetURL == nil, let primaryRoot = authorizedRoots.first {
                targetURL = primaryRoot.appendingPathComponent(trimmed).standardizedFileURL
            }
        }

        guard let candidateURL = targetURL else {
            throw SecurityValidationError.protectedSystemPath(path: rawPath)
        }

        // 3. Resolve symlinks across all ancestor components to detect escapes even for non-existent targets
        let resolvedCanonicalURL = Self.canonicalizePathResolvingSymlinks(url: candidateURL)
        let resolvedCanonicalPath = resolvedCanonicalURL.path

        // 4. Verify path traversal: components cannot contain ".."
        let components = candidateURL.pathComponents
        if components.contains("..") {
            throw SecurityValidationError.pathTraversalAttempt(path: rawPath)
        }

        // 5. Verify containment within at least one authorized root
        for root in authorizedRoots {
            let rootCanonical = root.standardizedFileURL.resolvingSymlinksInPath()
            let rootPath = rootCanonical.path

            if resolvedCanonicalPath == rootPath || resolvedCanonicalPath.hasPrefix(rootPath + "/") {
                return (resolvedCanonicalURL, root)
            }
        }

        // Reject if outside authorized roots with informative guidance
        let rootPaths = authorizedRoots.map { $0.path }.joined(separator: ", ")
        throw SecurityValidationError.protectedSystemPath(
            path: "Path '\(rawPath)' is outside all authorized directories (\(rootPaths)). Please authorize the containing folder in Aether Settings > Filesystem Permissions."
        )
    }

    // MARK: - Scoped Access Execution

    /// Deeply canonicalizes a path by resolving symbolic links across existing ancestor directories,
    /// preventing symlink escape attacks targeting non-existent target children.
    public static func canonicalizePathResolvingSymlinks(url: URL) -> URL {
        let fm = FileManager.default
        var current = url.standardizedFileURL
        var nonExistentSuffix: [String] = []

        // Traverse upwards until we find an existing filesystem ancestor
        while !fm.fileExists(atPath: current.path) && current.pathComponents.count > 1 {
            nonExistentSuffix.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
        }

        var resolved = current.resolvingSymlinksInPath()
        for component in nonExistentSuffix {
            resolved = resolved.appendingPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    /// Acquires security-scoped access to the authorized root containing the specified path.
    /// Returns the canonical destination URL and a Sendable release closure to call when finished.
    public func acquireAccess(to rawPath: String) throws -> (url: URL, release: @Sendable () -> Void) {
        let (canonicalURL, rootURL) = try validateAndResolve(path: rawPath)
        let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
        return (canonicalURL, {
            if didStartAccessing {
                rootURL.stopAccessingSecurityScopedResource()
            }
        })
    }

    /// Safely executes an operation within the security-scoped access boundary of the target path's root.
    public func withAccess<T: Sendable>(to rawPath: String, operation: @Sendable (URL) throws -> T) throws -> T {
        let access = try acquireAccess(to: rawPath)
        defer { access.release() }
        return try operation(access.url)
    }
}
