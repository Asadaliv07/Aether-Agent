import XCTest
import SQLite3
@testable import Aether

final class ModelCatalogTests: XCTestCase {

    private var tempDirectory: URL!
    private var testDatabaseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherModelCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        testDatabaseURL = tempDirectory.appendingPathComponent("test_catalog.sqlite")
    }

    override func tearDown() async throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - 1. Metadata Field Completeness Tests (22 Fields)

    func testAllRegistryModelsHaveComplete22Fields() {
        let registry = ModelCatalogRegistry.models
        XCTAssertGreaterThanOrEqual(registry.count, 50, "Curated registry must contain at least 50 verified models")

        for model in registry {
            // 1. Official name
            XCTAssertFalse(model.officialName.isEmpty, "Official name missing for \(model.repositoryId)")
            // 2. Display name
            XCTAssertFalse(model.displayName.isEmpty, "Display name missing for \(model.repositoryId)")
            // 3. Publisher
            XCTAssertFalse(model.publisher.isEmpty, "Publisher missing for \(model.repositoryId)")
            // 4. Model family
            XCTAssertFalse(model.modelFamily.isEmpty, "Family missing for \(model.repositoryId)")
            // 5. Architecture
            XCTAssertFalse(model.architecture.isEmpty, "Architecture missing for \(model.repositoryId)")
            // 6. Parameter count
            XCTAssertFalse(model.parameterCount.isEmpty, "Parameters missing for \(model.repositoryId)")
            // 7. Version
            XCTAssertFalse(model.modelVersion.isEmpty, "Version missing for \(model.repositoryId)")
            // 8. Description
            XCTAssertFalse(model.description.isEmpty, "Description missing for \(model.repositoryId)")
            // 9. Capabilities
            XCTAssertFalse(model.primaryCapabilities.isEmpty, "Capabilities empty for \(model.repositoryId)")
            // 10. Supported languages
            XCTAssertFalse(model.supportedLanguages.isEmpty, "Languages empty for \(model.repositoryId)")
            // 11. Context window
            XCTAssertGreaterThan(model.contextWindow, 0, "Context window must be > 0 for \(model.repositoryId)")
            // 12. Model format
            XCTAssertEqual(model.modelFormat, .gguf, "Catalog format should be GGUF")
            // 13. Quantization
            XCTAssertFalse(model.defaultQuantization.isEmpty, "Default quantization missing for \(model.repositoryId)")
            // 14. Download size
            XCTAssertGreaterThan(model.estimatedDownloadSize, 0, "Download size must be > 0 for \(model.repositoryId)")
            // 15. Repository ID
            XCTAssertTrue(model.repositoryId.contains("/"), "Repo ID should be user/repo: \(model.repositoryId)")
            // 16. Official URL
            XCTAssertEqual(model.officialSourceURL.scheme, "https", "Official URL must be HTTPS")
            // 17. License
            XCTAssertFalse(model.license.isEmpty, "License missing for \(model.repositoryId)")
            // 18. Hardware requirements
            XCTAssertGreaterThan(model.hardwareRequirements.minimumRAMBytes, 0)
            XCTAssertGreaterThanOrEqual(model.hardwareRequirements.recommendedRAMBytes, model.hardwareRequirements.minimumRAMBytes)
            // 19. Supported engines
            XCTAssertFalse(model.supportedInferenceEngines.isEmpty, "Engines missing for \(model.repositoryId)")
            // 20. Compatibility status
            XCTAssertNotNil(model.compatibilityStatus)
            // 21. Task type
            XCTAssertTrue(ModelTaskType.allCases.contains(model.taskType))
            // 22. Last verification date
            XCTAssertLessThanOrEqual(model.lastVerificationDate, Date())

            // Quantization variants
            XCTAssertFalse(model.availableQuantizations.isEmpty, "Quantizations missing for \(model.repositoryId)")
            for quant in model.availableQuantizations {
                XCTAssertFalse(quant.quantization.isEmpty)
                XCTAssertFalse(quant.filename.isEmpty)
                XCTAssertTrue(
                    quant.filename.hasSuffix(".gguf") || quant.filename.hasSuffix(".bin"),
                    "Variant filename must end in .gguf or .bin: \(quant.filename)"
                )
                XCTAssertGreaterThan(quant.size, 0)
            }
        }
    }

    // MARK: - 2. Model Name Normalization Tests

    func testModelNameNormalization() {
        let cases: [(raw: String, expected: String)] = [
            ("qwen2.5-7b-instruct-q4_k_m.gguf", "Qwen 2.5 7B Instruct"),
            ("Meta-Llama-3.1-8B-Instruct-Q4_K_M", "Llama 3.1 8B Instruct"),
            ("mistral-7b-instruct-v0.3.Q4_K_M", "Mistral 7B Instruct v0.3"),
            ("phi-3-mini-4k-instruct-q4.gguf", "Phi 3 Mini 4K Instruct"),
            ("deepseek-coder-6.7b-instruct-q4", "DeepSeek Coder 6.7B Instruct"),
            ("gemma-2-9b-it-Q4_K_M.gguf", "Gemma 2 9B Instruct"),
            ("Llama-3.2-3B-Instruct-Q4_K_M.gguf", "Llama 3.2 3B Instruct"),
            ("StarCoder2-7B-Q4_K_M.gguf", "StarCoder2 7B"),
            ("breeze-tts-2-q4_0.gguf", "Breeze TTS 2")
        ]

        for testCase in cases {
            let normalized = ModelCatalogNormalizer.cleanModelName(from: testCase.raw)
            XCTAssertEqual(normalized, testCase.expected, "Failed normalizing raw name: \(testCase.raw)")
        }
    }

    // MARK: - 3. Search & Filter Engine Tests

    func testCategoryFiltering() {
        let engine = ModelCatalogSearchEngine.shared

        let codingModels = engine.filterModels(category: .coding)
        XCTAssertFalse(codingModels.isEmpty)
        for model in codingModels {
            XCTAssertEqual(model.taskType, .coding)
        }

        let reasoningModels = engine.filterModels(category: .reasoning)
        XCTAssertFalse(reasoningModels.isEmpty)
        for model in reasoningModels {
            XCTAssertEqual(model.taskType, .reasoning)
        }

        let visionModels = engine.filterModels(category: .vision)
        XCTAssertFalse(visionModels.isEmpty)
        for model in visionModels {
            XCTAssertEqual(model.taskType, .visionLanguage)
        }

        let audioModels = engine.filterModels(category: .audio)
        XCTAssertFalse(audioModels.isEmpty)
        for model in audioModels {
            XCTAssertTrue(model.taskType == .speechToText || model.taskType == .textToSpeech)
        }

        let smallModels = engine.filterModels(category: .small)
        XCTAssertFalse(smallModels.isEmpty)
        for model in smallModels {
            let p = model.parameterCount.lowercased()
            XCTAssertTrue(
                p.contains("0.") || p.contains("1") || p.contains("2") || p.contains("3") || p.contains("m"),
                "Small model should be <4B: \(model.displayName) with \(model.parameterCount)"
            )
        }
    }

    func testQuerySearch() {
        let engine = ModelCatalogSearchEngine.shared

        let qwenResults = engine.filterModels(query: "qwen")
        XCTAssertFalse(qwenResults.isEmpty)
        for model in qwenResults {
            let matches = model.displayName.localizedCaseInsensitiveContains("qwen") ||
                model.officialName.localizedCaseInsensitiveContains("qwen") ||
                model.publisher.localizedCaseInsensitiveContains("qwen") ||
                model.modelFamily.localizedCaseInsensitiveContains("qwen") ||
                model.repositoryId.localizedCaseInsensitiveContains("qwen")
            XCTAssertTrue(matches, "Model \(model.displayName) should match query 'qwen'")
        }

        let nonExistent = engine.filterModels(query: "nonexistent_model_xyz_999")
        XCTAssertTrue(nonExistent.isEmpty)
    }

    func testPublisherAndFamilyFiltering() {
        let engine = ModelCatalogSearchEngine.shared

        let metaModels = engine.filterModels(selectedPublisher: "Meta")
        XCTAssertFalse(metaModels.isEmpty)
        for model in metaModels {
            XCTAssertEqual(model.publisher.lowercased(), "meta")
        }

        let mistralFamily = engine.filterModels(selectedFamily: "Mistral")
        XCTAssertFalse(mistralFamily.isEmpty)
        for model in mistralFamily {
            XCTAssertEqual(model.modelFamily.lowercased(), "mistral")
        }
    }

    func testSortingOptions() {
        let engine = ModelCatalogSearchEngine.shared

        let sortedByName = engine.filterModels(sort: .alphabetical)
        for i in 0..<(sortedByName.count - 1) {
            let cmp = sortedByName[i].displayName.localizedCaseInsensitiveCompare(sortedByName[i + 1].displayName)
            XCTAssertTrue(cmp == .orderedAscending || cmp == .orderedSame)
        }

        let sortedBySize = engine.filterModels(sort: .smallestSize)
        for i in 0..<(sortedBySize.count - 1) {
            XCTAssertLessThanOrEqual(sortedBySize[i].estimatedDownloadSize, sortedBySize[i + 1].estimatedDownloadSize)
        }

        let sortedByPopularity = engine.filterModels(sort: .mostPopular)
        XCTAssertFalse(sortedByPopularity.isEmpty)
    }

    // MARK: - 4. Device Capability Engine & Hardware Suitability Tests

    func testDeviceCapabilityProfiles() {
        // Test 8 GB profile
        let profile8GB = DeviceCapabilityProfile(
            physicalRAMBytes: 8 * 1024 * 1024 * 1024,
            chipIdentifier: "Apple M2"
        )
        XCTAssertEqual(profile8GB.physicalRAMGigabytes, 8)
        XCTAssertEqual(profile8GB.memoryTier, .base8GB)

        // Test 16 GB profile
        let profile16GB = DeviceCapabilityProfile(
            physicalRAMBytes: 16 * 1024 * 1024 * 1024,
            chipIdentifier: "Apple M5"
        )
        XCTAssertEqual(profile16GB.physicalRAMGigabytes, 16)
        XCTAssertEqual(profile16GB.memoryTier, .standard16GB)

        // Test 64 GB profile
        let profile64GB = DeviceCapabilityProfile(
            physicalRAMBytes: 64 * 1024 * 1024 * 1024,
            chipIdentifier: "Apple M3 Max"
        )
        XCTAssertEqual(profile64GB.physicalRAMGigabytes, 64)
        XCTAssertEqual(profile64GB.memoryTier, .pro48to64GB)

        // Evaluate a small 1B/1.5B model against 16GB
        let smallModel = ModelCatalogRegistry.models.first { $0.parameterCount.contains("1.54") || $0.parameterCount == "1B" }!
        let suitabilitySmall = DeviceCapabilityEngine.evaluateSuitability(model: smallModel, profile: profile16GB)
        XCTAssertTrue(suitabilitySmall.isSmoothlyPlayable)

        // Test dynamic memory pressure detection (MAJ-02)
        let sampled = DeviceCapabilityEngine.sampleAvailableSystemMemoryBytes()
        if let sampled {
            XCTAssertGreaterThan(sampled, 0)
        }
        let pressuredSuitability = DeviceCapabilityEngine.evaluateSuitability(
            model: smallModel,
            profile: profile16GB,
            availableMemoryBytes: 500 * 1024 * 1024 // Only 500MB available
        )
        if case .highMemoryPressure = pressuredSuitability {
            // Expected
        } else {
            XCTFail("500MB available memory should trigger highMemoryPressure, got \(pressuredSuitability)")
        }

        // Evaluate a 70B/72B model against 8GB
        let hugeModel = ModelCatalogRegistry.models.first { $0.parameterCount.contains("70B") || $0.parameterCount.contains("671B") }!
        let suitabilityHugeOn8GB = DeviceCapabilityEngine.evaluateSuitability(model: hugeModel, profile: profile8GB)
        if case .requiresMoreRAM(let needed, let current) = suitabilityHugeOn8GB {
            XCTAssertGreaterThan(needed, 8)
            XCTAssertEqual(current, 8)
        } else {
            XCTFail("Huge model on 8GB host should require more RAM, got: \(suitabilityHugeOn8GB)")
        }

        // Evaluate an audio model (Whisper) which requires specialized audio engine
        let whisperModel = ModelCatalogRegistry.models.first { $0.taskType == .speechToText }!
        let suitabilityWhisper = DeviceCapabilityEngine.evaluateSuitability(model: whisperModel, profile: profile16GB)
        if case .requiresSpecializedEngine(let label) = suitabilityWhisper {
            XCTAssertTrue(label.contains("Audio") || label.contains("whisper"))
        } else {
            XCTFail("Whisper model should require specialized engine, got: \(suitabilityWhisper)")
        }
    }

    // MARK: - 5. Database Name Update & Model Migration Tests

    func testDatabaseModelNameUpdate() async throws {
        let database = try ConversationDatabase(fileURL: testDatabaseURL)

        let dummyURL = tempDirectory.appendingPathComponent("model.gguf")
        try "dummy model content".write(to: dummyURL, atomically: true, encoding: .utf8)

        let initialRecord = ModelRecord(
            name: "qwen2.5-coder-7b-instruct-q4_k_m.gguf",
            filePath: dummyURL.path,
            fileSize: 4500000000,
            architecture: "qwen2",
            quantization: "Q4_K_M",
            contextLength: 32768,
            parameterCount: 7_000_000_000
        )

        try await database.insertModel(initialRecord)

        // Verify initial state
        var fetched = try await database.fetchModel(id: initialRecord.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "qwen2.5-coder-7b-instruct-q4_k_m.gguf")

        // Perform in-place name update
        let cleanName = ModelCatalogNormalizer.cleanModelName(from: initialRecord.name)
        XCTAssertEqual(cleanName, "Qwen 2.5 Coder 7B Instruct")

        try await database.updateModelName(id: initialRecord.id, name: cleanName)

        // Verify updated state preserves filePath and other properties
        fetched = try await database.fetchModel(id: initialRecord.id)
        XCTAssertEqual(fetched?.name, "Qwen 2.5 Coder 7B Instruct")
        XCTAssertEqual(fetched?.filePath, dummyURL.path)
        XCTAssertEqual(fetched?.quantization, "Q4_K_M")
    }

    func testModelLibraryServiceMigration() async throws {
        let database = try ConversationDatabase(fileURL: testDatabaseURL)

        let dummyURL = tempDirectory.appendingPathComponent("Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf")
        try "dummy model content".write(to: dummyURL, atomically: true, encoding: .utf8)

        let initialRecord = ModelRecord(
            name: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
            filePath: dummyURL.path,
            fileSize: 4900000000,
            architecture: "llama",
            quantization: "Q4_K_M",
            contextLength: 131072,
            parameterCount: 8_000_000_000
        )

        try await database.insertModel(initialRecord)

        let service = ModelLibraryService(database: database)
        let count = try await service.migrateAndNormalizeInstalledModelNames()
        XCTAssertEqual(count, 1, "Should migrate exactly 1 unnormalized model")

        let fetched = try await database.fetchModel(id: initialRecord.id)
        XCTAssertEqual(fetched?.name, "Llama 3.1 8B Instruct")

        // Second pass should migrate 0 because it's already normalized
        let secondPassCount = try await service.migrateAndNormalizeInstalledModelNames()
        XCTAssertEqual(secondPassCount, 0, "Second migration pass should touch 0 models")
    }
}
