import XCTest
import SQLite3
@testable import Aether

final class ModelLibraryTests: XCTestCase {

    private var tempDirectory: URL!
    private var testDatabaseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherModelLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        testDatabaseURL = tempDirectory.appendingPathComponent("test.sqlite")
    }

    override func tearDown() async throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - GGUF Metadata Reader Tests

    func testGGUFMagicValidationFailsOnGarbageFile() throws {
        let garbageFile = tempDirectory.appendingPathComponent("garbage.bin")
        try "Not a GGUF file at all".write(to: garbageFile, atomically: true, encoding: .utf8)

        let reader = GGUFMetadataReader()
        XCTAssertThrowsError(try reader.readMetadata(at: garbageFile.path)) { error in
            guard let libError = error as? ModelLibraryError else {
                XCTFail("Expected ModelLibraryError, got \(error)")
                return
            }
            if case .invalidGGUF(let reason) = libError {
                XCTAssertTrue(reason.contains("Magic header mismatch"), "Should detect non-GGUF magic: \(reason)")
            } else {
                XCTFail("Expected .invalidGGUF, got \(libError)")
            }
        }
    }

    func testGGUFMagicValidationFailsOnTruncatedFile() throws {
        let truncatedFile = tempDirectory.appendingPathComponent("truncated.bin")
        try Data([0x47, 0x47]).write(to: truncatedFile) // Only 2 bytes

        let reader = GGUFMetadataReader()
        XCTAssertThrowsError(try reader.readMetadata(at: truncatedFile.path)) { error in
            guard let libError = error as? ModelLibraryError else {
                XCTFail("Expected ModelLibraryError, got \(error)")
                return
            }
            if case .invalidGGUF(let reason) = libError {
                XCTAssertTrue(reason.contains("truncated") || reason.contains("smaller than 4 bytes"), "Should report truncated: \(reason)")
            } else {
                XCTFail("Expected .invalidGGUF, got \(libError)")
            }
        }
    }

    func testGGUFMissingFileThrowsFileNotFound() {
        let missingPath = tempDirectory.appendingPathComponent("nonexistent.gguf").path
        let reader = GGUFMetadataReader()
        XCTAssertThrowsError(try reader.readMetadata(at: missingPath)) { error in
            guard let libError = error as? ModelLibraryError else {
                XCTFail("Expected ModelLibraryError, got \(error)")
                return
            }
            XCTAssertEqual(libError, .fileNotFound(missingPath))
        }
    }

    func testGGUFDirectoryPathThrowsInvalidGGUF() {
        let reader = GGUFMetadataReader()
        XCTAssertThrowsError(try reader.readMetadata(at: tempDirectory.path)) { error in
            guard let libError = error as? ModelLibraryError else {
                XCTFail("Expected ModelLibraryError, got \(error)")
                return
            }
            if case .invalidGGUF(let reason) = libError {
                XCTAssertTrue(reason.contains("directory"), "Should reject directory path: \(reason)")
            } else {
                XCTFail("Expected .invalidGGUF, got \(libError)")
            }
        }
    }

    func testRealModelFixtureHeaderInspectionIfAvailable() throws {
        let candidatePaths = [
            "/Users/asadalishaikh/Desktop/qwen2.5-coder/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463",
            "/Users/asadalishaikh/.ollama/models/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463"
        ]
        guard let localFixturePath = candidatePaths.first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            print("Skipping real fixture test: fixture not readable or not present.")
            return
        }

        let reader = GGUFMetadataReader()
        let metadata = try reader.readMetadata(at: localFixturePath)

        XCTAssertEqual(metadata.architecture, "qwen2")
        XCTAssertEqual(metadata.quantization, "Q4_K_M")
        XCTAssertEqual(metadata.contextLength, 32768)
        XCTAssertEqual(metadata.blockCount, 28)
        XCTAssertGreaterThan(metadata.tensorCount, 300)

        let compat = reader.evaluateCompatibility(metadata: metadata, fileSize: 4_683_074_048)
        XCTAssertTrue(compat.isUsable, "Qwen2.5-Coder 7B Q4_K_M must evaluate as usable.")
    }

    // MARK: - DEF-39-04 Runtime Memory Assessment Tests

    /// 1. Small compatible model with known metadata.
    func testSmallCompatibleModelWithKnownMetadata() {
        let metadata = GGUFMetadata(
            architecture: "llama",
            name: "TinyLlama-1.1B-Chat-v1.0",
            quantization: "Q4_K_M",
            contextLength: 2048,
            blockCount: 22,
            parameterCount: 1_100_000_000,
            tensorCount: 201,
            chatTemplate: nil,
            license: "apache-2.0",
            headCount: 32,
            headCountKV: 4,
            embeddingLength: 2048,
            keyLength: 64
        )
        let fileSize: Int64 = 669 * 1024 * 1024 // ~669 MiB

        // Test on 8 GB RAM tier (8 * 1024^3 bytes)
        let ram8GB: UInt64 = 8 * 1024 * 1024 * 1024
        let estimate8GB = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: fileSize,
            hostRAM: ram8GB
        )

        XCTAssertEqual(estimate8GB.weightBytes, fileSize)
        // KV cache: 2 * 22 layers * 4 kv heads * 64 head dim * 2.0 (f16) * 2048 ctx = 46,137,344 bytes (~44 MiB)
        XCTAssertEqual(estimate8GB.kvCacheBytes, 46_137_344)
        XCTAssertEqual(estimate8GB.computeBufferBytes, 250 * 1024 * 1024) // 250 MiB min
        XCTAssertEqual(estimate8GB.applicationReserveBytes, 200 * 1024 * 1024) // 200 MiB
        XCTAssertEqual(estimate8GB.systemReserveBytes, Int64(3.0 * 1024 * 1024 * 1024)) // 3.0 GiB on 8 GB tier
        XCTAssertEqual(estimate8GB.effectiveHeadroomBytes, Int64(5.0 * 1024 * 1024 * 1024)) // 5.0 GiB
        XCTAssertTrue(estimate8GB.isCompatible)
        XCTAssertNil(estimate8GB.warningReason)

        let reader = GGUFMetadataReader()
        let compat = reader.evaluateCompatibility(metadata: metadata, fileSize: fileSize, hostRAM: ram8GB)
        XCTAssertEqual(compat, .compatible)
        XCTAssertTrue(compat.isUsable)
    }

    /// 2. Model that exceeds the conservative memory budget.
    func testModelExceedsConservativeMemoryBudget() {
        let metadata = GGUFMetadata(
            architecture: "llama",
            name: "Llama-3-70B-Instruct-Q4_K_M",
            quantization: "Q4_K_M",
            contextLength: 4096,
            blockCount: 80,
            parameterCount: 70_000_000_000,
            tensorCount: 723,
            chatTemplate: nil,
            license: "llama3",
            headCount: 64,
            headCountKV: 8,
            embeddingLength: 8192,
            keyLength: 128
        )
        // 42 GB quantized weight file on 16 GB machine
        let fileSize: Int64 = 42 * 1024 * 1024 * 1024
        let ram16GB: UInt64 = 16 * 1024 * 1024 * 1024

        let estimate = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: fileSize,
            hostRAM: ram16GB
        )

        XCTAssertFalse(estimate.isCompatible)
        XCTAssertNotNil(estimate.warningReason)
        XCTAssertTrue(estimate.warningReason!.contains("exceeds conservative budget"))

        let reader = GGUFMetadataReader()
        let compat = reader.evaluateCompatibility(metadata: metadata, fileSize: fileSize, hostRAM: ram16GB)
        if case .memoryWarning(let warning) = compat {
            XCTAssertTrue(warning.contains("Estimated runtime memory demand"))
        } else {
            XCTFail("Expected .memoryWarning, got \(compat)")
        }
        XCTAssertTrue(compat.isUsable, "Models exceeding budget are usable with warning")
    }

    /// 3. Context-length increases that raise KV cache demand.
    func testContextLengthIncreasesRaiseKVCacheDemand() {
        let metadata = GGUFMetadata(
            architecture: "qwen2",
            name: "Qwen2.5-7B-Instruct",
            quantization: "Q4_K_M",
            contextLength: 32768,
            blockCount: 28,
            parameterCount: 7_000_000_000,
            tensorCount: 338,
            chatTemplate: nil,
            license: "apache-2.0",
            headCount: 28,
            headCountKV: 4,
            embeddingLength: 3584,
            keyLength: 128
        )
        let fileSize: Int64 = 4_683_074_048 // ~4.36 GiB
        let ram16GB: UInt64 = 16 * 1024 * 1024 * 1024 // 16 GB RAM -> headroom = 11.5 GB

        // At 2048 context length
        let est2048 = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: fileSize,
            targetContextLength: 2048,
            hostRAM: ram16GB
        )
        // KV cache: 2 * 28 * 4 * 128 * 2.0 * 2048 = 117,440,512 bytes (~112 MiB)
        XCTAssertEqual(est2048.kvCacheBytes, 117_440_512)
        XCTAssertTrue(est2048.isCompatible)

        // At 65536 context length (32x increase)
        let est65536 = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: fileSize,
            targetContextLength: 65536,
            hostRAM: ram16GB
        )
        // KV cache: exactly 32 * 117_440_512 = 3,758,096,384 bytes (~3.5 GiB)
        XCTAssertEqual(est65536.kvCacheBytes, est2048.kvCacheBytes * 32)
        XCTAssertEqual(est65536.kvCacheBytes, 3_758_096_384)

        // Now test on 8 GB RAM tier (Headroom 5.0 GB):
        let ram8GB: UInt64 = 8 * 1024 * 1024 * 1024 // 8 GB RAM -> headroom = 5.0 GB
        // At 2048: 4.36 GB weight + 0.11 GB KV + 0.25 GB compute + 0.20 GB app = 4.92 GB <= 5.0 GB -> Compatible!
        let est8GB_2048 = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: fileSize,
            targetContextLength: 2048,
            hostRAM: ram8GB
        )
        XCTAssertTrue(est8GB_2048.isCompatible)

        // At 8192: KV cache increases to 469 MB -> Total demand becomes 5.28 GB > 5.0 GB -> Incompatible!
        let est8GB_8192 = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: fileSize,
            targetContextLength: 8192,
            hostRAM: ram8GB
        )
        XCTAssertFalse(est8GB_8192.isCompatible, "Context increase must push borderline model into memory warning")
    }

    /// 4. Different KV-head counts and cache data types where supported.
    func testDifferentKVHeadCountsAndCacheDataTypes() {
        // Base metadata: 32 layers, head dim 128, context length 4096
        func makeMeta(kvHeads: Int) -> GGUFMetadata {
            GGUFMetadata(
                architecture: "llama",
                name: "TestArch",
                quantization: "Q4_0",
                contextLength: 4096,
                blockCount: 32,
                parameterCount: 7_000_000_000,
                tensorCount: 291,
                chatTemplate: nil,
                license: nil,
                headCount: 32,
                headCountKV: kvHeads,
                embeddingLength: 4096,
                keyLength: 128
            )
        }

        let mhaMeta = makeMeta(kvHeads: 32) // MHA (Multi-Head Attention)
        let gqaMeta = makeMeta(kvHeads: 8)  // GQA (Grouped-Query Attention)
        let mqaMeta = makeMeta(kvHeads: 1)  // MQA (Multi-Query Attention)

        let dummyFileSize: Int64 = 4 * 1024 * 1024 * 1024

        // 1. KV-head count ratios with F16 cache
        let estMHA = GGUFMetadataReader.estimateRuntimeMemory(metadata: mhaMeta, fileSize: dummyFileSize, cacheType: .f16)
        let estGQA = GGUFMetadataReader.estimateRuntimeMemory(metadata: gqaMeta, fileSize: dummyFileSize, cacheType: .f16)
        let estMQA = GGUFMetadataReader.estimateRuntimeMemory(metadata: mqaMeta, fileSize: dummyFileSize, cacheType: .f16)

        // MHA (32 heads) should be 4x GQA (8 heads) and 32x MQA (1 head)
        XCTAssertEqual(estMHA.kvCacheBytes, estGQA.kvCacheBytes * 4)
        XCTAssertEqual(estMHA.kvCacheBytes, estMQA.kvCacheBytes * 32)

        // 2. Cache data types: F32 (4.0 B), F16 (2.0 B), Q8_0 (1.0625 B), Q4_0 (0.5625 B)
        let estF32 = GGUFMetadataReader.estimateRuntimeMemory(metadata: gqaMeta, fileSize: dummyFileSize, cacheType: .f32)
        let estF16 = GGUFMetadataReader.estimateRuntimeMemory(metadata: gqaMeta, fileSize: dummyFileSize, cacheType: .f16)
        let estQ8 = GGUFMetadataReader.estimateRuntimeMemory(metadata: gqaMeta, fileSize: dummyFileSize, cacheType: .q8_0)
        let estQ4 = GGUFMetadataReader.estimateRuntimeMemory(metadata: gqaMeta, fileSize: dummyFileSize, cacheType: .q4_0)

        // F32 should be exactly 2x F16
        XCTAssertEqual(estF32.kvCacheBytes, estF16.kvCacheBytes * 2)

        // Q8_0 (34/32 bytes/elem) vs F16 (2.0 bytes/elem)
        let expectedQ8Bytes = Int64(Double(estF16.kvCacheBytes) * (1.0625 / 2.0))
        XCTAssertEqual(estQ8.kvCacheBytes, expectedQ8Bytes)

        // Q4_0 (18/32 bytes/elem) vs F16 (2.0 bytes/elem)
        let expectedQ4Bytes = Int64(Double(estF16.kvCacheBytes) * (0.5625 / 2.0))
        XCTAssertEqual(estQ4.kvCacheBytes, expectedQ4Bytes)
        XCTAssertLessThan(estQ4.kvCacheBytes, estF16.kvCacheBytes / 3)
    }

    /// 5. Missing architecture or tensor metadata.
    func testMissingArchitectureOrTensorMetadata() {
        let reader = GGUFMetadataReader()

        // 5a. Missing / empty architecture
        let emptyArchMeta = GGUFMetadata(
            architecture: "  ",
            name: "EmptyArch",
            quantization: "Q4_0",
            contextLength: 2048,
            blockCount: 32,
            parameterCount: nil,
            tensorCount: 100,
            chatTemplate: nil,
            license: nil
        )
        let resEmpty = reader.evaluateCompatibility(metadata: emptyArchMeta, fileSize: 1024 * 1024 * 1024)
        XCTAssertFalse(resEmpty.isUsable)
        if case .unknown(let reason) = resEmpty {
            XCTAssertTrue(reason.contains("Architecture is unverified or missing"))
        } else {
            XCTFail("Expected .unknown for empty architecture, got \(resEmpty)")
        }

        // 5b. Missing tensor metadata (tensorCount <= 0)
        let zeroTensorMeta = GGUFMetadata(
            architecture: "llama",
            name: "NoTensors",
            quantization: "Q4_0",
            contextLength: 2048,
            blockCount: 32,
            parameterCount: nil,
            tensorCount: 0,
            chatTemplate: nil,
            license: nil
        )
        let resZeroTensor = reader.evaluateCompatibility(metadata: zeroTensorMeta, fileSize: 1024 * 1024 * 1024)
        XCTAssertFalse(resZeroTensor.isUsable)
        if case .unknown(let reason) = resZeroTensor {
            XCTAssertTrue(reason.contains("tensor metadata is missing or invalid"))
        } else {
            XCTFail("Expected .unknown for zero tensorCount, got \(resZeroTensor)")
        }

        // 5c. Zero or negative file size
        let normalMeta = GGUFMetadata(
            architecture: "llama",
            name: "ValidMeta",
            quantization: "Q4_0",
            contextLength: 2048,
            blockCount: 32,
            parameterCount: nil,
            tensorCount: 200,
            chatTemplate: nil,
            license: nil
        )
        let resZeroSize = reader.evaluateCompatibility(metadata: normalMeta, fileSize: 0)
        XCTAssertFalse(resZeroSize.isUsable)
        if case .unknown(let reason) = resZeroSize {
            XCTAssertTrue(reason.contains("File size unknown or non-positive"))
        } else {
            XCTFail("Expected .unknown for zero fileSize, got \(resZeroSize)")
        }

        let resNegSize = reader.evaluateCompatibility(metadata: normalMeta, fileSize: -500)
        XCTAssertFalse(resNegSize.isUsable)
        if case .unknown(let reason) = resNegSize {
            XCTAssertTrue(reason.contains("File size unknown or non-positive"))
        } else {
            XCTFail("Expected .unknown for negative fileSize, got \(resNegSize)")
        }
    }

    /// 6. Overflow and invalid numeric inputs.
    func testOverflowAndInvalidNumericInputs() {
        let metadata = GGUFMetadata(
            architecture: "llama",
            name: "OverflowTest",
            quantization: "Q4_0",
            contextLength: Int.max,
            blockCount: Int.max,
            parameterCount: nil,
            tensorCount: 500,
            chatTemplate: nil,
            license: nil,
            headCount: Int.max,
            headCountKV: Int.max,
            embeddingLength: Int.max,
            keyLength: Int.max
        )

        // Ensure calculation does not crash with fatalError or overflow exception
        let estimate = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: Int64.max,
            targetContextLength: Int.max,
            hostRAM: UInt64.max
        )

        XCTAssertFalse(estimate.isCompatible)
        XCTAssertNotNil(estimate.warningReason)

        // Negative context length input
        let negativeCtxEstimate = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: 1024,
            targetContextLength: -1024,
            hostRAM: 16 * 1024 * 1024 * 1024
        )
        // safeCtx guards with max(1, ...)
        XCTAssertGreaterThan(negativeCtxEstimate.computeBufferBytes, 0)
        XCTAssertGreaterThan(negativeCtxEstimate.kvCacheBytes, 0)
    }

    /// 7. 8 GB and 16 GB memory configurations.
    func test8GBAnd16GBMemoryConfigurations() {
        let ram8GB: UInt64 = 8 * 1024 * 1024 * 1024
        let ram16GB: UInt64 = 16 * 1024 * 1024 * 1024
        let ram32GB: UInt64 = 32 * 1024 * 1024 * 1024

        // macOS system reserve tiered values
        let res8 = GGUFMetadataReader.systemReserveBytes(for: ram8GB)
        let res16 = GGUFMetadataReader.systemReserveBytes(for: ram16GB)
        let res32 = GGUFMetadataReader.systemReserveBytes(for: ram32GB)

        XCTAssertEqual(res8, Int64(3.0 * 1024 * 1024 * 1024), "8 GB tier must reserve 3.0 GB for macOS")
        XCTAssertEqual(res16, Int64(4.5 * 1024 * 1024 * 1024), "16 GB tier must reserve 4.5 GB for macOS")
        XCTAssertEqual(res32, Int64(5.5 * 1024 * 1024 * 1024), "24+ GB tier must reserve 5.5 GB for macOS")

        // Headrooms
        let headroom8 = Int64(ram8GB) - res8
        let headroom16 = Int64(ram16GB) - res16
        XCTAssertEqual(headroom8, Int64(5.0 * 1024 * 1024 * 1024), "Effective headroom on 8 GB is 5.0 GB")
        XCTAssertEqual(headroom16, Int64(11.5 * 1024 * 1024 * 1024), "Effective headroom on 16 GB is 11.5 GB")
    }

    /// 8. Unknown or unsupported architecture.
    func testUnknownOrUnsupportedArchitecture() {
        let reader = GGUFMetadataReader()

        let unsupportedArchitectures = ["unknown_weird_arch", "mamba", "rwkv", "chinchilla", "custom_transformer"]
        for arch in unsupportedArchitectures {
            let meta = GGUFMetadata(
                architecture: arch,
                name: "Model-\(arch)",
                quantization: "Q4_0",
                contextLength: 2048,
                blockCount: 32,
                parameterCount: nil,
                tensorCount: 200,
                chatTemplate: nil,
                license: nil
            )
            let result = reader.evaluateCompatibility(metadata: meta, fileSize: 1024 * 1024 * 1024)
            XCTAssertFalse(result.isUsable)
            XCTAssertEqual(result, .unsupportedArchitecture(arch))
            XCTAssertEqual(result.displayMessage, "Unsupported architecture: \(arch)")
        }
    }

    /// 9. Existing compatibility UI behavior and regression cases.
    func testCompatibilityUIBehaviorAndRegressionCases() {
        // UI Helpers on ModelCompatibility
        let comp = ModelCompatibility.compatible
        XCTAssertTrue(comp.isUsable)
        XCTAssertNil(comp.displayMessage)

        let memWarn = ModelCompatibility.memoryWarning("High memory demand")
        XCTAssertTrue(memWarn.isUsable, "Memory warning models must remain usable in UI")
        XCTAssertEqual(memWarn.displayMessage, "Memory warning: High memory demand")

        let unsupp = ModelCompatibility.unsupportedArchitecture("falcon")
        XCTAssertFalse(unsupp.isUsable, "Unsupported models must be disabled in UI")
        XCTAssertEqual(unsupp.displayMessage, "Unsupported architecture: falcon")

        let unknown = ModelCompatibility.unknown("Need more data")
        XCTAssertFalse(unknown.isUsable, "Unknown compatibility models must be disabled in UI")
        XCTAssertEqual(unknown.displayMessage, "Compatibility unknown: Need more data")

        // Remote GGUF compatibility evaluation via HuggingFaceQuantUtils
        let ram16GB: UInt64 = 16 * 1024 * 1024 * 1024
        let smallRemote = HuggingFaceQuantUtils.evaluateFileCompatibility(
            architecture: "llama",
            fileSize: 2 * 1024 * 1024 * 1024,
            hostRAM: ram16GB
        )
        XCTAssertEqual(smallRemote, .compatible)

        let hugeRemote = HuggingFaceQuantUtils.evaluateFileCompatibility(
            architecture: "llama",
            fileSize: 25 * 1024 * 1024 * 1024,
            hostRAM: ram16GB
        )
        if case .memoryWarning(let w) = hugeRemote {
            XCTAssertTrue(w.contains("exceeds conservative budget"))
        } else {
            XCTFail("Expected .memoryWarning for 25 GB file on 16 GB RAM")
        }
    }

    // MARK: - Persistence & Migration Tests

    func testFreshDatabaseSchemaContainsModelsTable() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let models = try await db.fetchModels()
        XCTAssertEqual(models.count, 0, "Fresh database must start with an empty models catalog.")
    }

    func testMigrationV1ToV2PreservesExistingConversationsAndMessages() async throws {
        // 1. Manually initialize a v1 database
        let v1DbURL = tempDirectory.appendingPathComponent("v1_test.sqlite")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(v1DbURL.path, &handle, flags, nil), SQLITE_OK)

        // Run v1 creation manually
        let v1SQL = """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, model_name TEXT);
            CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, created_at REAL NOT NULL, status TEXT NOT NULL, token_count INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE);
            INSERT INTO schema_migrations (version, applied_at) VALUES (1, 1000.0);
            INSERT INTO conversations (id, title, created_at, updated_at, model_name) VALUES ('C1111111-1111-1111-1111-111111111111', 'V1 Legacy Chat', 1000.0, 1000.0, 'LegacyModel');
            INSERT INTO messages (id, conversation_id, role, content, created_at, status, token_count) VALUES ('E1111111-1111-1111-1111-111111111111', 'C1111111-1111-1111-1111-111111111111', 'user', 'Hello from v1', 1001.0, 'completed', 3);
        """
        XCTAssertEqual(sqlite3_exec(handle, v1SQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)

        // 2. Open via ConversationDatabase which will trigger Migration v2
        let db = try ConversationDatabase(fileURL: v1DbURL)

        // Verify conversations and messages survived untouched
        let convs = try await db.fetchConversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.title, "V1 Legacy Chat")
        XCTAssertEqual(convs.first?.modelName, "LegacyModel")

        let messages = try await db.fetchMessages(for: UUID(uuidString: "C1111111-1111-1111-1111-111111111111")!)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Hello from v1")

        // Verify models table is now active and empty
        let models = try await db.fetchModels()
        XCTAssertEqual(models.count, 0)
    }

    func testModelCatalogCRUD() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)

        let modelId = UUID()
        let fakePath = tempDirectory.appendingPathComponent("fake_model.gguf").path
        try "Fake GGUF".write(toFile: fakePath, atomically: true, encoding: .utf8)

        let record = ModelRecord(
            id: modelId,
            name: "Test Model",
            filePath: fakePath,
            fileSize: 1024 * 1024 * 50,
            architecture: "llama",
            quantization: "Q4_0",
            contextLength: 4096,
            parameterCount: 3_000_000_000
        )

        // 1. Insert
        let inserted = try await db.insertModel(record)
        XCTAssertEqual(inserted.id, modelId)

        // 2. Fetch by ID
        let fetched = try await db.fetchModel(id: modelId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Test Model")
        XCTAssertEqual(fetched?.quantization, "Q4_0")
        XCTAssertEqual(fetched?.contextLength, 4096)
        XCTAssertEqual(fetched?.parameterCount, 3_000_000_000)

        // 3. Fetch by Path
        let fetchedByPath = try await db.fetchModel(byPath: fakePath)
        XCTAssertEqual(fetchedByPath?.id, modelId)

        // 4. Duplicate insertion throws error
        do {
            _ = try await db.insertModel(record)
            XCTFail("Duplicate model insertion must throw error")
        } catch let libError as ModelLibraryError {
            XCTAssertEqual(libError, .duplicateModel(path: fakePath))
        } catch {
            XCTFail("Expected ModelLibraryError, got \(error)")
        }

        // 5. Update last used
        let usedDate = Date(timeIntervalSince1970: 2000.0)
        try await db.updateModelLastUsed(id: modelId, date: usedDate)
        let updated = try await db.fetchModel(id: modelId)
        XCTAssertEqual(updated?.lastUsedAt?.timeIntervalSince1970, 2000.0)

        // 6. Delete model record (non-destructive)
        try await db.deleteModel(id: modelId)
        let afterDelete = try await db.fetchModel(id: modelId)
        XCTAssertNil(afterDelete, "Catalog record must be removed.")

        // Verify underlying file on disk was NOT deleted
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakePath), "Removing catalog entry must NEVER delete model file on disk.")
    }

    // MARK: - ModelLibraryService Tests

    func testModelLibraryServiceDetectsMissingFiles() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let missingPath = tempDirectory.appendingPathComponent("disappeared.gguf").path
        let record = ModelRecord(
            name: "Ghost Model",
            filePath: missingPath,
            fileSize: 1000,
            architecture: "qwen2",
            quantization: "Q4_K_M",
            contextLength: 2048
        )
        try await db.insertModel(record)

        let catalog = try await service.fetchCatalog()
        XCTAssertEqual(catalog.count, 1)
        XCTAssertTrue(catalog.first?.isMissing == true, "Model whose file does not exist on disk must be marked isMissing.")
    }

    // MARK: - InferenceService Model Switching & Invariant Tests

    func testInferenceServiceSwitchModelEnforcesSingleActiveModel() async throws {
        let worker = MockInferenceWorker()
        let service = InferenceService(worker: worker)

        let path1 = tempDirectory.appendingPathComponent("model1.gguf").path
        let path2 = tempDirectory.appendingPathComponent("model2.gguf").path
        try "fake1".write(toFile: path1, atomically: true, encoding: .utf8)
        try "fake2".write(toFile: path2, atomically: true, encoding: .utf8)

        // 1. Initial load
        let info1 = try await service.switchModel(at: path1)
        XCTAssertEqual(info1.name, "model1.gguf")
        let isLoaded1 = await worker.isModelLoaded()
        XCTAssertTrue(isLoaded1)

        // 2. Switch to model 2: should unload model 1 before loading model 2
        let info2 = try await service.switchModel(at: path2)
        XCTAssertEqual(info2.name, "model2.gguf")

        // Worker calls: 1 initial load, 1 unload, 1 second load = 2 loads, 1 unload
        let loadCount = await worker.loadCallCount
        let unloadCount = await worker.unloadCallCount
        XCTAssertEqual(loadCount, 2, "Expected exactly 2 model loads.")
        XCTAssertEqual(unloadCount, 1, "Expected prior model to be unloaded during switch.")

        // 3. Switch to same model at path2 is a safe idempotent no-op
        let info3 = try await service.switchModel(at: path2)
        XCTAssertEqual(info3.name, "model2.gguf")
        let loadCountAfterSame = await worker.loadCallCount
        XCTAssertEqual(loadCountAfterSame, 2, "Switching to already loaded path must not trigger redundant reloads.")
    }

    func testInferenceServiceSwitchModelCancelsActiveGenerationFirst() async throws {
        let worker = MockInferenceWorker()
        let service = InferenceService(worker: worker)

        let path1 = tempDirectory.appendingPathComponent("modelA.gguf").path
        let path2 = tempDirectory.appendingPathComponent("modelB.gguf").path
        try "fakeA".write(toFile: path1, atomically: true, encoding: .utf8)
        try "fakeB".write(toFile: path2, atomically: true, encoding: .utf8)

        try await service.loadModel(at: path1)

        // Start mock generation stream
        _ = await service.generate(prompt: "Test prompt")

        // Request switch while generating
        let info2 = try await service.switchModel(at: path2)
        XCTAssertEqual(info2.name, "modelB.gguf")

        let finalState = await service.state
        XCTAssertEqual(finalState, .loaded(modelInfo: info2))
    }

    func testInferenceServiceSwitchModelHandlesLoadFailureCleanly() async throws {
        let worker = MockInferenceWorker()
        let service = InferenceService(worker: worker)

        let pathGood = tempDirectory.appendingPathComponent("good.gguf").path
        let pathBad = tempDirectory.appendingPathComponent("bad.gguf").path
        try "good".write(toFile: pathGood, atomically: true, encoding: .utf8)
        try "bad".write(toFile: pathBad, atomically: true, encoding: .utf8)

        try await service.loadModel(at: pathGood)

        // Set mock worker to fail subsequent load
        await worker.setShouldFailLoad(true)
        await worker.setFailureError(.modelLoadingFailed("Simulated corrupt weights"))

        do {
            _ = try await service.switchModel(at: pathBad)
            XCTFail("Switch to failing model must throw.")
        } catch {
            // Expected
        }

        let stateAfterFailure = await service.state
        if case .failed(let err) = stateAfterFailure {
            XCTAssertTrue(err.contains("Simulated corrupt weights"), "State must reflect clean failure: \(err)")
        } else {
            XCTFail("Engine must enter failed state after switch failure, got \(stateAfterFailure)")
        }
    }

    // MARK: - Security-Scoped Access & Lifecycle Remediation Tests

    func testSecurityScopedAccessLifecycleBalance() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let modelFile = tempDirectory.appendingPathComponent("scoped_model.gguf")
        try "fake_gguf_content".write(to: modelFile, atomically: true, encoding: .utf8)

        // Generate bookmark data if platform permits
        let bookmarkData = try? modelFile.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let record = ModelRecord(
            name: "Scoped Model",
            filePath: modelFile.path,
            fileSize: 100,
            architecture: "qwen2",
            quantization: "Q4_K_M",
            contextLength: 2048,
            bookmarkData: bookmarkData
        )
        let inserted = try await db.insertModel(record)

        // 1. Initially no access is active
        let initialActive = await service.isModelAccessActive(id: inserted.id)
        let initialCount = await service.activeAccessCount()
        XCTAssertFalse(initialActive)
        XCTAssertEqual(initialCount, 0)

        // 2. Prepare model for loading acquires access if bookmark present
        let resolvedPath = try await service.prepareModelForLoading(id: inserted.id)
        XCTAssertEqual(resolvedPath, modelFile.path)

        if bookmarkData != nil {
            let activeAfterPrepare = await service.isModelAccessActive(id: inserted.id)
            let countAfterPrepare = await service.activeAccessCount()
            XCTAssertTrue(activeAfterPrepare, "Access must be tracked as active after prepareModelForLoading")
            XCTAssertEqual(countAfterPrepare, 1, "Exactly one access token must be held")
        }

        // 3. Re-preparing the same model does not leak or duplicate access tokens
        _ = try await service.prepareModelForLoading(id: inserted.id)
        if bookmarkData != nil {
            let countAfterSecondPrepare = await service.activeAccessCount()
            XCTAssertEqual(countAfterSecondPrepare, 1, "Subsequent preparation of same model must not leak tokens")
        }

        // 4. Release access
        await service.releaseModelAccess(id: inserted.id)
        let activeAfterRelease = await service.isModelAccessActive(id: inserted.id)
        let countAfterRelease = await service.activeAccessCount()
        XCTAssertFalse(activeAfterRelease)
        XCTAssertEqual(countAfterRelease, 0, "Access token count must return to 0 after release")

        // 5. Idempotent double release must be safe
        await service.releaseModelAccess(id: inserted.id)
        let countAfterDoubleRelease = await service.activeAccessCount()
        XCTAssertEqual(countAfterDoubleRelease, 0, "Double-release must not fail or corrupt state")
    }

    func testPrepareModelForLoadingHandlesCorruptBookmark() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let modelFile = tempDirectory.appendingPathComponent("corrupt_bookmark.gguf")
        try "fake_gguf_content".write(to: modelFile, atomically: true, encoding: .utf8)

        let corruptData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let record = ModelRecord(
            name: "Corrupt Bookmark Model",
            filePath: modelFile.path,
            fileSize: 100,
            architecture: "qwen2",
            quantization: "Q4_K_M",
            contextLength: 2048,
            bookmarkData: corruptData
        )
        let inserted = try await db.insertModel(record)

        do {
            _ = try await service.prepareModelForLoading(id: inserted.id)
            XCTFail("Resolving corrupt bookmark must throw an unreadableFile error.")
        } catch let err as ModelLibraryError {
            if case .unreadableFile(let reason) = err {
                XCTAssertTrue(reason.contains("Could not resolve security-scoped bookmark"), "Error must clearly identify bookmark resolution failure: \(reason)")
            } else {
                XCTFail("Expected .unreadableFile, got \(err)")
            }
        } catch {
            XCTFail("Expected ModelLibraryError, got \(error)")
        }

        // Ensure zero leaked access tokens
        let count = await service.activeAccessCount()
        XCTAssertEqual(count, 0, "Failed bookmark resolution must not leave active tokens")
    }

    func testPrepareModelForLoadingMissingFileCleansUpScope() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let nonExistentPath = tempDirectory.appendingPathComponent("ghost_file.gguf").path
        let record = ModelRecord(
            name: "Ghost Model",
            filePath: nonExistentPath,
            fileSize: 100,
            architecture: "qwen2",
            quantization: "Q4_K_M",
            contextLength: 2048,
            bookmarkData: nil
        )
        let inserted = try await db.insertModel(record)

        do {
            _ = try await service.prepareModelForLoading(id: inserted.id)
            XCTFail("Preparing non-existent file must throw .fileNotFound.")
        } catch let err as ModelLibraryError {
            if case .fileNotFound(let path) = err {
                XCTAssertEqual(path, nonExistentPath)
            } else {
                XCTFail("Expected .fileNotFound, got \(err)")
            }
        } catch {
            XCTFail("Expected ModelLibraryError, got \(error)")
        }

        let count = await service.activeAccessCount()
        XCTAssertEqual(count, 0)
    }

    func testSwitchModelPreLoadActionTeardownOrdering() async throws {
        actor SwitchOrderTracker {
            var preLoadActionExecuted = false
            var unloadCompletedBeforePreLoad = false

            func record(unloadCount: Int) {
                preLoadActionExecuted = true
                if unloadCount >= 1 {
                    unloadCompletedBeforePreLoad = true
                }
            }
        }

        let worker = MockInferenceWorker()
        let service = InferenceService(worker: worker)
        let tracker = SwitchOrderTracker()

        let path1 = tempDirectory.appendingPathComponent("ord_model1.gguf").path
        let path2 = tempDirectory.appendingPathComponent("ord_model2.gguf").path
        try "model1".write(toFile: path1, atomically: true, encoding: .utf8)
        try "model2".write(toFile: path2, atomically: true, encoding: .utf8)

        _ = try await service.switchModel(at: path1)

        _ = try await service.switchModel(at: path2, configuration: .conservative) { [worker, tracker] in
            let unloadCount = await worker.unloadCallCount
            await tracker.record(unloadCount: unloadCount)
        }

        let executed = await tracker.preLoadActionExecuted
        let ordered = await tracker.unloadCompletedBeforePreLoad
        XCTAssertTrue(executed, "preLoadAction must be invoked during model switch")
        XCTAssertTrue(ordered, "Prior model native unload must complete BEFORE preLoadAction runs")
    }

    func testChatViewModelSelectAndLoadModelMaintainsScopeLifecycle() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let worker = MockInferenceWorker()
        let infService = InferenceService(worker: worker)
        let libService = ModelLibraryService(database: db)
        let viewModel = await ChatViewModel(inferenceService: infService, database: db, modelLibraryService: libService)

        let file1 = tempDirectory.appendingPathComponent("vm_model1.gguf")
        let file2 = tempDirectory.appendingPathComponent("vm_model2.gguf")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        let bookmark1 = try? file1.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let bookmark2 = try? file2.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        let rec1 = try await db.insertModel(ModelRecord(
            name: "VM Model 1", filePath: file1.path, fileSize: 100, architecture: "qwen2", quantization: "Q4_K_M", contextLength: 2048, bookmarkData: bookmark1
        ))
        let rec2 = try await db.insertModel(ModelRecord(
            name: "VM Model 2", filePath: file2.path, fileSize: 100, architecture: "qwen2", quantization: "Q4_K_M", contextLength: 2048, bookmarkData: bookmark2
        ))

        // 1. Load Model 1
        await viewModel.selectAndLoadModel(model: rec1)
        let loadedId1 = await viewModel.loadedModelId
        XCTAssertEqual(loadedId1, rec1.id)

        if bookmark1 != nil {
            let count1 = await libService.activeAccessCount()
            let active1 = await libService.isModelAccessActive(id: rec1.id)
            XCTAssertEqual(count1, 1)
            XCTAssertTrue(active1)
        }

        // 2. Switch to Model 2
        await viewModel.selectAndLoadModel(model: rec2)
        let loadedId2 = await viewModel.loadedModelId
        XCTAssertEqual(loadedId2, rec2.id)

        if bookmark2 != nil {
            let count2 = await libService.activeAccessCount()
            let active2 = await libService.isModelAccessActive(id: rec2.id)
            let activeOld = await libService.isModelAccessActive(id: rec1.id)
            XCTAssertEqual(count2, 1, "Only the newly active model's scope should remain active")
            XCTAssertTrue(active2)
            XCTAssertFalse(activeOld, "Previous model's scope must have been released")
        }

        // 3. Unload model
        await viewModel.unloadModel()
        let loadedAfterUnload = await viewModel.loadedModelId
        XCTAssertNil(loadedAfterUnload)

        let finalCount = await libService.activeAccessCount()
        XCTAssertEqual(finalCount, 0, "All scopes must be released after unloadModel")
    }

    func testChatViewModelFailedLoadCleansUpSecurityScope() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let worker = MockInferenceWorker()
        let infService = InferenceService(worker: worker)
        let libService = ModelLibraryService(database: db)
        let viewModel = await ChatViewModel(inferenceService: infService, database: db, modelLibraryService: libService)

        let file = tempDirectory.appendingPathComponent("fail_model.gguf")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        let bookmark = try? file.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        let rec = try await db.insertModel(ModelRecord(
            name: "Fail Model", filePath: file.path, fileSize: 100, architecture: "qwen2", quantization: "Q4_K_M", contextLength: 2048, bookmarkData: bookmark
        ))

        // Configure worker to fail
        await worker.setShouldFailLoad(true)
        await worker.setFailureError(.modelLoadingFailed("Injected failure for scope cleanup test"))

        await viewModel.selectAndLoadModel(model: rec)

        let loadedId = await viewModel.loadedModelId
        XCTAssertNil(loadedId, "Model must not be marked loaded on failure")

        let count = await libService.activeAccessCount()
        XCTAssertEqual(count, 0, "Failed load must release any acquired security scope")
    }

    func testReleaseAllModelAccessOnShutdown() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let file1 = tempDirectory.appendingPathComponent("shut1.gguf")
        let file2 = tempDirectory.appendingPathComponent("shut2.gguf")
        try "c1".write(to: file1, atomically: true, encoding: .utf8)
        try "c2".write(to: file2, atomically: true, encoding: .utf8)

        let b1 = try? file1.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let b2 = try? file2.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        let r1 = try await db.insertModel(ModelRecord(name: "S1", filePath: file1.path, fileSize: 10, architecture: "qwen2", quantization: "Q4_K_M", contextLength: 2048, bookmarkData: b1))
        let r2 = try await db.insertModel(ModelRecord(name: "S2", filePath: file2.path, fileSize: 10, architecture: "qwen2", quantization: "Q4_K_M", contextLength: 2048, bookmarkData: b2))

        _ = try await service.prepareModelForLoading(id: r1.id)
        _ = try await service.prepareModelForLoading(id: r2.id)

        // Shutdown release all
        await service.releaseAllModelAccess()
        let count = await service.activeAccessCount()
        XCTAssertEqual(count, 0, "releaseAllModelAccess must clear all active scopes")
    }

    // MARK: - Critical Recovery & Catalog Usability Regressions

    private func createSyntheticGGUF(at url: URL, architecture: String = "llama") throws {
        var data = Data()
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46]) // "GGUF"
        var version: UInt32 = 3
        data.append(Data(bytes: &version, count: 4))
        var tensorCount: UInt64 = 1
        data.append(Data(bytes: &tensorCount, count: 8))
        var kvCount: UInt64 = 1
        data.append(Data(bytes: &kvCount, count: 8))

        // key: "general.architecture"
        let key = "general.architecture"
        var keyLen = UInt64(key.utf8.count)
        data.append(Data(bytes: &keyLen, count: 8))
        data.append(contentsOf: key.utf8)

        // type: STRING = 8
        var valType: UInt32 = 8
        data.append(Data(bytes: &valType, count: 4))

        // value: architecture
        var valLen = UInt64(architecture.utf8.count)
        data.append(Data(bytes: &valLen, count: 8))
        data.append(contentsOf: architecture.utf8)

        // 1 tensor info:
        let tensorName = "token_embd.weight"
        var tNameLen = UInt64(tensorName.utf8.count)
        data.append(Data(bytes: &tNameLen, count: 8))
        data.append(contentsOf: tensorName.utf8)

        var nDims: UInt32 = 1
        data.append(Data(bytes: &nDims, count: 4))
        var dim0: UInt64 = 16
        data.append(Data(bytes: &dim0, count: 8))
        var tType: UInt32 = 0 // GGML_TYPE_F32
        data.append(Data(bytes: &tType, count: 4))
        var offset: UInt64 = 0
        data.append(Data(bytes: &offset, count: 8))

        // Padding to 32 bytes
        let pad = (32 - (data.count % 32)) % 32
        if pad > 0 {
            data.append(Data(repeating: 0, count: pad))
        }
        // Tensor data: 16 * 4 bytes = 64 bytes
        data.append(Data(repeating: 0, count: 64))

        try data.write(to: url)
    }

    func testFetchCatalogPreservesUsabilityForStoredModelMetadataWithoutTensorCount() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let fileURL = tempDirectory.appendingPathComponent("stored_test.gguf")
        try createSyntheticGGUF(at: fileURL, architecture: "llama")
        let bookmark = try? fileURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Insert model with normal architecture and valid file
        let record = ModelRecord(
            name: "Test Llama",
            filePath: fileURL.path,
            fileSize: 1024,
            architecture: "llama",
            quantization: "Q4_0",
            contextLength: 2048,
            bookmarkData: bookmark
        )
        _ = try await db.insertModel(record)

        let catalog = try await service.fetchCatalog()
        guard let model = catalog.first(where: { $0.filePath == fileURL.path }) else {
            XCTFail("Model must be present in catalog")
            return
        }

        XCTAssertFalse(model.isMissing, "Model file should exist and not be marked missing")
        XCTAssertTrue(model.compatibilityStatus.isUsable, "Model must be usable and not greyed out as unknown")
    }

    func testRelinkModelUpdatesPathAndBookmark() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let oldPath = tempDirectory.appendingPathComponent("missing_old.gguf").path
        let initialRecord = ModelRecord(
            name: "Relinkable Model",
            filePath: oldPath,
            fileSize: 100,
            architecture: "llama",
            quantization: "Q4_0",
            contextLength: 2048,
            bookmarkData: nil
        )
        let saved = try await db.insertModel(initialRecord)

        // Initially, model is missing
        let fetchedInitial = try await service.fetchModel(id: saved.id)
        XCTAssertNotNil(fetchedInitial)
        XCTAssertTrue(fetchedInitial?.isMissing == true, "Model at nonexistent path must be marked missing")

        // Create new valid file at new location
        let newFileURL = tempDirectory.appendingPathComponent("new_location.gguf")
        try createSyntheticGGUF(at: newFileURL, architecture: "llama")

        // Relink model
        let relinked = try await service.relinkModel(id: saved.id, fileURL: newFileURL)
        XCTAssertEqual(relinked.id, saved.id)
        XCTAssertEqual(relinked.filePath, newFileURL.path)
        XCTAssertFalse(relinked.isMissing, "Relinked model must no longer be marked missing")
        XCTAssertTrue(relinked.compatibilityStatus.isUsable, "Relinked model must evaluate as usable")

        // Verify persisted database record
        let persisted = try await db.fetchModel(id: saved.id)
        XCTAssertEqual(persisted?.filePath, newFileURL.path)
        XCTAssertNotNil(persisted?.bookmarkData, "Security-scoped bookmark must be created and saved")
    }

    func testRegisterModelWithAllowReauthorization() async throws {
        let db = try ConversationDatabase(fileURL: testDatabaseURL)
        let service = ModelLibraryService(database: db)

        let fileURL = tempDirectory.appendingPathComponent("reauth_test.gguf")
        try createSyntheticGGUF(at: fileURL, architecture: "llama")

        // Initial registration
        let initial = try await service.registerModel(at: fileURL)
        XCTAssertEqual(initial.filePath, fileURL.path)

        // Second registration with allowReauthorization = false must throw duplicateModel
        do {
            _ = try await service.registerModel(at: fileURL, allowReauthorization: false)
            XCTFail("Must throw duplicateModel when allowReauthorization is false")
        } catch let error as ModelLibraryError {
            if case .duplicateModel = error {
                // Expected
            } else {
                XCTFail("Expected .duplicateModel, got \(error)")
            }
        }

        // Third registration with allowReauthorization = true must succeed
        let reauthorized = try await service.registerModel(at: fileURL, allowReauthorization: true)
        XCTAssertEqual(reauthorized.id, initial.id, "Must return existing model record")
        XCTAssertEqual(reauthorized.filePath, fileURL.path)
    }
}
