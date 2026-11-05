import Foundation
import os

/// High-level actor coordinating local model discovery, catalog persistence,
/// GGUF metadata extraction, and App Sandbox file-access resolution.
public actor ModelLibraryService {
    private let database: ConversationDatabase
    private let metadataReader: GGUFMetadataReader
    private let logger = Logger(subsystem: "com.aether.Aether", category: "ModelLibraryService")

    /// Active security-scoped resources being accessed by this service session.
    private var activeSecurityScopedURLs: [UUID: URL] = [:]

    public init(database: ConversationDatabase, metadataReader: GGUFMetadataReader = GGUFMetadataReader()) {
        self.database = database
        self.metadataReader = metadataReader
    }

    deinit {
        // Stop accessing all active security-scoped resources upon teardown
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Catalog Queries & Refresh

    /// Fetches all cataloged models from SQLite and assesses their current filesystem readiness.
    public func fetchCatalog() async throws -> [ModelRecord] {
        let storedModels = try await database.fetchModels()
        var resolvedModels: [ModelRecord] = []

        for var model in storedModels {
            // Assess file existence and accessibility
            var exists = false
            #if os(macOS)
            if activeSecurityScopedURLs[model.id] != nil {
                exists = FileManager.default.fileExists(atPath: model.filePath)
            } else if let bookmarkData = model.bookmarkData {
                var isStale = false
                if let resolvedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    let accessed = resolvedURL.startAccessingSecurityScopedResource()
                    exists = FileManager.default.fileExists(atPath: resolvedURL.path)
                    if accessed {
                        resolvedURL.stopAccessingSecurityScopedResource()
                    }
                    if isStale {
                        if let freshBookmark = try? resolvedURL.bookmarkData(
                            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            try? await database.updateModelBookmark(id: model.id, bookmarkData: freshBookmark)
                            model.bookmarkData = freshBookmark
                        }
                    }
                }
            }
            if !exists {
                if FileManager.default.fileExists(atPath: model.filePath) {
                    exists = true
                    let url = URL(fileURLWithPath: model.filePath)
                    if let newBookmark = try? url.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        try? await database.updateModelBookmark(id: model.id, bookmarkData: newBookmark)
                        model.bookmarkData = newBookmark
                    }
                }
            }
            #else
            exists = FileManager.default.fileExists(atPath: model.filePath)
            #endif

            if !exists {
                model.isMissing = true
            } else {
                model.isMissing = false
                // Re-evaluate compatibility against current system state
                let fileSize = model.fileSize
                if let liveMetadata = try? metadataReader.readMetadata(at: model.filePath) {
                    model.compatibilityStatus = metadataReader.evaluateCompatibility(metadata: liveMetadata, fileSize: fileSize)
                } else {
                    let metadata = GGUFMetadata(
                        architecture: model.architecture,
                        name: model.name,
                        quantization: model.quantization,
                        contextLength: model.contextLength,
                        parameterCount: model.parameterCount,
                        tensorCount: 1
                    )
                    model.compatibilityStatus = metadataReader.evaluateCompatibility(metadata: metadata, fileSize: fileSize)
                }
            }
            resolvedModels.append(model)
        }

        return resolvedModels
    }

    /// Fetches a specific model by ID from the catalog.
    public func fetchModel(id: UUID) async throws -> ModelRecord? {
        guard var model = try await database.fetchModel(id: id) else { return nil }
        var exists = false
        #if os(macOS)
        if activeSecurityScopedURLs[id] != nil {
            exists = FileManager.default.fileExists(atPath: model.filePath)
        } else if let bookmarkData = model.bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let accessed = resolvedURL.startAccessingSecurityScopedResource()
                exists = FileManager.default.fileExists(atPath: resolvedURL.path)
                if accessed {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
                if isStale {
                    if let freshBookmark = try? resolvedURL.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        try? await database.updateModelBookmark(id: id, bookmarkData: freshBookmark)
                        model.bookmarkData = freshBookmark
                    }
                }
            }
        }
        if !exists {
            if FileManager.default.fileExists(atPath: model.filePath) {
                exists = true
                let url = URL(fileURLWithPath: model.filePath)
                if let newBookmark = try? url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    try? await database.updateModelBookmark(id: id, bookmarkData: newBookmark)
                    model.bookmarkData = newBookmark
                }
            }
        }
        #else
        exists = FileManager.default.fileExists(atPath: model.filePath)
        #endif
        model.isMissing = !exists
        if exists {
            let fileSize = model.fileSize
            if let liveMetadata = try? metadataReader.readMetadata(at: model.filePath) {
                model.compatibilityStatus = metadataReader.evaluateCompatibility(metadata: liveMetadata, fileSize: fileSize)
            } else {
                let metadata = GGUFMetadata(
                    architecture: model.architecture,
                    name: model.name,
                    quantization: model.quantization,
                    contextLength: model.contextLength,
                    parameterCount: model.parameterCount,
                    tensorCount: 1
                )
                model.compatibilityStatus = metadataReader.evaluateCompatibility(metadata: metadata, fileSize: fileSize)
            }
        }
        return model
    }

    // MARK: - Model Ingestion & Registration

    /// Registers a local GGUF model file into Aether's catalog.
    ///
    /// - Parameters:
    ///   - fileURL: The local URL pointing to a `.gguf` file (e.g. from `NSOpenPanel`).
    ///   - customName: Optional user-override for model display name.
    /// - Returns: Persisted `ModelRecord` with extracted metadata.
    public func registerModel(at fileURL: URL, customName: String? = nil, allowReauthorization: Bool = false) async throws -> ModelRecord {
        let canonicalPath = fileURL.path

        // Check for duplicate path in catalog
        if let existing = try await database.fetchModel(byPath: canonicalPath) {
            if allowReauthorization {
                logger.info("Model at '\(canonicalPath, privacy: .public)' is already cataloged (ID: \(existing.id, privacy: .public)). Re-authorizing bookmark.")
                let bookmarkData: Data? = {
                    #if os(macOS)
                    return try? fileURL.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    #else
                    return nil
                    #endif
                }()
                if let bookmarkData {
                    try await database.updateModelBookmark(id: existing.id, bookmarkData: bookmarkData)
                }
                if let refreshed = try await fetchModel(id: existing.id) {
                    return refreshed
                }
                return existing
            } else {
                throw ModelLibraryError.duplicateModel(path: existing.filePath)
            }
        }

        // Access security-scoped resource if URL is security-scoped
        let isSecurityScoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        // 1. Inspect GGUF header and metadata with zero tensor allocation
        let metadata = try metadataReader.readMetadata(at: canonicalPath)

        // 2. Query filesystem attributes
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: canonicalPath),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        // 3. Evaluate compatibility
        let compatibility = metadataReader.evaluateCompatibility(metadata: metadata, fileSize: fileSize)

        // 4. Attempt to generate security-scoped bookmark for App Sandbox persistence
        let bookmarkData: Data? = {
            #if os(macOS)
            do {
                return try fileURL.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                logger.error("Failed to create security-scoped bookmark for '\(fileURL.path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                return nil
            }
            #else
            return nil
            #endif
        }()

        let displayName = customName ?? metadata.name
        let record = ModelRecord(
            name: displayName,
            filePath: canonicalPath,
            fileSize: fileSize,
            architecture: metadata.architecture,
            quantization: metadata.quantization,
            contextLength: metadata.contextLength,
            parameterCount: metadata.parameterCount,
            bookmarkData: bookmarkData,
            isMissing: false,
            compatibilityStatus: compatibility
        )

        // 5. Persist to SQLite
        let persistedRecord = try await database.insertModel(record)
        logger.info("Successfully registered model '\(displayName, privacy: .public)' (\(metadata.architecture, privacy: .public))")
        return persistedRecord
    }

    /// Relinks an existing catalog model to a new or re-selected local file URL, updating its path,
    /// security-scoped bookmark, and re-validating compatibility.
    public func relinkModel(id: UUID, fileURL: URL) async throws -> ModelRecord {
        guard let existing = try await database.fetchModel(id: id) else {
            throw ModelLibraryError.modelNotFoundInCatalog(id)
        }

        let canonicalPath = fileURL.path
        let isSecurityScoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = try metadataReader.readMetadata(at: canonicalPath)
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: canonicalPath),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        let bookmarkData: Data? = {
            #if os(macOS)
            return try? fileURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            return nil
            #endif
        }()

        try await database.updateModelLocation(
            id: id,
            filePath: canonicalPath,
            fileSize: fileSize,
            bookmarkData: bookmarkData
        )

        logger.info("Successfully relinked model ID \(id, privacy: .public) to '\(canonicalPath, privacy: .public)'")
        guard let updated = try await fetchModel(id: id) else {
            throw ModelLibraryError.modelNotFoundInCatalog(id)
        }
        return updated
    }

    // MARK: - Model Removal (Non-Destructive)

    /// Removes a model entry from Aether's SQLite catalog.
    ///
    /// GUARANTEE: This operation strictly removes database metadata.
    /// It NEVER deletes, moves, or alters the physical model file on disk.
    public func removeModelFromCatalog(id: UUID) async throws {
        // Stop any active security-scoped access
        if let activeURL = activeSecurityScopedURLs.removeValue(forKey: id) {
            activeURL.stopAccessingSecurityScopedResource()
        }

        try await database.deleteModel(id: id)
        logger.info("Removed model ID \(id, privacy: .public) from library catalog.")
    }

    // MARK: - File Access Resolution

    /// Resolves access to a model file for loading into memory, activating security-scoped
    /// bookmarks if necessary.
    ///
    /// - Parameter modelId: The catalog model ID.
    /// - Returns: Resolved canonical filesystem path ready for inference worker loading.
    public func prepareModelForLoading(id: UUID) async throws -> String {
        guard let model = try await database.fetchModel(id: id) else {
            throw ModelLibraryError.modelNotFoundInCatalog(id)
        }

        // Check if bookmark data exists for sandboxed resolution
        if let bookmarkData = model.bookmarkData {
            var isStale = false
            #if os(macOS)
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                throw ModelLibraryError.unreadableFile("Could not resolve security-scoped bookmark for model '\(model.name)'.")
            }

            // Start accessing security-scoped resource before attempting any filesystem access
            var newlyStarted = false
            if activeSecurityScopedURLs[id] == nil {
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    throw ModelLibraryError.unreadableFile("Failed to acquire security-scoped access for model '\(model.name)' at '\(resolvedURL.path)'.")
                }
                activeSecurityScopedURLs[id] = resolvedURL
                newlyStarted = true
                logger.info("Acquired security-scoped access for model '\(model.name, privacy: .public)'")
            }

            let resolvedPath = resolvedURL.path
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                if newlyStarted {
                    releaseModelAccess(id: id)
                }
                throw ModelLibraryError.fileNotFound(resolvedPath)
            }

            if isStale {
                // Refresh bookmark if stale
                if let freshBookmark = try? resolvedURL.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    try? await database.updateModelBookmark(id: id, bookmarkData: freshBookmark)
                    logger.info("Refreshed stale security-scoped bookmark for model '\(model.name, privacy: .public)'")
                }
            }

            try? await database.updateModelLastUsed(id: id)
            return resolvedPath
            #endif
        }

        // Direct path fallback (e.g. for container files or testing)
        let path = model.filePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ModelLibraryError.fileNotFound(path)
        }
        try? await database.updateModelLastUsed(id: id)
        return path
    }

    /// Releases any security-scoped access token held for a model.
    ///
    /// GUARANTEE: Calls `stopAccessingSecurityScopedResource()` exactly once for the
    /// active token and removes it from tracking to prevent double-stopping or leaks.
    public func releaseModelAccess(id: UUID) {
        if let url = activeSecurityScopedURLs.removeValue(forKey: id) {
            url.stopAccessingSecurityScopedResource()
            logger.info("Released security-scoped access for model ID \(id, privacy: .public)")
        }
    }

    /// Releases all active security-scoped access tokens on application shutdown.
    public func releaseAllModelAccess() {
        for (id, url) in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
            logger.info("Shutdown: Released security-scoped access for model ID \(id, privacy: .public)")
        }
        activeSecurityScopedURLs.removeAll()
    }

    /// Testable inquiry into whether security-scoped access is currently active for a model ID.
    public func isModelAccessActive(id: UUID) -> Bool {
        return activeSecurityScopedURLs[id] != nil
    }

    /// Returns the total count of active security-scoped resource tokens held.
    public func activeAccessCount() -> Int {
        return activeSecurityScopedURLs.count
    }
}
