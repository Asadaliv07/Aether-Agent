import XCTest
@testable import Aether

final class ModelDownloadManagerTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: ConversationDatabase!
    private var modelLibraryService: ModelLibraryService!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let dbURL = tempDirectory.appendingPathComponent("test_downloads.sqlite")
        database = try ConversationDatabase(fileURL: dbURL)
        modelLibraryService = ModelLibraryService(database: database)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        database = nil
        modelLibraryService = nil
        try await super.tearDown()
    }

    // MARK: - Path Traversal & Filename Safety Tests

    func testSafeFilenameValidation() throws {
        // Valid GGUF filenames
        XCTAssertNoThrow(try ModelDownloadManager.validateSafeFilename("qwen2.5-coder-7b-instruct-q4_k_m.gguf"))
        XCTAssertNoThrow(try ModelDownloadManager.validateSafeFilename("meta-llama-3-8b.Q8_0.gguf"))
        XCTAssertNoThrow(try ModelDownloadManager.validateSafeFilename("Mistral-7B-v0.1.GGUF"))

        // Invalid extensions
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeFilename("model.bin")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .invalidFilename("model.bin"))
        }
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeFilename("model.safetensors")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .invalidFilename("model.safetensors"))
        }
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeFilename("script.sh")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .invalidFilename("script.sh"))
        }

        // Path traversal attempts
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeFilename("../evil.gguf")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .unsafePath("../evil.gguf"))
        }
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeFilename("subdir/model.gguf")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .unsafePath("subdir/model.gguf"))
        }
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeFilename("/absolute/path.gguf")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .unsafePath("/absolute/path.gguf"))
        }
    }

    func testSafeRepoIdValidation() throws {
        // Valid repos
        XCTAssertNoThrow(try ModelDownloadManager.validateSafeRepoId("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF"))
        XCTAssertNoThrow(try ModelDownloadManager.validateSafeRepoId("meta-llama/Meta-Llama-3-8B"))
        XCTAssertNoThrow(try ModelDownloadManager.validateSafeRepoId("TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF"))

        // Path traversal attempts
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeRepoId("../evil/repo")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .unsafePath("../evil/repo"))
        }
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeRepoId("org/../../evil")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .unsafePath("org/../../evil"))
        }
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeRepoId("/absolute/repo")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .unsafePath("/absolute/repo"))
        }

        // Missing slash
        XCTAssertThrowsError(try ModelDownloadManager.validateSafeRepoId("invalid-no-slash")) { error in
            XCTAssertEqual(error as? ModelDownloadError, .unsafePath("invalid-no-slash"))
        }
    }

    // MARK: - Overwrite & Duplicate Protection

    func testOverwriteProtectionRejectsExistingFile() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let repoId = "Qwen/Qwen2.5-Coder-7B"
        let filename = "qwen.gguf"

        // Create dummy existing file
        let repoDir = tempDirectory.appendingPathComponent(repoId)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let filePath = repoDir.appendingPathComponent(filename)
        try Data("dummy".utf8).write(to: filePath)

        let dummyURL = URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-7B/resolve/main/qwen.gguf")!

        do {
            _ = try await manager.startDownload(
                repoId: repoId,
                filename: filename,
                downloadURL: dummyURL,
                expectedSize: 1024
            )
            XCTFail("Expected alreadyDownloaded error")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .alreadyDownloaded(filename))
        }
    }

    // MARK: - Database Persistence & Recovery Tests

    func testDatabaseDownloadRecordCRUD() async throws {
        let downloadId = UUID()
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: "test-org/test-model",
            filename: "model-q4.gguf",
            remoteURL: "https://example.com/model-q4.gguf",
            destinationPath: "/tmp/models/test-org_test-model/model-q4.gguf",
            totalBytes: 5_000_000_000,
            downloadedBytes: 1_000_000_000,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: "resume-token".data(using: .utf8)
        )

        // Insert
        try await database.insertDownload(record)

        // Fetch by ID
        let fetched = try await database.fetchDownload(id: downloadId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.repoId, "test-org/test-model")
        XCTAssertEqual(fetched?.filename, "model-q4.gguf")
        XCTAssertEqual(fetched?.downloadedBytes, 1_000_000_000)
        XCTAssertEqual(fetched?.status, DownloadStatus.downloading)

        // Fetch by repoId & filename
        let fetchedByRepo = try await database.fetchDownload(repoId: "test-org/test-model", filename: "model-q4.gguf")
        XCTAssertNotNil(fetchedByRepo)
        XCTAssertEqual(fetchedByRepo?.id, downloadId)

        // Update progress
        try await database.updateDownloadProgress(
            id: downloadId,
            downloadedBytes: 2_500_000_000,
            totalBytes: 5_000_000_000,
            status: .paused,
            errorMessage: nil,
            resumeData: "new-resume-token".data(using: .utf8)
        )

        let updated = try await database.fetchDownload(id: downloadId)
        XCTAssertEqual(updated?.downloadedBytes, 2_500_000_000)
        XCTAssertEqual(updated?.status, DownloadStatus.paused)

        // List all
        let all = try await database.fetchDownloads()
        XCTAssertEqual(all.count, 1)

        // Delete
        try await database.deleteDownload(id: downloadId)
        let deleted = try await database.fetchDownload(id: downloadId)
        XCTAssertNil(deleted)
    }

    func testPersistedDownloadRecoveryOnStartup() async throws {
        let downloadId = UUID()
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: "meta-llama/Meta-Llama-3-8B",
            filename: "llama3-q4.gguf",
            remoteURL: "https://example.com/llama3.gguf",
            destinationPath: "/tmp/models/llama3-q4.gguf",
            totalBytes: 4_000_000_000,
            downloadedBytes: 1_500_000_000,
            status: .paused,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: "cached-data".data(using: .utf8)
        )
        try await database.insertDownload(record)

        // Create manager and load persisted downloads
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.loadPersistedDownloads()

        let downloads = await manager.getActiveDownloads()
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(downloads[0].id, downloadId)
        XCTAssertEqual(downloads[0].status, DownloadStatus.paused)
        XCTAssertEqual(downloads[0].bytesDownloaded, 1_500_000_000)
        XCTAssertEqual(downloads[0].totalBytes, 4_000_000_000)
    }

    // MARK: - Corrupt File Validation Rejection

    func testCorruptDownloadedFileRejectedAndCleanedUp() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let repoId = "test/corrupt-model"
        let filename = "corrupt.gguf"
        let targetDir = tempDirectory.appendingPathComponent(repoId)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let finalPath = targetDir.appendingPathComponent(filename).path

        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: "https://example.com/corrupt.gguf",
            destinationPath: finalPath,
            totalBytes: 100,
            downloadedBytes: 100,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        try await database.insertDownload(record)

        // Create corrupt temporary file (not GGUF magic)
        let corruptTempFile = tempDirectory.appendingPathComponent("corrupt.tmp")
        try Data("NOT_A_GGUF_FILE".utf8).write(to: corruptTempFile)

        // Simulate completion handler
        await manager.handleDownloadFinished(id: downloadId, temporaryLocation: corruptTempFile)

        let progress = await manager.getDownload(id: downloadId)
        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.status, DownloadStatus.failed)
        XCTAssertNotNil(progress?.errorMessage)

        // Staging file should be cleaned up
        let stagingPath = "\(finalPath).download"
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))

        // Final file should NOT have been created
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalPath))
    }

    // MARK: - DEF-39-03 Deduplication & Paused Download Resumption Tests

    final class MockDownloadURLProtocol: URLProtocol {
        nonisolated(unsafe) static var testHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            guard let handler = MockDownloadURLProtocol.testHandler else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "100"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 100))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeMockDownloadSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockDownloadURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testStartingPausedDownloadResumesExistingTask() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.configureSession(customSession: makeMockDownloadSession())

        let repoId = "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF"
        let filename = "tinyllama-1.1b-chat.Q4_K_M.gguf"
        let downloadURL = URL(string: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/\(filename)")!
        let totalBytes: Int64 = 669_000_000

        // 1. Start download
        let initialId = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: downloadURL,
            expectedSize: totalBytes
        )

        // 2. Pause download
        try await manager.pauseDownload(id: initialId)
        let pausedProgress = await manager.getDownload(id: initialId)
        XCTAssertEqual(pausedProgress?.status, .paused)

        // 3. Attempt to start the same download while paused
        let resumedId = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: downloadURL,
            expectedSize: totalBytes
        )

        // 4. Verify DEF-39-03: Reuses existing download identity, resumes it, does not create duplicate
        XCTAssertEqual(resumedId, initialId, "Starting a paused download must return the existing download ID")
        let activeDownloads = await manager.getActiveDownloads()
        XCTAssertEqual(activeDownloads.count, 1, "There must be exactly one download registered")
        let progress = await manager.getDownload(id: initialId)
        XCTAssertEqual(progress?.status, .downloading, "Download must transition to downloading")
    }

    func testRepeatedStartDownloadThrowsAlreadyDownloading() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.configureSession(customSession: makeMockDownloadSession())

        let repoId = "meta-llama/Meta-Llama-3-8B-Instruct-GGUF"
        let filename = "llama-3-8b-instruct.Q4_K_M.gguf"
        let downloadURL = URL(string: "https://huggingface.co/meta-llama/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/\(filename)")!

        // First start
        _ = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: downloadURL,
            expectedSize: 1024
        )

        // Repeated start must throw alreadyDownloading
        do {
            _ = try await manager.startDownload(
                repoId: repoId,
                filename: filename,
                downloadURL: downloadURL,
                expectedSize: 1024
            )
            XCTFail("Expected ModelDownloadError.alreadyDownloading")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .alreadyDownloading(filename))
        }
    }

    func testConcurrentStartDownloadPreservesSingleTask() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.configureSession(customSession: makeMockDownloadSession())

        let repoId = "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF"
        let filename = "qwen2.5-coder-7b-instruct.Q4_K_M.gguf"
        let downloadURL = URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/\(filename)")!

        // Fire 10 concurrent startDownload tasks
        let concurrencyCount = 10
        let results = await withTaskGroup(of: Result<UUID, Error>.self) { group in
            for _ in 0..<concurrencyCount {
                group.addTask {
                    do {
                        let id = try await manager.startDownload(
                            repoId: repoId,
                            filename: filename,
                            downloadURL: downloadURL,
                            expectedSize: 1024
                        )
                        return .success(id)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var res: [Result<UUID, Error>] = []
            for await r in group {
                res.append(r)
            }
            return res
        }

        let successes = results.compactMap { try? $0.get() }
        let failures = results.compactMap { res -> Error? in
            if case .failure(let err) = res { return err }
            return nil
        }

        XCTAssertEqual(successes.count, 1, "Exactly one concurrent start request must succeed")
        XCTAssertEqual(failures.count, concurrencyCount - 1, "All other concurrent requests must fail with alreadyDownloading")
        for fail in failures {
            guard let downloadErr = fail as? ModelDownloadError else {
                XCTFail("Unexpected error type: \(fail)")
                continue
            }
            XCTAssertEqual(downloadErr, .alreadyDownloading(filename))
        }

        // Database and in-memory invariants
        let allRecords = try await database.fetchDownloads()
        XCTAssertEqual(allRecords.count, 1, "Database must contain exactly 1 download record")
        let active = await manager.getActiveDownloads()
        XCTAssertEqual(active.count, 1, "Active downloads must contain exactly 1 entry")
    }

    func testConcurrentResumeRequestsPreserveSingleTask() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.configureSession(customSession: makeMockDownloadSession())

        let repoId = "mistralai/Mistral-7B-Instruct-v0.3-GGUF"
        let filename = "mistral-7b-instruct-v0.3.Q4_K_M.gguf"
        let downloadURL = URL(string: "https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/\(filename)")!

        let id = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: downloadURL,
            expectedSize: 2048
        )
        try await manager.pauseDownload(id: id)

        // Fire 5 concurrent resumeDownload requests
        let resumeCount = 5
        let results = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for _ in 0..<resumeCount {
                group.addTask {
                    do {
                        try await manager.resumeDownload(id: id)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var res: [Result<Void, Error>] = []
            for await r in group {
                res.append(r)
            }
            return res
        }

        // All resume requests should succeed idempotently
        let successes = results.compactMap { try? $0.get() }
        XCTAssertEqual(successes.count, resumeCount, "All concurrent resume requests should succeed idempotently without error")

        let progress = await manager.getDownload(id: id)
        XCTAssertEqual(progress?.status, .downloading)
        let active = await manager.getActiveDownloads()
        XCTAssertEqual(active.count, 1, "Single task invariant maintained")
    }

    func testResumeDataAndPartialFilesHandledCorrectly() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.configureSession(customSession: makeMockDownloadSession())

        let downloadId = UUID()
        let repoId = "google/gemma-2-2b-it-GGUF"
        let filename = "gemma-2-2b-it.Q4_K_M.gguf"
        let dummyResumeToken = "sample-urlsession-resume-data".data(using: .utf8)!
        let targetDir = tempDirectory.appendingPathComponent(repoId)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let finalPath = targetDir.appendingPathComponent(filename).path

        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: "https://huggingface.co/google/gemma-2-2b-it-GGUF/resolve/main/\(filename)",
            destinationPath: finalPath,
            totalBytes: 5000,
            downloadedBytes: 2500,
            status: .paused,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: dummyResumeToken
        )
        try await database.insertDownload(record)
        await manager.loadPersistedDownloads()

        // Verify paused state with resume data loaded
        let preProgress = await manager.getDownload(id: downloadId)
        XCTAssertEqual(preProgress?.status, .paused)
        XCTAssertEqual(preProgress?.bytesDownloaded, 2500)

        // Resuming from paused state via startDownload (DEF-39-03)
        let resumedId = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: URL(string: record.remoteURL)!,
            expectedSize: 5000
        )
        XCTAssertEqual(resumedId, downloadId)

        let postProgress = await manager.getDownload(id: downloadId)
        XCTAssertEqual(postProgress?.status, .downloading)
    }

    func testCancellationAndCompletedDownloadBehaviorRemainIntact() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.configureSession(customSession: makeMockDownloadSession())

        let repoId = "microsoft/Phi-3-mini-4k-instruct-gguf"
        let filename = "Phi-3-mini-4k-instruct-q4.gguf"
        let downloadURL = URL(string: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/\(filename)")!

        let id = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: downloadURL,
            expectedSize: 1024
        )

        // Cancel download
        try await manager.cancelDownload(id: id)
        let cancelledProgress = await manager.getDownload(id: id)
        XCTAssertEqual(cancelledProgress?.status, .cancelled, "Cancelled download records status as cancelled")

        // Record in DB should reflect cancelled
        let dbRecord = try await database.fetchDownload(id: id)
        XCTAssertEqual(dbRecord?.status, .cancelled)

        // Starting again after cancellation cleans up old record and starts fresh
        let newId = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: downloadURL,
            expectedSize: 1024
        )
        XCTAssertNotEqual(newId, id, "A cancelled download start creates a fresh download task")

        // Completed download behavior: starting an already completed download throws alreadyDownloaded
        try await database.updateDownloadProgress(
            id: newId,
            downloadedBytes: 1024,
            totalBytes: 1024,
            status: .completed,
            errorMessage: nil,
            resumeData: nil
        )
        await manager.loadPersistedDownloads()

        do {
            _ = try await manager.startDownload(
                repoId: repoId,
                filename: filename,
                downloadURL: downloadURL,
                expectedSize: 1024
            )
            XCTFail("Expected ModelDownloadError.alreadyDownloaded")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .alreadyDownloaded(filename))
        }
    }

    // MARK: - DEF-39-05 Interrupted Download Recovery Tests

    func testInterruptedDownloadingStateReconciledToPausedOnLaunch() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let repoId = "TheBloke/TinyLlama-1.1B"
        let filename = "tinyllama.gguf"
        let finalPath = tempDirectory.appendingPathComponent("tinyllama.gguf").path

        // Record left in .downloading from previous process crash/kill
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: "https://example.com/tinyllama.gguf",
            destinationPath: finalPath,
            totalBytes: 600_000_000,
            downloadedBytes: 300_000_000,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        try await database.insertDownload(record)

        // Launch app: load persisted downloads
        await manager.loadPersistedDownloads()

        // 1. In-memory status is reconciled to .paused
        let progress = await manager.getDownload(id: downloadId)
        XCTAssertEqual(progress?.status, .paused, "Interrupted .downloading record must be reconciled to .paused")
        XCTAssertEqual(progress?.bytesDownloaded, 300_000_000)

        // 2. Database record is updated to .paused with explanatory message
        let dbRecord = try await database.fetchDownload(id: downloadId)
        XCTAssertEqual(dbRecord?.status, .paused)
        XCTAssertTrue(dbRecord?.errorMessage?.localizedCaseInsensitiveContains("interrupted by application exit") == true)
    }

    func testInterruptedPendingStateReconciledToPausedOnLaunch() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: "test/repo",
            filename: "model.gguf",
            remoteURL: "https://example.com/model.gguf",
            destinationPath: tempDirectory.appendingPathComponent("model.gguf").path,
            totalBytes: 500_000_000,
            downloadedBytes: 0,
            status: .pending,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        try await database.insertDownload(record)

        await manager.loadPersistedDownloads()

        let progress = await manager.getDownload(id: downloadId)
        XCTAssertEqual(progress?.status, .paused, "Interrupted .pending record must be reconciled to .paused")
        let dbRecord = try await database.fetchDownload(id: downloadId)
        XCTAssertEqual(dbRecord?.status, .paused)
    }

    func testInterruptedDownloadWithValidResumeDataPreservesResumeData() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let resumeDict: [String: Any] = [
            "NSURLSessionResumeBytesReceived": 1024,
            "NSURLSessionResumeCurrentRequest": "dummy"
        ]
        let validResumeData = try PropertyListSerialization.data(fromPropertyList: resumeDict, format: .binary, options: 0)

        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: "test/valid-resume",
            filename: "valid.gguf",
            remoteURL: "https://example.com/valid.gguf",
            destinationPath: tempDirectory.appendingPathComponent("valid.gguf").path,
            totalBytes: 10_000,
            downloadedBytes: 1024,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: validResumeData
        )
        try await database.insertDownload(record)

        await manager.loadPersistedDownloads()

        let dbRecord = try await database.fetchDownload(id: downloadId)
        XCTAssertEqual(dbRecord?.status, .paused)
        XCTAssertNotNil(dbRecord?.resumeData, "Valid property-list resume data must be preserved on recovery")
        XCTAssertEqual(dbRecord?.resumeData, validResumeData)
    }

    func testInterruptedDownloadWithCorruptResumeDataClearsCorruptData() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let corruptResumeData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03]) // Corrupt non-plist bytes

        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: "test/corrupt-resume",
            filename: "corrupt.gguf",
            remoteURL: "https://example.com/corrupt.gguf",
            destinationPath: tempDirectory.appendingPathComponent("corrupt.gguf").path,
            totalBytes: 10_000,
            downloadedBytes: 500,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: corruptResumeData
        )
        try await database.insertDownload(record)

        await manager.loadPersistedDownloads()

        let dbRecord = try await database.fetchDownload(id: downloadId)
        XCTAssertEqual(dbRecord?.status, .paused)
        XCTAssertNil(dbRecord?.resumeData, "Corrupt resume data must be discarded to allow clean restart")
    }

    func testRepeatedRecoveryIsIdempotent() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: "test/idempotent",
            filename: "idem.gguf",
            remoteURL: "https://example.com/idem.gguf",
            destinationPath: tempDirectory.appendingPathComponent("idem.gguf").path,
            totalBytes: 5000,
            downloadedBytes: 2500,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        try await database.insertDownload(record)

        // Run recovery 3 times
        await manager.loadPersistedDownloads()
        await manager.loadPersistedDownloads()
        await manager.loadPersistedDownloads()

        let downloads = await manager.getAllDownloads()
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(downloads.first?.status, .paused)
        XCTAssertEqual(downloads.first?.bytesDownloaded, 2500)
    }

    func testDuplicateStartPreventionAfterInterruptedRecovery() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )
        await manager.configureSession(customSession: makeMockDownloadSession())

        let downloadId = UUID()
        let repoId = "test/duplicate-prevention"
        let filename = "prevent.gguf"
        let finalPath = tempDirectory.appendingPathComponent(repoId).appendingPathComponent(filename).path
        let url = URL(string: "https://example.com/prevent.gguf")!

        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: url.absoluteString,
            destinationPath: finalPath,
            totalBytes: 5000,
            downloadedBytes: 1000,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        try await database.insertDownload(record)

        // Recovery reconciles to .paused
        await manager.loadPersistedDownloads()

        // Calling startDownload on the recovered item should resume the existing task, NOT throw or create duplicate
        let returnedId = try await manager.startDownload(
            repoId: repoId,
            filename: filename,
            downloadURL: url,
            expectedSize: 5000
        )
        XCTAssertEqual(returnedId, downloadId, "startDownload must return the existing download ID")

        let allDownloads = await manager.getAllDownloads()
        XCTAssertEqual(allDownloads.count, 1, "Must maintain exactly one record without duplication")
        XCTAssertEqual(allDownloads.first?.status, .downloading)
    }

    // MARK: - DEF-39-06 Registration Failure Cleanup Tests

    private func createValidDummyGGUF(at destinationURL: URL) throws {
        var data = Data()
        // magic "GGUF"
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46])
        // version 3 (UInt32 little endian)
        var version: UInt32 = 3
        data.append(Data(bytes: &version, count: 4))
        // n_tensors: 0 (UInt64 little endian)
        var nTensors: UInt64 = 0
        data.append(Data(bytes: &nTensors, count: 8))
        // n_kv: 1 (UInt64 little endian)
        var nKV: UInt64 = 1
        data.append(Data(bytes: &nKV, count: 8))

        // Key: "general.architecture"
        let key = "general.architecture"
        var keyLen = UInt64(key.utf8.count)
        data.append(Data(bytes: &keyLen, count: 8))
        data.append(contentsOf: key.utf8)

        // Type: GGUF_TYPE_STRING = 8 (UInt32)
        var valType: UInt32 = 8
        data.append(Data(bytes: &valType, count: 4))

        // Val: "qwen2"
        let val = "qwen2"
        var valLen = UInt64(val.utf8.count)
        data.append(Data(bytes: &valLen, count: 8))
        data.append(contentsOf: val.utf8)

        try data.write(to: destinationURL)
    }

    func testRegistrationFailureCleansUpNewlyMovedFinalFile() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let repoId = "test/cleanup-on-fail"
        let filename = "cleanup-test.gguf"
        let repoDir = tempDirectory.appendingPathComponent(repoId)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let finalURL = repoDir.appendingPathComponent(filename)
        let finalPath = finalURL.path

        // Pre-insert a model record in the database with the same path.
        // This will cause modelLibraryService.registerModel to throw ModelLibraryError.duplicateModel
        // AFTER the file is moved to finalURL!
        let preExistingRecord = ModelRecord(
            name: "Duplicate Path Model",
            filePath: finalPath,
            fileSize: 1024,
            architecture: "qwen2",
            quantization: "Q4_0",
            contextLength: 2048
        )
        _ = try await database.insertModel(preExistingRecord)

        // Insert download record
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: "https://example.com/\(filename)",
            destinationPath: finalPath,
            totalBytes: 1024,
            downloadedBytes: 1024,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        _ = try await database.insertDownload(record)

        // Create temporary GGUF file
        let tempFile = tempDirectory.appendingPathComponent("temp-\(downloadId).tmp")
        try createValidDummyGGUF(at: tempFile)

        // Run handleDownloadFinished
        await manager.handleDownloadFinished(id: downloadId, temporaryLocation: tempFile)

        // Verify outcomes:
        // 1. Download status marked failed
        let progress = await manager.getDownload(id: downloadId)
        XCTAssertEqual(progress?.status, .failed)
        XCTAssertNotNil(progress?.errorMessage)

        // 2. DEF-39-06: The newly moved final file MUST have been cleaned up and deleted!
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalPath), "Orphaned final file must be removed when registration fails")

        // 3. Staging file must also be removed
        let stagingPath = "\(finalPath).download"
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath), "Staging file must be cleaned up")
    }

    func testPreExistingDestinationFileNeverOverwrittenOrDeleted() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let repoId = "test/protect-user-file"
        let filename = "precious.gguf"
        let repoDir = tempDirectory.appendingPathComponent(repoId)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let finalURL = repoDir.appendingPathComponent(filename)
        let finalPath = finalURL.path

        // Write pre-existing user data to finalPath
        let originalContent = "User's precious pre-existing file content".data(using: .utf8)!
        try originalContent.write(to: finalURL)

        // Insert download record
        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: "https://example.com/\(filename)",
            destinationPath: finalPath,
            totalBytes: 1024,
            downloadedBytes: 1024,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        _ = try await database.insertDownload(record)

        // Create temporary GGUF file
        let tempFile = tempDirectory.appendingPathComponent("temp-\(downloadId).tmp")
        try createValidDummyGGUF(at: tempFile)

        // Run handleDownloadFinished
        await manager.handleDownloadFinished(id: downloadId, temporaryLocation: tempFile)

        // Verify outcomes:
        // 1. Download status marked failed with alreadyDownloaded error
        let progress = await manager.getDownload(id: downloadId)
        XCTAssertEqual(progress?.status, .failed)

        // 2. DEF-39-06: Pre-existing user file MUST still exist and remain untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath), "Pre-existing file must never be deleted")
        let readData = try Data(contentsOf: finalURL)
        XCTAssertEqual(readData, originalContent, "Pre-existing user file content must never be overwritten")
    }

    func testSuccessfulDownloadAndRegistrationPreservesFinalFile() async throws {
        let manager = ModelDownloadManager(
            database: database,
            modelLibraryService: modelLibraryService,
            modelsBaseDirectory: tempDirectory
        )

        let downloadId = UUID()
        let repoId = "test/successful-flow"
        let filename = "success.gguf"
        let repoDir = tempDirectory.appendingPathComponent(repoId)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let finalURL = repoDir.appendingPathComponent(filename)
        let finalPath = finalURL.path

        let record = ModelDownloadRecord(
            id: downloadId,
            repoId: repoId,
            filename: filename,
            remoteURL: "https://example.com/\(filename)",
            destinationPath: finalPath,
            totalBytes: 1024,
            downloadedBytes: 1024,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date(),
            resumeData: nil
        )
        _ = try await database.insertDownload(record)

        let tempFile = tempDirectory.appendingPathComponent("temp-\(downloadId).tmp")
        try createValidDummyGGUF(at: tempFile)

        await manager.handleDownloadFinished(id: downloadId, temporaryLocation: tempFile)

        // 1. Download completed
        let progress = await manager.getDownload(id: downloadId)
        XCTAssertEqual(progress?.status, .completed)

        // 2. File exists at finalPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath))

        // 3. Registered in ModelLibrary database
        let model = try await database.fetchModel(byPath: finalPath)
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.architecture, "qwen2")
        XCTAssertEqual(model?.quantization, "Unknown")
    }
}
