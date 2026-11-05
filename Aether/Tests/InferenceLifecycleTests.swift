import XCTest
@testable import Aether

/// Mock worker for deterministic unit testing of `InferenceService` coordinator state transitions.
internal actor MockInferenceWorker: InferenceWorkerProtocol {
    private var shouldFailLoad: Bool = false
    private var failureError: InferenceError = .modelLoadingFailed("Simulated mock failure")
    private var loadDelayNanoseconds: UInt64 = 0
    private var isLoadedState: Bool = false
    private(set) var shutdownCallCount: Int = 0
    private(set) var unloadCallCount: Int = 0
    private(set) var loadCallCount: Int = 0

    init() {}

    func setShouldFailLoad(_ value: Bool) {
        self.shouldFailLoad = value
    }

    func setFailureError(_ error: InferenceError) {
        self.failureError = error
    }

    func setLoadDelayNanoseconds(_ delay: UInt64) {
        self.loadDelayNanoseconds = delay
    }

    func initializeBackend() async throws {}

    func loadModel(at path: String, configuration: ModelConfiguration) async throws -> ModelInfo {
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }

        loadCallCount += 1
        if shouldFailLoad {
            throw failureError
        }

        isLoadedState = true
        return ModelInfo(
            path: path,
            name: (path as NSString).lastPathComponent,
            sizeInBytes: 1024 * 1024 * 100, // 100 MB mock
            description: "Mock GGUF Model"
        )
    }

    func unloadModel() async throws {
        unloadCallCount += 1
        isLoadedState = false
    }

    func shutdown() async {
        shutdownCallCount += 1
        isLoadedState = false
    }

    func isModelLoaded() async -> Bool {
        return isLoadedState
    }

    func getModelChatTemplate() async -> String? {
        return nil
    }

    func countTokens(for text: String) async throws -> Int {
        if text.isEmpty { return 0 }
        return max(1, text.count / 4)
    }

    func generate(
        prompt: String,
        configuration: GenerationConfiguration,
        cancellationSignal: CancellationSignal,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws {
        if cancellationSignal.isCancelled {
            throw InferenceError.cancelled
        }
    }
}

final class InferenceLifecycleTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsUnloaded() async {
        let service = InferenceService(worker: MockInferenceWorker())
        let state = await service.state
        XCTAssertEqual(state, .unloaded, "InferenceService must initialize in the unloaded state.")
    }

    // MARK: - Path Validation & Missing Files

    func testEmptyAndWhitespaceModelPaths() async {
        let service = InferenceService(worker: MockInferenceWorker())

        do {
            _ = try await service.loadModel(at: "")
            XCTFail("Loading an empty path must throw an error.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .invalidModelPath(""), "Empty path must throw invalidModelPath.")
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }

        let state = await service.state
        XCTAssertEqual(state, .failed(errorDescription: InferenceError.invalidModelPath("").localizedDescription))
    }

    func testNonExistentModelPath() async {
        let service = InferenceService(worker: MockInferenceWorker())
        let ghostPath = "/tmp/aether-nonexistent-model-\(UUID().uuidString).gguf"

        do {
            _ = try await service.loadModel(at: ghostPath)
            XCTFail("Loading a non-existent path must throw modelNotFound.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .modelNotFound(ghostPath))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await service.state
        XCTAssertEqual(state, .failed(errorDescription: InferenceError.modelNotFound(ghostPath).localizedDescription))
    }

    func testDirectoryAsModelPath() async {
        let service = InferenceService(worker: MockInferenceWorker())
        let dirPath = NSTemporaryDirectory()

        do {
            _ = try await service.loadModel(at: dirPath)
            XCTFail("Loading a directory path must throw invalidModelPath.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .invalidModelPath(dirPath))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - State Machine & Conflicting Operations

    func testSuccessfulLoadAndStateTransition() async throws {
        let mock = MockInferenceWorker()
        let service = InferenceService(worker: mock)

        // Create a temporary dummy file to pass preliminary filesystem validation.
        let tempFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("dummy-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempFilePath, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempFilePath) }

        let info = try await service.loadModel(at: tempFilePath)
        XCTAssertEqual(info.name, (tempFilePath as NSString).lastPathComponent)

        let state = await service.state
        XCTAssertEqual(state, .loaded(modelInfo: info))
    }

    func testLoadWhenAlreadyLoadedThrows() async throws {
        let mock = MockInferenceWorker()
        let service = InferenceService(worker: mock)

        let tempPathA = (NSTemporaryDirectory() as NSString).appendingPathComponent("modelA-\(UUID().uuidString).gguf")
        let tempPathB = (NSTemporaryDirectory() as NSString).appendingPathComponent("modelB-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempPathA, contents: Data("A".utf8))
        FileManager.default.createFile(atPath: tempPathB, contents: Data("B".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: tempPathA)
            try? FileManager.default.removeItem(atPath: tempPathB)
        }

        _ = try await service.loadModel(at: tempPathA)

        do {
            _ = try await service.loadModel(at: tempPathB)
            XCTFail("Attempting to load while already loaded must throw alreadyLoaded.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .alreadyLoaded(existingModel: (tempPathA as NSString).lastPathComponent))
        }

        // State must remain loaded with Model A.
        let state = await service.state
        if case .loaded(let info) = state {
            XCTAssertEqual(info.name, (tempPathA as NSString).lastPathComponent)
        } else {
            XCTFail("State must remain .loaded(modelA)")
        }
    }

    func testUnloadWhenUnloadedIsSafeNoOp() async throws {
        let mock = MockInferenceWorker()
        let service = InferenceService(worker: mock)

        // Should complete without throwing.
        try await service.unloadModel()
        let state = await service.state
        XCTAssertEqual(state, .unloaded)
        let unloadCount = await mock.unloadCallCount
        XCTAssertEqual(unloadCount, 0, "Worker unload should not be invoked when already unloaded.")
    }

    func testRepeatedUnloadCallsAreSafe() async throws {
        let mock = MockInferenceWorker()
        let service = InferenceService(worker: mock)

        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("model-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempPath, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        _ = try await service.loadModel(at: tempPath)
        try await service.unloadModel()
        let stateAfterFirstUnload = await service.state
        XCTAssertEqual(stateAfterFirstUnload, .unloaded)

        // Second and third unloads must be safe idempotent no-ops.
        try await service.unloadModel()
        try await service.unloadModel()
        let finalState = await service.state
        XCTAssertEqual(finalState, .unloaded)
    }

    func testFailedLoadLeavesStateFailedAndConsistent() async {
        let mock = MockInferenceWorker()
        await mock.setShouldFailLoad(true)
        await mock.setFailureError(.modelLoadingFailed("Corrupt GGUF header"))
        let service = InferenceService(worker: mock)

        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("corrupt-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempPath, contents: Data("corrupt".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        do {
            _ = try await service.loadModel(at: tempPath)
            XCTFail("Load must fail when worker reports failure.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .modelLoadingFailed("Corrupt GGUF header"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await service.state
        XCTAssertEqual(state, .failed(errorDescription: InferenceError.modelLoadingFailed("Corrupt GGUF header").localizedDescription))

        // Subsequent valid load must be allowed after failure.
        await mock.setShouldFailLoad(false)
        do {
            let info = try await service.loadModel(at: tempPath)
            let recoveredState = await service.state
            XCTAssertEqual(recoveredState, .loaded(modelInfo: info))
        } catch {
            XCTFail("Recovery load must succeed: \(error)")
        }
    }

private actor StateAccumulator {
    private var states: [InferenceState] = []

    func append(_ state: InferenceState) {
        states.append(state)
    }

    func count() -> Int {
        states.count
    }

    func allStates() -> [InferenceState] {
        states
    }
}

    // MARK: - Reactive State Stream

    func testStateStreamReceivesTransitions() async throws {
        let mock = MockInferenceWorker()
        let service = InferenceService(worker: mock)

        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("stream-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempPath, contents: Data("stream".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let accumulator = StateAccumulator()
        let expectation = expectation(description: "Observed state sequence")

        let stream = await service.stateStream
        let streamTask = Task {
            for await state in stream {
                await accumulator.append(state)
                let currentCount = await accumulator.count()
                if currentCount == 5 {
                    expectation.fulfill()
                    break
                }
            }
        }

        // 1. Initial (.unloaded) already yielded
        // 2. Load -> .loading -> .loaded
        _ = try await service.loadModel(at: tempPath)
        // 3. Unload -> .unloading -> .unloaded
        try await service.unloadModel()

        await fulfillment(of: [expectation], timeout: 2.0)
        streamTask.cancel()

        let observedStates = await accumulator.allStates()
        XCTAssertEqual(observedStates.first, .unloaded)
        XCTAssertTrue(observedStates.contains(where: {
            if case .loading = $0 { return true } else { return false }
        }))
        XCTAssertTrue(observedStates.contains(where: {
            if case .loaded = $0 { return true } else { return false }
        }))
        XCTAssertTrue(observedStates.contains(where: { $0 == .unloading }))
        XCTAssertEqual(observedStates.last, .unloaded)
    }

    // MARK: - Native Worker Failure Handling (Non-GGUF File)

    func testNativeWorkerWithInvalidFormatFailsSafely() async {
        let worker = LlamaInferenceWorker()

        // Create a temporary non-GGUF text file to test native rejection.
        let tempInvalidPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("not-a-model-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tempInvalidPath, contents: Data("This is plain text, not a valid GGUF model binary file.".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempInvalidPath) }

        do {
            _ = try await worker.loadModel(at: tempInvalidPath, configuration: .conservative)
            XCTFail("Native llama.cpp must reject non-GGUF file.")
        } catch let error as InferenceError {
            if case .modelLoadingFailed = error {
                // Expected native rejection.
            } else {
                XCTFail("Expected .modelLoadingFailed, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let isLoaded = await worker.isModelLoaded()
        XCTAssertFalse(isLoaded, "Worker must remain unloaded after native load failure.")

        // Verify repeated shutdown is safe.
        await worker.shutdown()
        await worker.shutdown()
    }

    // MARK: - Real Model Validation Test Matrix (Phase 3.4.8)

    private var candidateModelPath: String? {
        let candidates = [
            "/Users/asadalishaikh/Desktop/qwen2.5-coder/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463",
            "/Users/asadalishaikh/.ollama/models/blobs/sha256-60e05f2100071479f596b964f89f510f057ce397ea22f2833a0cfe029bfc2463"
        ]
        return candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
    }

    /// Scenario A: Real model load, short generation, unload, reload, and repeated generation.
    func testRealModel_LifecycleLoadGenerateUnloadReload() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)

        // 1. Initial Load
        let loadStartTime = CFAbsoluteTimeGetCurrent()
        let info1 = try await service.loadModel(at: path, configuration: .conservative)
        let loadDuration = CFAbsoluteTimeGetCurrent() - loadStartTime

        XCTAssertEqual(info1.path, path)
        XCTAssertGreaterThan(info1.sizeInBytes, 4_000_000_000)
        XCTAssertFalse(info1.description.isEmpty)
        print("[REAL_MODEL_A] Model loaded in \(String(format: "%.3f", loadDuration))s: \(info1.description)")

        // 2. Generate short response
        let config = GenerationConfiguration(contextLength: 512, maxTokens: 10, temperature: 0.0)
        let stream1 = await service.generate(prompt: "Hello", configuration: config)
        var tokens1: [String] = []
        for try await token in stream1 {
            tokens1.append(token)
        }
        XCTAssertFalse(tokens1.isEmpty, "Generation 1 must produce tokens.")
        print("[REAL_MODEL_A] Gen 1 text: '\(tokens1.joined())' (\(tokens1.count) chunks)")

        // 3. Unload model
        let unloadStartTime = CFAbsoluteTimeGetCurrent()
        try await service.unloadModel()
        let unloadDuration = CFAbsoluteTimeGetCurrent() - unloadStartTime
        let stateAfterUnload = await service.state
        XCTAssertEqual(stateAfterUnload, .unloaded)
        print("[REAL_MODEL_A] Model unloaded in \(String(format: "%.3f", unloadDuration))s")

        // 4. Reload model
        let reloadStartTime = CFAbsoluteTimeGetCurrent()
        let info2 = try await service.loadModel(at: path, configuration: .conservative)
        let reloadDuration = CFAbsoluteTimeGetCurrent() - reloadStartTime
        XCTAssertEqual(info2.sizeInBytes, info1.sizeInBytes)
        print("[REAL_MODEL_A] Model reloaded in \(String(format: "%.3f", reloadDuration))s")

        // 5. Generate with reloaded model
        let stream2 = await service.generate(prompt: "World", configuration: config)
        var tokens2: [String] = []
        for try await token in stream2 {
            tokens2.append(token)
        }
        XCTAssertFalse(tokens2.isEmpty, "Generation 2 must produce tokens.")
        print("[REAL_MODEL_A] Gen 2 text: '\(tokens2.joined())' (\(tokens2.count) chunks)")

        // 6. Clean unload
        try await service.unloadModel()
        let finalState = await service.state
        XCTAssertEqual(finalState, .unloaded)
    }

    /// Scenario B & C: Prompt evaluation, deterministic greedy sampling, and token boundary enforcement.
    func testRealModel_PromptEvaluationAndTokenLimits() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        // Test deterministic greedy output reproducibility
        let config = GenerationConfiguration(contextLength: 512, maxTokens: 8, temperature: 0.0)
        let prompt = "The quick brown fox"

        let streamA = await service.generate(prompt: prompt, configuration: config)
        var textA = ""
        for try await chunk in streamA { textA += chunk }

        let streamB = await service.generate(prompt: prompt, configuration: config)
        var textB = ""
        for try await chunk in streamB { textB += chunk }

        XCTAssertFalse(textA.isEmpty)
        XCTAssertEqual(textA, textB, "Deterministic greedy sampling must produce identical outputs.")
        print("[REAL_MODEL_B] Greedy generation deterministic output: '\(textA)'")

        // Test boundary limits: maxTokens = 1
        let singleTokenConfig = GenerationConfiguration(contextLength: 512, maxTokens: 1, temperature: 0.0)
        let streamSingle = await service.generate(prompt: prompt, configuration: singleTokenConfig)
        var singleText = ""
        for try await chunk in streamSingle { singleText += chunk }
        XCTAssertFalse(singleText.isEmpty, "Single token generation must yield output.")
        print("[REAL_MODEL_B] Single token output: '\(singleText)'")
    }

    /// Scenario C: Input validation boundaries and context configurations.
    func testRealModel_BoundaryConditions() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        // 1. Empty prompt rejected
        let emptyStream = await service.generate(prompt: "")
        do {
            for try await _ in emptyStream { XCTFail("Empty prompt must not produce tokens.") }
            XCTFail("Empty prompt must throw.")
        } catch let err as InferenceError {
            if case .invalidPrompt = err { /* Expected */ } else { XCTFail("Expected .invalidPrompt, got: \(err)") }
        }

        // 2. Whitespace prompt rejected
        let wsStream = await service.generate(prompt: "   \n\t  ")
        do {
            for try await _ in wsStream { XCTFail("Whitespace prompt must not produce tokens.") }
            XCTFail("Whitespace prompt must throw.")
        } catch let err as InferenceError {
            if case .invalidPrompt = err { /* Expected */ } else { XCTFail("Expected .invalidPrompt, got: \(err)") }
        }

        // 3. Small context boundary (64 tokens)
        let smallCtxConfig = GenerationConfiguration(contextLength: 64, maxTokens: 5, temperature: 0.0)
        let smallCtxStream = await service.generate(prompt: "Hello world", configuration: smallCtxConfig)
        var smallCtxText = ""
        for try await chunk in smallCtxStream { smallCtxText += chunk }
        XCTAssertFalse(smallCtxText.isEmpty, "Small context must generate tokens successfully.")
        print("[REAL_MODEL_C] Small context output: '\(smallCtxText)'")
    }

    /// Scenario D: Sequential generation and conflicting request rejection.
    func testRealModel_SequentialAndConflictingRequests() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        // 1. Start Generation 1 with larger maxTokens to keep worker occupied
        let config1 = GenerationConfiguration(contextLength: 512, maxTokens: 40, temperature: 0.0)
        let stream1 = await service.generate(prompt: "Write a short counting sequence: 1, 2, 3,", configuration: config1)

        // 2. Conflicting generation while generation 1 is active must be rejected
        let conflictStream = await service.generate(prompt: "Conflicting prompt")
        do {
            for try await _ in conflictStream { XCTFail("Conflicting generation must not emit tokens.") }
            XCTFail("Conflicting generation must throw.")
        } catch let err as InferenceError {
            if case .conflictingOperation = err { /* Expected */ } else { XCTFail("Expected .conflictingOperation, got: \(err)") }
        }

        // 3. Conflicting unload while generation 1 is active must be rejected
        do {
            try await service.unloadModel()
            XCTFail("Conflicting unload must throw.")
        } catch let err as InferenceError {
            if case .conflictingOperation = err { /* Expected */ } else { XCTFail("Expected .conflictingOperation, got: \(err)") }
        }

        // 4. Drain Generation 1
        var text1 = ""
        for try await chunk in stream1 { text1 += chunk }
        XCTAssertFalse(text1.isEmpty)
        print("[REAL_MODEL_D] Gen 1 finished: '\(text1.prefix(30))...'")

        // 5. Subsequent generation succeeds after Generation 1 finishes
        let config2 = GenerationConfiguration(contextLength: 512, maxTokens: 10, temperature: 0.0)
        let stream2 = await service.generate(prompt: "Say goodbye", configuration: config2)
        var text2 = ""
        for try await chunk in stream2 { text2 += chunk }
        XCTAssertFalse(text2.isEmpty, "Subsequent generation must succeed.")
        print("[REAL_MODEL_D] Sequential Gen 2 finished: '\(text2)'")
    }

    /// Scenario E: Cancellation during token generation and barrier verification.
    func testRealModel_CancellationAndWorkerBarrier() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        _ = try await service.loadModel(at: path, configuration: .conservative)
        defer { Task { try? await service.unloadModel() } }

        // 1. Start generation with large maxTokens
        let config = GenerationConfiguration(contextLength: 512, maxTokens: 200, temperature: 0.0)
        let stream = await service.generate(prompt: "Write a long essay about the history of mathematics.", configuration: config)

        var chunksReceived = 0
        let cancelRequestedTime: CFAbsoluteTime
        do {
            for try await _ in stream {
                chunksReceived += 1
                if chunksReceived >= 3 {
                    // Trigger cancellation after 3 chunks
                    stream.cancel()
                    break
                }
            }
            cancelRequestedTime = CFAbsoluteTimeGetCurrent()
        } catch {
            cancelRequestedTime = CFAbsoluteTimeGetCurrent()
        }

        // 2. Await worker completion barrier
        await stream.waitForTermination()
        let completionTime = CFAbsoluteTimeGetCurrent()
        let barrierLatency = completionTime - cancelRequestedTime
        print("[REAL_MODEL_E] Cancellation barrier latency: \(String(format: "%.3f", barrierLatency))s")

        // 3. Service state must return cleanly to .loaded
        let stateAfterCancel = await service.state
        if case .loaded = stateAfterCancel {
            // Correct
        } else {
            XCTFail("State must return to .loaded after cancellation completes, got: \(stateAfterCancel)")
        }

        // 4. Subsequent generation must succeed cleanly
        let shortConfig = GenerationConfiguration(contextLength: 512, maxTokens: 5, temperature: 0.0)
        let postCancelStream = await service.generate(prompt: "A quick test", configuration: shortConfig)
        var postCancelText = ""
        for try await chunk in postCancelStream { postCancelText += chunk }
        XCTAssertFalse(postCancelText.isEmpty, "Post-cancellation generation must succeed.")
        print("[REAL_MODEL_E] Post-cancellation generation succeeded: '\(postCancelText)'")
    }

    /// Scenario F: Native error recovery and healthy generation after recovery.
    func testRealModel_ErrorRecoveryAndInvalidGGUF() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)

        // 1. Trigger load failure with invalid file
        let invalidPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("corrupted-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: invalidPath, contents: Data("BAD_GGUF_HEADER_DATA".utf8))
        defer { try? FileManager.default.removeItem(atPath: invalidPath) }

        do {
            _ = try await service.loadModel(at: invalidPath, configuration: .conservative)
            XCTFail("Loading corrupted file must throw.")
        } catch let err as InferenceError {
            if case .modelLoadingFailed = err { /* Expected */ } else { XCTFail("Expected .modelLoadingFailed, got: \(err)") }
        }

        let stateAfterFail = await service.state
        if case .failed = stateAfterFail {
            // Expected
        } else {
            XCTFail("Service must be in .failed state after load failure, got: \(stateAfterFail)")
        }

        // 2. Recover by loading genuine model
        let info = try await service.loadModel(at: path, configuration: .conservative)
        XCTAssertEqual(info.path, path)
        print("[REAL_MODEL_F] Recovered from failure by loading real model: \(info.name)")

        // 3. Generate to prove complete health
        let config = GenerationConfiguration(contextLength: 512, maxTokens: 5, temperature: 0.0)
        let stream = await service.generate(prompt: "Testing recovery", configuration: config)
        var text = ""
        for try await chunk in stream { text += chunk }
        XCTAssertFalse(text.isEmpty, "Generation after error recovery must succeed.")
        print("[REAL_MODEL_F] Post-recovery generation: '\(text)'")

        try await service.unloadModel()
        let finalState = await service.state
        XCTAssertEqual(finalState, .unloaded)
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? taskInfo.resident_size : 0
    }

    /// Scenario G (Phase 3.5.1 Validation): Explicit Memory Footprint Profiling
    func testRealModel_MemoryProfilingAcrossLifecycle() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)

        let baselineMemory = currentResidentMemoryBytes()
        print("[MEMORY_METRIC] Baseline resident memory: \(baselineMemory / (1024 * 1024)) MiB")

        // 1. Model Load
        _ = try await service.loadModel(at: path, configuration: .conservative)
        let postLoadMemory = currentResidentMemoryBytes()
        print("[MEMORY_METRIC] Post-load resident memory: \(postLoadMemory / (1024 * 1024)) MiB")
        XCTAssertGreaterThan(postLoadMemory, baselineMemory, "Model load should increase resident memory")

        // 2. Active Generation
        let config = GenerationConfiguration(contextLength: 512, maxTokens: 15, temperature: 0.0)
        let stream = await service.generate(prompt: "Write a short sentence about swift.", configuration: config)
        var duringGenMemory: UInt64 = 0
        var tokens: [String] = []
        for try await token in stream {
            tokens.append(token)
            if duringGenMemory == 0 && tokens.count >= 3 {
                duringGenMemory = currentResidentMemoryBytes()
            }
        }
        let postGenMemory = currentResidentMemoryBytes()
        print("[MEMORY_METRIC] During-generation resident memory: \(duringGenMemory / (1024 * 1024)) MiB")
        print("[MEMORY_METRIC] Post-generation resident memory: \(postGenMemory / (1024 * 1024)) MiB")

        // 3. Model Unload
        try await service.unloadModel()
        let postUnloadMemory = currentResidentMemoryBytes()
        print("[MEMORY_METRIC] Post-unload resident memory: \(postUnloadMemory / (1024 * 1024)) MiB")

        // 4. Multi-turn consecutive stability check
        _ = try await service.loadModel(at: path, configuration: .conservative)
        for turn in 1...3 {
            let turnStream = await service.generate(prompt: "Turn \(turn) test prompt", configuration: config)
            var count = 0
            for try await _ in turnStream { count += 1 }
            let turnMemory = currentResidentMemoryBytes()
            print("[MEMORY_METRIC] Consecutive turn \(turn) memory: \(turnMemory / (1024 * 1024)) MiB")
        }
        try await service.unloadModel()
    }

    // MARK: - Phase 3.8.3: Inference Worker Teardown Safety & Deadlock Regression Suite (DEF-38-05)

    /// 1. Verifies that releasing the final reference to a worker while executing on its own serial queue
    /// runs cleanup inline without triggering a libdispatch self-deadlock (__DISPATCH_WAIT_FOR_QUEUE__).
    func testWorkerDeinitOnWorkerQueuePreventsDeadlock() async throws {
        var worker: LlamaInferenceWorker? = LlamaInferenceWorker()
        try await worker?.initializeBackend()

        let expectation = expectation(description: "Worker deinit on worker queue completes without deadlock")

        // Capture worker into a queue block, then nil out the outer reference.
        // The block on executionQueue will hold the final reference and deallocate worker on completion.
        worker?.executionQueue.async {
            worker = nil
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    /// 2. Verifies that releasing a worker from an external thread (outside the worker queue)
    /// synchronizes cleanly with the worker queue via queue.sync.
    func testWorkerDeinitFromExternalThread() async throws {
        var worker: LlamaInferenceWorker? = LlamaInferenceWorker()
        try await worker?.initializeBackend()
        let isLoaded = await worker?.isModelLoaded()
        XCTAssertEqual(isLoaded, false)

        // Drop reference on cooperative async task context (external to worker.queue)
        worker = nil
        XCTAssertNil(worker)
    }

    /// 3. Verifies that repeated and concurrent shutdown and unload requests complete safely without deadlocks or races.
    func testRepeatedAndConcurrentShutdownAndUnload() async throws {
        let worker = LlamaInferenceWorker()
        try await worker.initializeBackend()

        // Concurrent execution of shutdown and unloadModel
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await worker.shutdown()
                }
                group.addTask {
                    try? await worker.unloadModel()
                }
            }
        }

        // Sequential repeated calls after shutdown
        await worker.shutdown()
        await worker.shutdown()
        try await worker.unloadModel()

        let isLoaded = await worker.isModelLoaded()
        XCTAssertFalse(isLoaded)
    }

    /// 4. Verifies that native resources are cleaned up safely and idempotently without double-free errors.
    func testNativeCleanupExecutesExactlyOnce() async throws {
        var worker: LlamaInferenceWorker? = LlamaInferenceWorker()
        try await worker?.initializeBackend()

        // First shutdown frees native backend and sets isShutdown = true
        await worker?.shutdown()

        // Second shutdown is an idempotent no-op
        await worker?.shutdown()

        // Deallocation should detect resources are already cleaned up and perform zero redundant calls
        worker = nil
        XCTAssertNil(worker)
    }

    /// 5. Verifies safe release after failed or interrupted initialization.
    func testWorkerReleaseAfterFailedInitialization() async throws {
        var worker: LlamaInferenceWorker? = LlamaInferenceWorker()

        // Attempt to load from non-existent path
        do {
            _ = try await worker?.loadModel(at: "/nonexistent/test/model.gguf", configuration: .conservative)
            XCTFail("Load of non-existent model should fail.")
        } catch {
            // Expected failure
        }

        // Release worker immediately without explicit shutdown
        worker = nil
        XCTAssertNil(worker)
    }

    /// 6. Verifies cancellation and teardown around active inference.
    func testWorkerCancellationAndTeardownAroundActiveInference() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        var worker: LlamaInferenceWorker? = LlamaInferenceWorker()
        let service = InferenceService(worker: worker!)
        _ = try await service.loadModel(at: path, configuration: .conservative)

        let signal = CancellationSignal()
        let config = GenerationConfiguration(contextLength: 512, maxTokens: 100, temperature: 0.0)

        // Cancel signal immediately before or during generation
        signal.cancel()

        do {
            try await worker?.generate(prompt: "Hello", configuration: config, cancellationSignal: signal, onToken: { _ in })
            XCTFail("Expected cancellation error.")
        } catch let err as InferenceError {
            if case .cancelled = err {
                // Expected cancellation
            } else {
                XCTFail("Expected .cancelled, got \(err)")
            }
        }

        // Safe teardown after cancellation
        try await service.unloadModel()
        await service.shutdown()
        worker = nil
        XCTAssertNil(worker)
    }

    /// 7. Stress test: 50 rapid sequential creation, initialization, and deallocation cycles
    /// alternating between external-thread and in-queue deallocations.
    func testRapidWorkerCreationAndDestructionStressMatrix() async throws {
        for iteration in 1...50 {
            var worker: LlamaInferenceWorker? = LlamaInferenceWorker()
            try await worker?.initializeBackend()

            if iteration % 2 == 0 {
                // In-queue deallocation
                let exp = expectation(description: "Stress in-queue teardown cycle \(iteration)")
                worker?.executionQueue.async {
                    worker = nil
                    exp.fulfill()
                }
                await fulfillment(of: [exp], timeout: 2.0)
            } else {
                // External-thread deallocation
                worker = nil
                XCTAssertNil(worker)
            }
        }
    }

    /// Scenario H (DEF-39-01 Regression): Long prompt exceeding batch size (512 tokens) is chunked safely without SIGABRT crash.
    func testRealModel_Z_LongPromptChunkingExceedingBatchSize() async throws {
        guard let path = candidateModelPath else {
            throw XCTSkip("No local candidate GGUF model available at expected path.")
        }

        let worker = LlamaInferenceWorker()
        let service = InferenceService(worker: worker)
        // Configure with conservative model settings
        let config = ModelConfiguration.conservative
        _ = try await service.loadModel(at: path, configuration: config)

        // Generate a long prompt that tokenizes to >512 tokens (e.g. repeat a paragraph 12 times)
        let paragraph = "Write a comprehensive Python script using Tkinter to build a desktop notepad application with file open, save, text editing, syntax highlighting, search and replace, font customization, and word count features. Ensure all buttons and menus are properly wired with event handlers and error dialogs.\n"
        let longPrompt = "<|im_start|>user\n" + String(repeating: paragraph, count: 12) + "Please write the python code below.<|im_end|>\n<|im_start|>assistant\n"

        let tokenCount = try await service.countTokens(for: longPrompt)
        print("[CHUNK_TEST] Prompt token count: \(tokenCount) tokens (batch limit is 512)")
        XCTAssertGreaterThan(tokenCount, 512, "Test requires prompt token count to exceed the 512 batch limit")

        let genConfig = GenerationConfiguration(contextLength: 2048, maxTokens: 10, temperature: 0.0)
        let stream = await service.generate(prompt: longPrompt, configuration: genConfig)
        var outputTokens: [String] = []
        for try await token in stream {
            outputTokens.append(token)
        }
        XCTAssertFalse(outputTokens.isEmpty, "Chunked prompt generation must succeed and produce tokens")
        print("[CHUNK_TEST] Successfully generated tokens for long prompt: '\(outputTokens.joined())'")

        // Synchronously unload and shutdown to release memory
        try await service.unloadModel()
        await service.shutdown()
    }
}


