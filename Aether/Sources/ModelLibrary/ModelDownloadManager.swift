import Foundation
import os

/// Public state representing an active or completed download progress snapshot.
public struct DownloadProgress: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let repoId: String
    public let filename: String
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let fractionCompleted: Double
    public let status: DownloadStatus
    public let errorMessage: String?

    public init(
        id: UUID,
        repoId: String,
        filename: String,
        bytesDownloaded: Int64,
        totalBytes: Int64,
        status: DownloadStatus,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.repoId = repoId
        self.filename = filename
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.fractionCompleted = totalBytes > 0 ? min(max(Double(bytesDownloaded) / Double(totalBytes), 0.0), 1.0) : 0.0
        self.status = status
        self.errorMessage = errorMessage
    }

    public var formattedProgress: String {
        let downloadedStr = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        if totalBytes > 0 {
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let percent = Int(fractionCompleted * 100)
            return "\(percent)% • \(downloadedStr) / \(totalStr)"
        }
        return downloadedStr
    }
}

/// Errors occurring during model download and validation lifecycle.
public enum ModelDownloadError: LocalizedError, Equatable {
    case invalidFilename(String)
    case unsafePath(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case alreadyDownloading(String)
    case alreadyDownloaded(String)
    case downloadNotFound(UUID)
    case networkError(String)
    case corruptFile(String)
    case serverError(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidFilename(let name):
            return "Invalid filename: '\(name)'. Only safe .gguf filenames are permitted."
        case .unsafePath(let path):
            return "Path traversal detected in path: '\(path)'."
        case .insufficientDiskSpace(let required, let available):
            let reqStr = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Insufficient disk space: Model requires \(reqStr), but only \(availStr) is available."
        case .alreadyDownloading(let name):
            return "A download for '\(name)' is already in progress."
        case .alreadyDownloaded(let name):
            return "Model file '\(name)' already exists in your library."
        case .downloadNotFound(let id):
            return "Download with ID \(id) not found."
        case .networkError(let msg):
            return "Download network error: \(msg)"
        case .corruptFile(let msg):
            return "Downloaded file failed GGUF validation: \(msg)"
        case .serverError(let code):
            return "Model server returned HTTP error \(code)."
        }
    }
}

/// Protocol abstracting the model download manager for testability and injection.
public protocol ModelDownloadManagerProtocol: Sendable {
    func startDownload(
        repoId: String,
        filename: String,
        downloadURL: URL,
        expectedSize: Int64
    ) async throws -> UUID

    func pauseDownload(id: UUID) async throws
    func resumeDownload(id: UUID) async throws
    func cancelDownload(id: UUID) async throws
    func getActiveDownloads() async -> [DownloadProgress]
    func getDownload(id: UUID) async -> DownloadProgress?
}

/// Thread-safe actor orchestrating native model downloads, pause/resume, atomic staging,
/// disk-space safety checks, GGUF validation, and catalog registration.
public actor ModelDownloadManager: ModelDownloadManagerProtocol {
    private let database: ConversationDatabase
    private let modelLibraryService: ModelLibraryService
    private let metadataReader: GGUFMetadataReader
    private let modelsBaseDirectory: URL
    private let logger = Logger(subsystem: "com.aether.Aether", category: "ModelDownloadManager")

    /// Active download tasks keyed by download UUID.
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// In-memory active progress map.
    private var progressMap: [UUID: DownloadProgress] = [:]
    /// Active resume data map.
    private var resumeDataMap: [UUID: Data] = [:]

    private var session: URLSession!
    private var coordinator: DownloadCoordinator!

    public init(
        database: ConversationDatabase,
        modelLibraryService: ModelLibraryService,
        metadataReader: GGUFMetadataReader = GGUFMetadataReader(),
        modelsBaseDirectory: URL? = nil
    ) {
        self.database = database
        self.modelLibraryService = modelLibraryService
        self.metadataReader = metadataReader

        let baseDir = modelsBaseDirectory ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Aether/Models", isDirectory: true)
        }()
        self.modelsBaseDirectory = baseDir

        // Ensure base directory exists
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    /// Configures the internal URLSession with the download coordinator.
    public func configureSession(customSession: URLSession? = nil) {
        if let customSession {
            self.session = customSession
        } else {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 3600 // 1 hour for large weights
            let coord = DownloadCoordinator(manager: self)
            self.coordinator = coord
            self.session = URLSession(configuration: config, delegate: coord, delegateQueue: nil)
        }
    }

    /// Loads persisted download records on application launch.
    /// DEF-39-05: Reconciles interrupted tasks left in .downloading or .pending states.
    public func loadPersistedDownloads() async {
        do {
            let records = try await database.fetchDownloads()
            for record in records {
                var effectiveStatus = record.status
                var effectiveErrorMessage = record.errorMessage
                var validResumeData: Data? = nil

                // Check resume data validity
                if let data = record.resumeData {
                    if (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) is [String: Any] {
                        validResumeData = data
                    }
                }

                // In-process URLSession tasks cannot survive application termination.
                // If a record is persisted in .downloading or .pending state, and no active task exists
                // in memory, reconcile the record to .paused so it can be cleanly resumed or restarted.
                if (record.status == .downloading || record.status == .pending) && tasks[record.id] == nil {
                    effectiveStatus = .paused
                    effectiveErrorMessage = record.errorMessage ?? "Interrupted by application exit and paused for safe resumption"
                    logger.info("Reconciled interrupted download '\(record.filename)' from \(record.status.rawValue) to .paused.")

                    // Persist reconciled status to database
                    try? await database.updateDownloadProgress(
                        id: record.id,
                        downloadedBytes: record.downloadedBytes,
                        totalBytes: record.totalBytes,
                        status: .paused,
                        errorMessage: effectiveErrorMessage,
                        resumeData: validResumeData
                    )
                }

                let progress = DownloadProgress(
                    id: record.id,
                    repoId: record.repoId,
                    filename: record.filename,
                    bytesDownloaded: record.downloadedBytes,
                    totalBytes: record.totalBytes,
                    status: effectiveStatus,
                    errorMessage: effectiveErrorMessage
                )
                progressMap[record.id] = progress
                if let validResumeData {
                    resumeDataMap[record.id] = validResumeData
                } else {
                    resumeDataMap.removeValue(forKey: record.id)
                }
            }
            logger.info("Loaded \(records.count) persisted download records from database.")
        } catch {
            logger.error("Failed to load persisted downloads: \(error.localizedDescription)")
        }
    }

    // MARK: - Download Lifecycle

    /// Initiates a new model download.
    public func startDownload(
        repoId: String,
        filename: String,
        downloadURL: URL,
        expectedSize: Int64
    ) async throws -> UUID {
        if session == nil {
            configureSession()
        }

        // 1. Validate safe filename and prevent path traversal
        try Self.validateSafeFilename(filename)
        try Self.validateSafeRepoId(repoId)

        // 2. Resolve target file path
        let destinationDir = targetDirectory(for: repoId)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let finalPath = destinationDir.appendingPathComponent(filename).path

        // 3. Overwrite check: If final file already exists on disk, reject
        if FileManager.default.fileExists(atPath: finalPath) {
            throw ModelDownloadError.alreadyDownloaded(filename)
        }

        // 4. DEF-39-03: Deduplication and paused-state resumption check
        if let existing = progressMap.values.first(where: { $0.repoId == repoId && $0.filename == filename }) {
            switch existing.status {
            case .downloading, .pending:
                throw ModelDownloadError.alreadyDownloading(filename)
            case .paused:
                logger.info("Download for '\(filename)' from \(repoId) is paused (ID: \(existing.id)); resuming existing download.")
                try await resumeDownload(id: existing.id)
                return existing.id
            case .completed:
                throw ModelDownloadError.alreadyDownloaded(filename)
            case .failed, .cancelled:
                tasks.removeValue(forKey: existing.id)?.cancel()
                resumeDataMap.removeValue(forKey: existing.id)
                progressMap.removeValue(forKey: existing.id)
                try? await database.deleteDownload(id: existing.id)
            }
        }

        // Check persistent database for prior records across launches
        if let existingRecord = try? await database.fetchDownload(repoId: repoId, filename: filename) {
            // Re-check progressMap after suspension point in case another concurrent start reserved during await
            if let inFlight = progressMap.values.first(where: { $0.repoId == repoId && $0.filename == filename }) {
                switch inFlight.status {
                case .downloading, .pending:
                    throw ModelDownloadError.alreadyDownloading(filename)
                case .paused:
                    try await resumeDownload(id: inFlight.id)
                    return inFlight.id
                case .completed:
                    throw ModelDownloadError.alreadyDownloaded(filename)
                case .failed, .cancelled:
                    break
                }
            }

            switch existingRecord.status {
            case .downloading, .pending:
                throw ModelDownloadError.alreadyDownloading(filename)
            case .paused:
                logger.info("Found paused download in database for '\(filename)' from \(repoId) (ID: \(existingRecord.id)); resuming.")
                if let rData = existingRecord.resumeData {
                    resumeDataMap[existingRecord.id] = rData
                }
                progressMap[existingRecord.id] = DownloadProgress(
                    id: existingRecord.id,
                    repoId: existingRecord.repoId,
                    filename: existingRecord.filename,
                    bytesDownloaded: existingRecord.downloadedBytes,
                    totalBytes: existingRecord.totalBytes,
                    status: .paused
                )
                try await resumeDownload(id: existingRecord.id)
                return existingRecord.id
            case .completed:
                throw ModelDownloadError.alreadyDownloaded(filename)
            case .failed, .cancelled:
                try? await database.deleteDownload(id: existingRecord.id)
            }
        }

        // Re-check progressMap after the database await (even if record was nil) to prevent concurrent actor re-entrancy races
        if let inFlight = progressMap.values.first(where: { $0.repoId == repoId && $0.filename == filename }) {
            switch inFlight.status {
            case .downloading, .pending:
                throw ModelDownloadError.alreadyDownloading(filename)
            case .paused:
                try await resumeDownload(id: inFlight.id)
                return inFlight.id
            case .completed:
                throw ModelDownloadError.alreadyDownloaded(filename)
            case .failed, .cancelled:
                break
            }
        }

        // 5. Verify sufficient disk space
        try checkDiskSpace(at: destinationDir, requiredBytes: expectedSize)

        // 6. Allocate ID and synchronously reserve in progressMap BEFORE suspension point
        // to prevent concurrent actor re-entrancy races.
        let downloadId = UUID()
        let pendingProgress = DownloadProgress(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            bytesDownloaded: 0,
            totalBytes: expectedSize,
            status: .pending
        )
        progressMap[downloadId] = pendingProgress

        // 7. Persist to database
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: downloadURL.absoluteString,
            destinationPath: finalPath,
            totalBytes: expectedSize,
            downloadedBytes: 0,
            status: .downloading
        )
        do {
            _ = try await database.insertDownload(record)
        } catch {
            progressMap.removeValue(forKey: downloadId)
            throw error
        }

        let activeProgress = DownloadProgress(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            bytesDownloaded: 0,
            totalBytes: expectedSize,
            status: .downloading
        )
        progressMap[downloadId] = activeProgress

        // 8. Launch download task
        var request = URLRequest(url: downloadURL)
        request.setValue("Aether/1.0", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        tasks[downloadId] = task
        task.taskDescription = downloadId.uuidString
        task.resume()

        logger.info("Started download for '\(filename)' from \(repoId) (ID: \(downloadId))")
        return downloadId
    }

    /// Pauses an active download, capturing resume data if provided by the server.
    public func pauseDownload(id: UUID) async throws {
        guard let task = tasks[id] else {
            // If already paused, do nothing
            if var p = progressMap[id], p.status == .downloading {
                p = DownloadProgress(id: id, repoId: p.repoId, filename: p.filename, bytesDownloaded: p.bytesDownloaded, totalBytes: p.totalBytes, status: .paused)
                progressMap[id] = p
                try await database.updateDownloadProgress(id: id, downloadedBytes: p.bytesDownloaded, totalBytes: p.totalBytes, status: .paused, errorMessage: nil, resumeData: nil)
            }
            return
        }

        let resumeData = await task.cancelByProducingResumeData()
        tasks.removeValue(forKey: id)

        if let resumeData {
            resumeDataMap[id] = resumeData
        }

        if var progress = progressMap[id] {
            progress = DownloadProgress(
                id: id,
                repoId: progress.repoId,
                filename: progress.filename,
                bytesDownloaded: progress.bytesDownloaded,
                totalBytes: progress.totalBytes,
                status: .paused
            )
            progressMap[id] = progress
            try await database.updateDownloadProgress(
                id: id,
                downloadedBytes: progress.bytesDownloaded,
                totalBytes: progress.totalBytes,
                status: .paused,
                errorMessage: nil,
                resumeData: resumeData
            )
        }
        logger.info("Paused download ID \(id)")
    }

    /// Resumes a paused download using resume data or re-requesting from server.
    public func resumeDownload(id: UUID) async throws {
        // Idempotency guard: if task is already running in tasks[id], safe no-op
        if tasks[id] != nil, let p = progressMap[id], p.status == .downloading {
            logger.info("Download ID \(id) is already actively downloading; ignoring duplicate resume request.")
            return
        }

        guard let record = try await database.fetchDownload(id: id) else {
            throw ModelDownloadError.downloadNotFound(id)
        }

        // Re-check after suspension point to prevent concurrent resume races
        if tasks[id] != nil, let p = progressMap[id], p.status == .downloading {
            logger.info("Download ID \(id) was already resumed during await; ignoring duplicate resume request.")
            return
        }

        if session == nil {
            configureSession()
        }

        // Cancel any lingering task before creating a replacement to enforce single active task
        if let oldTask = tasks.removeValue(forKey: id) {
            oldTask.cancel()
        }

        let task: URLSessionDownloadTask
        if let resumeData = resumeDataMap[id] ?? record.resumeData,
           (try? PropertyListSerialization.propertyList(from: resumeData, options: [], format: nil)) is [String: Any] {
            task = session.downloadTask(withResumeData: resumeData)
        } else if let url = URL(string: record.remoteURL) {
            var req = URLRequest(url: url)
            req.setValue("Aether/1.0", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: req)
        } else {
            throw ModelDownloadError.networkError("Malformed remote URL for download ID \(id)")
        }

        tasks[id] = task
        task.taskDescription = id.uuidString

        let updatedProgress = DownloadProgress(
            id: id,
            repoId: record.repoId,
            filename: record.filename,
            bytesDownloaded: record.downloadedBytes,
            totalBytes: record.totalBytes,
            status: .downloading
        )
        progressMap[id] = updatedProgress
        try await database.updateDownloadProgress(
            id: id,
            downloadedBytes: record.downloadedBytes,
            totalBytes: record.totalBytes,
            status: .downloading,
            errorMessage: nil,
            resumeData: nil
        )

        task.resume()
        logger.info("Resumed download ID \(id)")
    }

    /// Cancels an active or paused download and cleans up partial disk files.
    public func cancelDownload(id: UUID) async throws {
        if let task = tasks.removeValue(forKey: id) {
            task.cancel()
        }
        resumeDataMap.removeValue(forKey: id)

        guard let record = try await database.fetchDownload(id: id) else { return }

        // Remove staging or partial file
        let stagingPath = "\(record.destinationPath).download"
        try? FileManager.default.removeItem(atPath: stagingPath)

        if var p = progressMap[id] {
            p = DownloadProgress(
                id: id,
                repoId: p.repoId,
                filename: p.filename,
                bytesDownloaded: p.bytesDownloaded,
                totalBytes: p.totalBytes,
                status: .cancelled
            )
            progressMap[id] = p
        }

        try await database.updateDownloadProgress(
            id: id,
            downloadedBytes: 0,
            totalBytes: record.totalBytes,
            status: .cancelled,
            errorMessage: "Cancelled by user",
            resumeData: nil
        )
        logger.info("Cancelled download ID \(id)")
    }

    public func getActiveDownloads() -> [DownloadProgress] {
        Array(progressMap.values.filter { $0.status == .downloading || $0.status == .pending || $0.status == .paused })
    }

    public func getAllDownloads() -> [DownloadProgress] {
        Array(progressMap.values)
    }

    public func getDownload(id: UUID) -> DownloadProgress? {
        progressMap[id]
    }

    // MARK: - Delegate Callbacks (Handled inside actor boundary)

    func handleBytesWritten(id: UUID, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) async {
        guard var progress = progressMap[id] else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : progress.totalBytes

        progress = DownloadProgress(
            id: id,
            repoId: progress.repoId,
            filename: progress.filename,
            bytesDownloaded: totalBytesWritten,
            totalBytes: total,
            status: .downloading
        )
        progressMap[id] = progress

        // Persist progress periodically (every 5 MB to avoid disk churn)
        if totalBytesWritten % (5 * 1024 * 1024) < 131072 {
            try? await database.updateDownloadProgress(
                id: id,
                downloadedBytes: totalBytesWritten,
                totalBytes: total,
                status: .downloading,
                errorMessage: nil,
                resumeData: nil
            )
        }
    }

    func handleDownloadFinished(id: UUID, temporaryLocation: URL) async {
        tasks.removeValue(forKey: id)
        guard let record = try? await database.fetchDownload(id: id) else { return }

        // If the download was already marked cancelled, discard the completed temporary file cleanly.
        if record.status == .cancelled {
            logger.info("Download for '\(record.filename)' was cancelled prior to completion; discarding.")
            try? FileManager.default.removeItem(at: temporaryLocation)
            return
        }

        let finalPath = record.destinationPath
        let stagingPath = "\(finalPath).download"
        let stagingURL = URL(fileURLWithPath: stagingPath)
        let finalURL = URL(fileURLWithPath: finalPath)

        // DEF-39-06: Track whether the file was moved to the final destination by this operation.
        var didMoveToFinalDestination = false

        do {
            // Move from temporary cache to persistent staging file
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: temporaryLocation, to: stagingURL)

            // GGUF VALIDATION BEFORE INSTALLATION
            logger.info("Validating downloaded GGUF file: \(stagingPath)")
            _ = try metadataReader.readMetadata(at: stagingPath)

            // DEF-39-06: Never overwrite or delete a pre-existing user file.
            if FileManager.default.fileExists(atPath: finalPath) {
                throw ModelDownloadError.alreadyDownloaded(record.filename)
            }

            // Atomic move to final destination
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
            didMoveToFinalDestination = true

            // Register with ModelLibraryService with clean, human-readable display title
            let cleanName = ModelCatalogNormalizer.normalize(
                installedName: record.filename,
                filePath: finalPath,
                architecture: ""
            )
            _ = try await modelLibraryService.registerModel(at: finalURL, customName: cleanName)

            // Mark completed in database
            let completedProgress = DownloadProgress(
                id: id,
                repoId: record.repoId,
                filename: record.filename,
                bytesDownloaded: record.totalBytes,
                totalBytes: record.totalBytes,
                status: .completed
            )
            progressMap[id] = completedProgress
            try await database.updateDownloadProgress(
                id: id,
                downloadedBytes: record.totalBytes,
                totalBytes: record.totalBytes,
                status: .completed,
                errorMessage: nil,
                resumeData: nil
            )
            logger.info("Successfully finished download & registered model: \(record.filename)")
        } catch {
            logger.error("Download completion failed for \(record.filename): \(error.localizedDescription)")

            // DEF-39-06: Clean up newly created final file if registration failed, or staging file if move hadn't occurred.
            if didMoveToFinalDestination {
                do {
                    try FileManager.default.removeItem(at: finalURL)
                    logger.info("DEF-39-06: Cleaned up orphaned final file at '\(finalPath)' after registration failure.")
                } catch {
                    logger.error("DEF-39-06: Failed to clean up orphaned final file at '\(finalPath)': \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: stagingURL)
            }

            let failedProgress = DownloadProgress(
                id: id,
                repoId: record.repoId,
                filename: record.filename,
                bytesDownloaded: record.downloadedBytes,
                totalBytes: record.totalBytes,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            progressMap[id] = failedProgress
            try? await database.updateDownloadProgress(
                id: id,
                downloadedBytes: record.downloadedBytes,
                totalBytes: record.totalBytes,
                status: .failed,
                errorMessage: error.localizedDescription,
                resumeData: nil
            )
        }
    }

    func handleTaskError(id: UUID, error: Error) async {
        tasks.removeValue(forKey: id)
        let nsError = error as NSError

        // Check if cancellation produced resume data
        if let resumeData = nsError.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
            resumeDataMap[id] = resumeData
        }

        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            // Handled cleanly via cancelDownload or pauseDownload
            return
        }

        if var progress = progressMap[id] {
            progress = DownloadProgress(
                id: id,
                repoId: progress.repoId,
                filename: progress.filename,
                bytesDownloaded: progress.bytesDownloaded,
                totalBytes: progress.totalBytes,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            progressMap[id] = progress
            try? await database.updateDownloadProgress(
                id: id,
                downloadedBytes: progress.bytesDownloaded,
                totalBytes: progress.totalBytes,
                status: .failed,
                errorMessage: error.localizedDescription,
                resumeData: resumeDataMap[id]
            )
        }
        logger.error("Download task \(id) failed: \(error.localizedDescription)")
    }

    // MARK: - Validation & Filesystem Safety

    public static func validateSafeFilename(_ filename: String) throws {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ModelDownloadError.invalidFilename(filename)
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(".."), !trimmed.hasPrefix(".") else {
            throw ModelDownloadError.unsafePath(filename)
        }
        guard trimmed.lowercased().hasSuffix(".gguf") else {
            throw ModelDownloadError.invalidFilename(filename)
        }
    }

    public static func validateSafeRepoId(_ repoId: String) throws {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(".."),
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("."),
              trimmed.contains("/") else {
            throw ModelDownloadError.unsafePath(repoId)
        }
    }

    private func targetDirectory(for repoId: String) -> URL {
        modelsBaseDirectory.appendingPathComponent(repoId, isDirectory: true)
    }

    private func checkDiskSpace(at folder: URL, requiredBytes: Int64) throws {
        guard requiredBytes > 0 else { return }
        do {
            let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            let safetyBuffer: Int64 = 500 * 1024 * 1024 // 500 MB safety headroom

            if available > 0 && available < (requiredBytes + safetyBuffer) {
                throw ModelDownloadError.insufficientDiskSpace(required: requiredBytes, available: available)
            }
        } catch let err as ModelDownloadError {
            throw err
        } catch {
            // In testing or virtual volume contexts where capacity query is unsupported, proceed cautiously
            logger.warning("Could not query disk space at \(folder.path): \(error.localizedDescription)")
        }
    }
}

// MARK: - URLSession Download Delegate Coordinator

final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var manager: ModelDownloadManager?

    init(manager: ModelDownloadManager) {
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let idStr = downloadTask.taskDescription, let id = UUID(uuidString: idStr) else { return }
        Task { [weak manager] in
            await manager?.handleBytesWritten(
                id: id,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let idStr = downloadTask.taskDescription, let id = UUID(uuidString: idStr) else { return }
        Task { [weak manager] in
            await manager?.handleDownloadFinished(id: id, temporaryLocation: location)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let idStr = task.taskDescription, let id = UUID(uuidString: idStr) else { return }
        if let error {
            Task { [weak manager] in
                await manager?.handleTaskError(id: id, error: error)
            }
        }
    }
}
