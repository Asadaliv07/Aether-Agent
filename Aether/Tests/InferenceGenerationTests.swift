import XCTest
@testable import Aether

/// Mock worker for deterministic unit testing of generation, streaming, and cancellation behavior.
internal actor MockGenerationWorker: InferenceWorkerProtocol {
    private var isLoadedState: Bool = false
    private var tokenSequence: [String] = ["Hello", " world", "!", " How", " are", " you", "?"]
    private var shouldFailDecode: Bool = false
    private var delayPerTokenNanoseconds: UInt64 = 10_000_000 // 10ms
    private(set) var generateCallCount: Int = 0

    private var isGated: Bool = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var onStartContinuation: CheckedContinuation<Void, Never>?
    private var blockBeforeTokenIndex: Int?
    private var tokenGateContinuation: CheckedContinuation<Void, Never>?
    private var capturedSignal: CancellationSignal?
    private var throwErrorOnExit: InferenceError?

    init(isInitiallyLoaded: Bool = true) {
        self.isLoadedState = isInitiallyLoaded
    }

    func setTokenSequence(_ tokens: [String]) {
        self.tokenSequence = tokens
    }

    func setShouldFailDecode(_ fail: Bool) {
        self.shouldFailDecode = fail
    }

    func setDelayPerTokenNanoseconds(_ delay: UInt64) {
        self.delayPerTokenNanoseconds = delay
    }

    func setGated(_ gated: Bool) {
        self.isGated = gated
    }

    func setBlockBeforeTokenIndex(_ index: Int?) {
        self.blockBeforeTokenIndex = index
    }

    func setThrowErrorOnExit(_ error: InferenceError?) {
        self.throwErrorOnExit = error
    }

    func waitForGenerateStart() async {
        if generateCallCount > 0 { return }
        await withCheckedContinuation { cont in
            self.onStartContinuation = cont
        }
    }

    func openGate() {
        gateContinuation?.resume()
        gateContinuation = nil
        isGated = false
    }

    func openTokenGate() {
        tokenGateContinuation?.resume()
        tokenGateContinuation = nil
        blockBeforeTokenIndex = nil
    }

    func getCapturedSignal() -> CancellationSignal? {
        return capturedSignal
    }

    func initializeBackend() async throws {}

    func loadModel(at path: String, configuration: ModelConfiguration) async throws -> ModelInfo {
        isLoadedState = true
        return ModelInfo(
            path: path,
            name: (path as NSString).lastPathComponent,
            sizeInBytes: 1024 * 1024 * 50,
            description: "Mock GGUF Model"
        )
    }

    func unloadModel() async throws {
        isLoadedState = false
    }

    func shutdown() async {
        isLoadedState = false
    }

    func isModelLoaded() async -> Bool {
        return isLoadedState
    }

    private var mockChatTemplate: String? = nil

    func setMockChatTemplate(_ template: String?) {
        self.mockChatTemplate = template
    }

    func getModelChatTemplate() async -> String? {
        return mockChatTemplate
    }

    func countTokens(for text: String) async throws -> Int {
        guard isLoadedState else { throw InferenceError.notLoaded }
        if text.isEmpty { return 0 }
        return max(1, text.count / 4)
    }

    func generate(
        prompt: String,
        configuration: GenerationConfiguration,
        cancellationSignal: CancellationSignal,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws {
        generateCallCount += 1
        capturedSignal = cancellationSignal
        onStartContinuation?.resume()
        onStartContinuation = nil

        guard isLoadedState else {
            throw InferenceError.notLoaded
        }

        try configuration.validate()

        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceError.invalidPrompt("Prompt cannot be empty.")
        }

        if isGated {
            await withCheckedContinuation { cont in
                self.gateContinuation = cont
            }
        }

        if let error = throwErrorOnExit {
            throw error
        }

        if cancellationSignal.isCancelled {
            throw InferenceError.cancelled
        }

        var emittedCount = 0
        for token in tokenSequence {
            if cancellationSignal.isCancelled {
                throw InferenceError.cancelled
            }

            if emittedCount >= configuration.maxTokens {
                break
            }

            if shouldFailDecode && emittedCount == 2 {
                throw InferenceError.decodeFailed(code: -1, description: "Simulated decode failure.")
            }

            if let blockIdx = blockBeforeTokenIndex, emittedCount == blockIdx {
                await withCheckedContinuation { cont in
                    self.tokenGateContinuation = cont
                }
            }

            if let error = throwErrorOnExit {
                throw error
            }

            if cancellationSignal.isCancelled {
                throw InferenceError.cancelled
            }

            if delayPerTokenNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayPerTokenNanoseconds)
            }

            if cancellationSignal.isCancelled {
                throw InferenceError.cancelled
            }

            onToken(token)
            emittedCount += 1
        }
    }
}

final class InferenceGenerationTests: XCTestCase {

    // Helper to create a loaded service
    private func makeLoadedService(worker: any InferenceWorkerProtocol) async throws -> InferenceService {
        let service = InferenceService(worker: worker)
        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("test-model-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempPath, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        _ = try await service.loadModel(at: tempPath)
        return service
    }

    // MARK: - Validation Tests

    func testEmptyAndWhitespacePromptsThrow() async throws {
        let mock = MockGenerationWorker()
        let service = try await makeLoadedService(worker: mock)

        // Empty prompt
        let emptyStream = await service.generate(prompt: "")
        do {
            for try await _ in emptyStream {
                XCTFail("Empty prompt must not produce tokens.")
            }
            XCTFail("Empty prompt must throw an error.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .invalidPrompt("Prompt cannot be empty or whitespace only."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Whitespace prompt
        let whitespaceStream = await service.generate(prompt: "   \n\t  ")
        do {
            for try await _ in whitespaceStream {
                XCTFail("Whitespace prompt must not produce tokens.")
            }
            XCTFail("Whitespace prompt must throw an error.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .invalidPrompt("Prompt cannot be empty or whitespace only."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidConfigurationValidation() throws {
        // Zero contextLength
        let zeroCtx = GenerationConfiguration(contextLength: 0)
        XCTAssertThrowsError(try zeroCtx.validate()) { error in
            XCTAssertEqual(error as? InferenceError, .invalidConfiguration("contextLength must be greater than zero."))
        }

        // Zero maxTokens
        let zeroTokens = GenerationConfiguration(maxTokens: 0)
        XCTAssertThrowsError(try zeroTokens.validate()) { error in
            XCTAssertEqual(error as? InferenceError, .invalidConfiguration("maxTokens must be greater than zero."))
        }

        // Negative temperature
        let negTemp = GenerationConfiguration(temperature: -0.5)
        XCTAssertThrowsError(try negTemp.validate()) { error in
            XCTAssertEqual(error as? InferenceError, .invalidConfiguration("temperature must be non-negative."))
        }

        // Invalid topP
        let invalidTopP = GenerationConfiguration(topP: 0.0)
        XCTAssertThrowsError(try invalidTopP.validate()) { error in
            XCTAssertEqual(error as? InferenceError, .invalidConfiguration("topP must be in (0.0, 1.0]."))
        }
    }

    func testGenerateWhenNotLoadedThrows() async {
        let mock = MockGenerationWorker(isInitiallyLoaded: false)
        let service = InferenceService(worker: mock)

        let stream = await service.generate(prompt: "Hello")
        do {
            for try await _ in stream {
                XCTFail("Generating when unloaded must not yield tokens.")
            }
            XCTFail("Generating when unloaded must throw notLoaded.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Streaming and Ordering Tests

    func testSuccessfulGenerationStreamingInOrder() async throws {
        let mock = MockGenerationWorker()
        let expectedTokens = ["The", " quick", " brown", " fox"]
        await mock.setTokenSequence(expectedTokens)
        await mock.setDelayPerTokenNanoseconds(1_000_000)

        let service = try await makeLoadedService(worker: mock)

        var receivedTokens: [String] = []
        let stream = await service.generate(prompt: "Tell me a story", configuration: .default)

        for try await chunk in stream {
            receivedTokens.append(chunk)
        }

        XCTAssertEqual(receivedTokens, expectedTokens, "Tokens must be streamed in exact generated order.")
        let finalState = await service.state
        if case .loaded = finalState {
            // Expected return to .loaded
        } else {
            XCTFail("Service state must return to .loaded after completion, got: \(finalState)")
        }
    }

    func testMaxTokensEnforcement() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["A", "B", "C", "D", "E", "F", "G"])
        await mock.setDelayPerTokenNanoseconds(1_000_000)

        let service = try await makeLoadedService(worker: mock)

        var receivedTokens: [String] = []
        let config = GenerationConfiguration(maxTokens: 3)
        let stream = await service.generate(prompt: "Alphabet", configuration: config)

        for try await chunk in stream {
            receivedTokens.append(chunk)
        }

        XCTAssertEqual(receivedTokens.count, 3, "Generation must stop once maxTokens is reached.")
        XCTAssertEqual(receivedTokens, ["A", "B", "C"])
    }

    // MARK: - Cancellation Tests

    func testConsumerEarlyTerminationTriggersCancellation() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["One", "Two", "Three", "Four", "Five"])
        await mock.setDelayPerTokenNanoseconds(20_000_000) // 20ms per token

        let service = try await makeLoadedService(worker: mock)

        var receivedCount = 0
        let stream = await service.generate(prompt: "Count to 5")

        // Consumer breaks early after 2 tokens
        for try await _ in stream {
            receivedCount += 1
            if receivedCount == 2 {
                break
            }
        }

        XCTAssertEqual(receivedCount, 2)

        // Allow worker to observe cancellation and exit
        try await Task.sleep(nanoseconds: 50_000_000)

        let state = await service.state
        if case .loaded = state {
            // State must recover to .loaded
        } else {
            XCTFail("Service must return to .loaded after consumer cancellation, got: \(state)")
        }
    }

    func testSubsequentGenerationAfterCancellationSucceeds() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["Step1", "Step2", "Step3"])
        await mock.setDelayPerTokenNanoseconds(20_000_000)

        let service = try await makeLoadedService(worker: mock)

        // First generation cancelled early
        let stream1 = await service.generate(prompt: "First")
        for try await _ in stream1 {
            break
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        // Second generation must succeed without requiring reload
        await mock.setTokenSequence(["Fresh1", "Fresh2"])
        await mock.setDelayPerTokenNanoseconds(1_000_000)

        var secondOutput: [String] = []
        let stream2 = await service.generate(prompt: "Second")
        for try await chunk in stream2 {
            secondOutput.append(chunk)
        }

        XCTAssertEqual(secondOutput, ["Fresh1", "Fresh2"])
        let state = await service.state
        if case .loaded = state {
            // Clean state
        } else {
            XCTFail("Service must remain loaded after recovery generation.")
        }
    }

    // MARK: - Conflicting Operations

    func testConflictingGenerationThrows() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["T1", "T2", "T3", "T4"])
        await mock.setDelayPerTokenNanoseconds(50_000_000) // 50ms per token

        let service = try await makeLoadedService(worker: mock)

        let stream1 = await service.generate(prompt: "Run 1")

        // Start stream 1 in background task
        let task1 = Task {
            var count = 0
            for try await _ in stream1 {
                count += 1
            }
            return count
        }

        // Wait briefly for stream1 to enter .generating state
        try await Task.sleep(nanoseconds: 10_000_000)

        let currentState = await service.state
        if case .generating = currentState {
            // Confirmed in generating state
        } else {
            XCTFail("Service must be in .generating state, got: \(currentState)")
        }

        // Second generation attempt while first is in progress must fail
        let stream2 = await service.generate(prompt: "Run 2")
        do {
            for try await _ in stream2 {
                XCTFail("Second generation must not yield tokens.")
            }
            XCTFail("Second generation must throw conflictingOperation.")
        } catch let error as InferenceError {
            if case .conflictingOperation = error {
                // Expected conflict rejection
            } else {
                XCTFail("Expected .conflictingOperation, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Attempting to unload while generating must also fail
        do {
            try await service.unloadModel()
            XCTFail("Unloading during generation must throw conflictingOperation.")
        } catch let error as InferenceError {
            if case .conflictingOperation = error {
                // Expected conflict rejection
            } else {
                XCTFail("Expected .conflictingOperation, got: \(error)")
            }
        }

        _ = try await task1.value
    }

    // MARK: - Native Worker Safeguards

    func testNativeWorkerWhenNotLoadedThrows() async {
        let worker = LlamaInferenceWorker()
        let signal = CancellationSignal()

        do {
            try await worker.generate(
                prompt: "Hello",
                configuration: .default,
                cancellationSignal: signal,
                onToken: { _ in }
            )
            XCTFail("Native worker must throw notLoaded when no model is active.")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Finding A & C: Stream Lifecycle and Cancellation Tests

    func testStreamRequestedAndAbandonedWithoutIterationHaultsAndRecovers() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["A", "B", "C", "D", "E"])
        await mock.setDelayPerTokenNanoseconds(50_000_000)

        let service = try await makeLoadedService(worker: mock)

        // Request stream in a scope and drop it immediately without iterating
        do {
            _ = await service.generate(prompt: "Abandoned")
        }

        // Allow deinit and stream.cancel() to fire and propagate to mock worker
        try await Task.sleep(nanoseconds: 100_000_000)

        let stateAfterAbandon = await service.state
        if case .loaded = stateAfterAbandon {
            // Success: state restored to .loaded
        } else {
            XCTFail("Service must return to .loaded after stream abandonment, got: \(stateAfterAbandon)")
        }

        // Verify a new generation can succeed immediately after abandonment
        await mock.setTokenSequence(["Fresh1", "Fresh2"])
        await mock.setDelayPerTokenNanoseconds(1_000_000)

        var output: [String] = []
        let newStream = await service.generate(prompt: "Subsequent")
        for try await chunk in newStream {
            output.append(chunk)
        }
        XCTAssertEqual(output, ["Fresh1", "Fresh2"])
    }

    func testConsumerTaskCancellationPropagatesToWorker() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["T1", "T2", "T3", "T4", "T5"])
        await mock.setDelayPerTokenNanoseconds(50_000_000)

        let service = try await makeLoadedService(worker: mock)

        let stream = await service.generate(prompt: "CancelMe")
        let consumerTask = Task {
            var tokens: [String] = []
            for try await token in stream {
                tokens.append(token)
            }
            return tokens
        }

        // Wait for generation to start
        try await Task.sleep(nanoseconds: 20_000_000)
        consumerTask.cancel()

        do {
            _ = try await consumerTask.value
            XCTFail("Consumer task must throw CancellationError upon cancellation")
        } catch is CancellationError {
            // Expected
        } catch let error as InferenceError where error == .cancelled {
            // Also acceptable if mapped
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let finalState = await service.state
        if case .loaded = finalState {
            // Correctly returned to .loaded
        } else {
            XCTFail("Service must return to .loaded after consumer task cancellation, got: \(finalState)")
        }
    }

    func testStreamMultipleIteratorsRejected() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["X", "Y"])
        await mock.setDelayPerTokenNanoseconds(10_000_000)

        let service = try await makeLoadedService(worker: mock)
        let stream = await service.generate(prompt: "MultiIter")

        // First iterator
        var it1 = stream.makeAsyncIterator()
        _ = try await it1.next()

        // Second iterator must fail with conflictingOperation
        var it2 = stream.makeAsyncIterator()
        do {
            _ = try await it2.next()
            XCTFail("Second iterator must throw conflictingOperation")
        } catch let error as InferenceError {
            if case .conflictingOperation = error {
                // Expected
            } else {
                XCTFail("Expected .conflictingOperation, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Finding B: State Reservation and Race Prevention Tests

    func testRapidSequentialGenerationRequestsDoNotCorruptState() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["Slow1", "Slow2", "Slow3"])
        await mock.setDelayPerTokenNanoseconds(50_000_000)

        let service = try await makeLoadedService(worker: mock)

        // Launch request 1
        let stream1 = await service.generate(prompt: "Req1")

        // Immediately launch request 2 while 1 is active (state is .generating)
        let stream2 = await service.generate(prompt: "Req2")

        // Stream 2 must yield conflictingOperation upon consumption
        do {
            for try await _ in stream2 {
                XCTFail("Stream 2 must not yield any tokens")
            }
            XCTFail("Stream 2 must throw conflictingOperation")
        } catch let error as InferenceError {
            if case .conflictingOperation = error {
                // Expected rejection of conflicting request
            } else {
                XCTFail("Expected conflictingOperation, got: \(error)")
            }
        }

        // Stream 1 must continue generating safely without being corrupted or cancelled by stream 2
        var stream1Tokens: [String] = []
        for try await token in stream1 {
            stream1Tokens.append(token)
        }
        XCTAssertEqual(stream1Tokens, ["Slow1", "Slow2", "Slow3"])

        let finalState = await service.state
        if case .loaded = finalState {
            // Correct
        } else {
            XCTFail("Service must return to .loaded, got: \(finalState)")
        }
    }

    func testRejectedRequestCannotReplaceActiveCancellationSignal() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["A", "B", "C", "D"])
        await mock.setDelayPerTokenNanoseconds(50_000_000)

        let service = try await makeLoadedService(worker: mock)

        let stream1 = await service.generate(prompt: "Original")

        // Consume one token from stream 1 to be certain it is running
        var it1 = stream1.makeAsyncIterator()
        let first = try await it1.next()
        XCTAssertEqual(first, "A")

        // Issue a second conflicting request that will be rejected
        let stream2 = await service.generate(prompt: "Conflicting")
        do {
            for try await _ in stream2 { }
        } catch {
            // Rejected as expected
        }

        // Now cancel generation via service.cancelGeneration()
        await service.cancelGeneration()

        // Stream 1 should now be cancelled, confirming the cancellation signal was NOT clobbered by stream 2
        do {
            while let _ = try await it1.next() { }
        } catch is CancellationError {
            // Expected cancellation
        } catch let error as InferenceError where error == .cancelled {
            // Expected cancellation
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let state = await service.state
        if case .loaded = state {
            // Recovered
        } else {
            XCTFail("Expected .loaded state, got: \(state)")
        }
    }

    // MARK: - Finding D: UTF-8 Accumulator Tests

    func testUTF8BufferValidASCII() {
        var buffer = UTF8Buffer()
        let bytes = Array("Hello, World!".utf8)
        let emitted = buffer.processBytes(bytes)
        XCTAssertEqual(emitted, "Hello, World!")
        XCTAssertEqual(buffer.flush(), "")
    }

    func testUTF8BufferMultibyteSplitAcrossChunks() {
        var buffer = UTF8Buffer()
        // Euro symbol '€' is 3 bytes: 0xE2, 0x82, 0xAC
        let euroBytes: [UInt8] = Array("€".utf8)

        let chunk1 = buffer.processBytes([euroBytes[0]])
        XCTAssertEqual(chunk1, "", "First byte of 3-byte sequence must be buffered")

        let chunk2 = buffer.processBytes([euroBytes[1]])
        XCTAssertEqual(chunk2, "", "Second byte of 3-byte sequence must be buffered")

        let chunk3 = buffer.processBytes([euroBytes[2]])
        XCTAssertEqual(chunk3, "€", "Complete 3-byte sequence must be emitted")

        XCTAssertEqual(buffer.flush(), "")
    }

    func testUTF8BufferEmojiSplitAcrossChunks() {
        var buffer = UTF8Buffer()
        // Rocket emoji '🚀' is 4 bytes
        let rocketBytes: [UInt8] = Array("🚀".utf8)

        let chunk1 = buffer.processBytes([rocketBytes[0], rocketBytes[1]])
        XCTAssertEqual(chunk1, "", "First 2 bytes of 4-byte emoji must be buffered")

        let chunk2 = buffer.processBytes([rocketBytes[2], rocketBytes[3]])
        XCTAssertEqual(chunk2, "🚀", "Full emoji must be emitted when remaining bytes arrive")

        XCTAssertEqual(buffer.flush(), "")
    }

    func testUTF8BufferMalformedByteRecovery() {
        var buffer = UTF8Buffer()
        // Invalid start byte 0xFF followed by valid ASCII 'abc'
        let malformedBytes: [UInt8] = [0xFF, 0x61, 0x62, 0x63]
        let result = buffer.processBytes(malformedBytes)
        // Must emit replacement character U+FFFD for 0xFF, followed by 'abc'
        XCTAssertEqual(result, "\u{FFFD}abc", "Malformed byte must be replaced without poisoning accumulator")
        XCTAssertEqual(buffer.flush(), "")
    }

    func testUTF8BufferTrailingIncompleteFlushedAsReplacement() {
        var buffer = UTF8Buffer()
        // Incomplete 2-byte sequence start: 0xC3 (start of 'é' without trailing continuation byte)
        let chunk = buffer.processBytes([0xC3])
        XCTAssertEqual(chunk, "")

        // Generation ends: flush must emit U+FFFD and empty the buffer
        let flushed = buffer.flush()
        XCTAssertEqual(flushed, "\u{FFFD}")
        XCTAssertEqual(buffer.flush(), "")
    }

    // MARK: - Native Generation Correctness (Findings E & F)

    func testExactMaxTokensBoundaryStopsWithoutExtraTokens() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["1", "2", "3", "4", "5"])
        await mock.setDelayPerTokenNanoseconds(1_000_000)

        let service = try await makeLoadedService(worker: mock)
        let config = GenerationConfiguration(maxTokens: 1)
        let stream = await service.generate(prompt: "OneToken", configuration: config)

        var count = 0
        for try await _ in stream {
            count += 1
        }
        XCTAssertEqual(count, 1, "Must generate exactly maxTokens = 1 without extra evaluation")
    }

    func testGenerationConfigurationValidationAndDefaults() {
        let config = GenerationConfiguration.default
        XCTAssertEqual(config.contextLength, 2048)
        XCTAssertEqual(config.maxTokens, 256)
        XCTAssertEqual(config.temperature, 0.0)
        XCTAssertEqual(config.topP, 0.95)
        XCTAssertEqual(config.topK, 40)
        XCTAssertEqual(config.seed, 1234)
        XCTAssertNoThrow(try config.validate())
    }

    // MARK: - Phase 3.4.7 Remediation Tests (Findings ADV-01, ADV-02, ADV-03)

    func testADV01_staleGenerationCannotCorruptActiveGeneration() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["A1", "A2", "A3"])
        await mock.setDelayPerTokenNanoseconds(0)

        let service = try await makeLoadedService(worker: mock)

        // 1. Generation A starts with gate closed
        await mock.setGated(true)
        let streamA = await service.generate(prompt: "GenA")
        await mock.waitForGenerateStart()

        // 2. Cancellation is requested on A while it is blocked in worker
        streamA.cancel()

        // 3. Generation B must be rejected while A is still active in the worker
        let streamBAttempt = await service.generate(prompt: "GenB-TooEarly")
        do {
            for try await _ in streamBAttempt {
                XCTFail("Must not yield tokens while previous generation is active")
            }
            XCTFail("Must throw conflictingOperation")
        } catch let err as InferenceError {
            if case .conflictingOperation = err {
                // Expected: Generation B cannot interleave with active Generation A
            } else {
                XCTFail("Expected .conflictingOperation, got: \(err)")
            }
        }

        // 4. Release Generation A with a simulated decode failure
        await mock.setThrowErrorOnExit(InferenceError.decodeFailed(code: -1, description: "Late error from A"))
        await mock.openGate()
        await streamA.waitForTermination()

        // Allow Generation A to fully complete its failure path
        do {
            for try await _ in streamA { }
        } catch {
            // Expected failure from A
        }

        // Service state must be .failed because A owned the generation when it failed
        let stateAfterA = await service.state
        if case .failed = stateAfterA {
            // Correct
        } else {
            XCTFail("Service must be .failed after A's error, got: \(stateAfterA)")
        }

        // 5. Recovery load succeeds
        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("recovery-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: tempPath, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        _ = try await service.loadModel(at: tempPath)

        // 6. Generation B runs and completes cleanly to .loaded
        await mock.setThrowErrorOnExit(nil)
        await mock.setGated(false)
        await mock.setTokenSequence(["B1", "B2"])

        var bTokens: [String] = []
        let streamB = await service.generate(prompt: "GenB-Success")
        for try await token in streamB {
            bTokens.append(token)
        }
        XCTAssertEqual(bTokens, ["B1", "B2"])
        await streamB.waitForTermination()

        let finalState = await service.state
        if case .loaded = finalState {
            // Correct
        } else {
            XCTFail("Service state must return to .loaded after Generation B finishes, got: \(finalState)")
        }
    }

    func testADV02_serviceDoesNotRestoreLoadedWhileWorkerActive() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["Token1", "Token2"])
        await mock.setDelayPerTokenNanoseconds(0)

        let service = try await makeLoadedService(worker: mock)

        // 1. Start Generation with gate closed
        await mock.setGated(true)
        let stream = await service.generate(prompt: "BlockMe")
        await mock.waitForGenerateStart()

        // 2. Trigger stream cancellation
        stream.cancel()

        // 3. Worker is still held inside generate(); service must NOT report .loaded
        let stateWhileGated = await service.state
        if case .generating = stateWhileGated {
            // Correct: Still reported as .generating while worker execution is active
        } else {
            XCTFail("Service must remain in .generating state while worker is active, got: \(stateWhileGated)")
        }

        // 4. Conflicting generation must be rejected
        let conflictStream = await service.generate(prompt: "Conflict")
        do {
            for try await _ in conflictStream { }
            XCTFail("Conflicting request must throw")
        } catch let err as InferenceError {
            if case .conflictingOperation = err {
                // Expected
            } else {
                XCTFail("Expected .conflictingOperation, got: \(err)")
            }
        }

        // 5. Conflicting unload must be rejected
        do {
            try await service.unloadModel()
            XCTFail("Unload during active generation must throw")
        } catch let err as InferenceError {
            if case .conflictingOperation = err {
                // Expected
            } else {
                XCTFail("Expected .conflictingOperation, got: \(err)")
            }
        }

        // 6. Release worker gate to complete cancellation
        await mock.openGate()
        await stream.waitForTermination()

        // Allow stream iteration to consume cancellation
        do {
            for try await _ in stream { }
        } catch is CancellationError {
            // Expected
        } catch let err as InferenceError where err == .cancelled {
            // Expected
        }

        // 7. Now service must transition to .loaded
        let stateAfterRelease = await service.state
        if case .loaded = stateAfterRelease {
            // Correctly restored to .loaded only after worker finished
        } else {
            XCTFail("Service must transition to .loaded after worker completes, got: \(stateAfterRelease)")
        }

        // 8. Subsequent unload succeeds
        try await service.unloadModel()
        let stateAfterUnload = await service.state
        XCTAssertEqual(stateAfterUnload, .unloaded)
    }

    func testADV02_cancellationFollowedByDelayedNativeErrorLeavesFailedState() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["X", "Y"])
        await mock.setDelayPerTokenNanoseconds(0)

        let service = try await makeLoadedService(worker: mock)

        // Hold generation inside worker
        await mock.setGated(true)
        let stream = await service.generate(prompt: "LateError")
        await mock.waitForGenerateStart()

        // Request cancellation
        stream.cancel()

        // Configure delayed non-cancellation error upon worker exit
        await mock.setThrowErrorOnExit(InferenceError.decodeFailed(code: -1, description: "Late GPU bus error"))

        // Release gate
        await mock.openGate()
        await stream.waitForTermination()

        do {
            for try await _ in stream { }
        } catch {
            // Caught expected failure
        }

        // Service state must be .failed, NOT incorrectly restored to .loaded
        let state = await service.state
        if case .failed = state {
            // Correct
        } else {
            XCTFail("Service must remain in .failed state after native error, got: \(state)")
        }
    }

    func testADV03_cancellationWhileNextSuspendedPropagatesPromptly() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["TokenA", "TokenB", "TokenC"])
        await mock.setDelayPerTokenNanoseconds(0)

        let service = try await makeLoadedService(worker: mock)

        // Block before token index 1 (after TokenA is emitted)
        await mock.setBlockBeforeTokenIndex(1)

        let stream = await service.generate(prompt: "Prompt")
        let firstTokenReceived = expectation(description: "First token received")

        let consumerTask = Task {
            var received: [String] = []
            for try await token in stream {
                received.append(token)
                if received.count == 1 {
                    firstTokenReceived.fulfill()
                }
            }
            return received
        }

        // Wait until first token arrives and consumer task is suspended awaiting token 1
        await fulfillment(of: [firstTokenReceived], timeout: 2.0)

        // Cancel the consumer task while suspended inside next()
        consumerTask.cancel()

        // Verify withTaskCancellationHandler has immediately asserted the cancellation signal
        // without waiting for token 1
        let signal = await mock.getCapturedSignal()
        XCTAssertNotNil(signal)
        XCTAssertTrue(signal?.isCancelled ?? false, "Cancellation signal must be immediately asserted when task cancels while suspended")

        // Verify service state has NOT prematurely become .loaded while worker is still blocked
        let stateDuringBlock = await service.state
        if case .generating = stateDuringBlock {
            // Correct: Still .generating
        } else {
            XCTFail("Service must not report .loaded while worker is blocked, got: \(stateDuringBlock)")
        }

        // Unblock worker gate to allow cooperative cancellation to complete
        await mock.openTokenGate()

        // Consumer task must throw CancellationError
        do {
            _ = try await consumerTask.value
            XCTFail("Consumer task must throw CancellationError")
        } catch is CancellationError {
            // Expected
        } catch let err as InferenceError where err == .cancelled {
            // Also acceptable
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Wait for generation task to fully complete its defer block
        await stream.waitForTermination()

        // Verify service transitions to .loaded after worker completes
        let finalState = await service.state
        if case .loaded = finalState {
            // Correct
        } else {
            XCTFail("Service must return to .loaded after worker completes cancellation, got: \(finalState)")
        }
    }

    func testADV03_cancellationCallbackFromTerminatedGenerationCannotCancelNewGeneration() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["Gen1Token"])
        await mock.setDelayPerTokenNanoseconds(0)

        let service = try await makeLoadedService(worker: mock)

        // Generation 1 completes normally
        let stream1 = await service.generate(prompt: "Gen1")
        for try await _ in stream1 { }

        let stateAfter1 = await service.state
        if case .loaded = stateAfter1 {
            // Correct
        } else {
            XCTFail("Expected .loaded after generation 1, got \(stateAfter1)")
        }

        // Generation 2 starts
        await mock.setTokenSequence(["Gen2TokenA", "Gen2TokenB"])
        let stream2 = await service.generate(prompt: "Gen2")

        // Fire a delayed cancel on stream 1
        stream1.cancel()

        // Stream 2 must NOT be cancelled
        var tokens2: [String] = []
        for try await token in stream2 {
            tokens2.append(token)
        }
        XCTAssertEqual(tokens2, ["Gen2TokenA", "Gen2TokenB"])

        let finalState = await service.state
        if case .loaded = finalState {
            // Correct
        } else {
            XCTFail("Service state must be .loaded, got: \(finalState)")
        }
    }

    func testADV03_workerErrorsAreNotSwallowedOrTransformedToCancellation() async throws {
        let mock = MockGenerationWorker()
        await mock.setTokenSequence(["A", "B", "C"])
        await mock.setShouldFailDecode(true) // Fails after token 2 with decodeFailed(-1)
        await mock.setDelayPerTokenNanoseconds(0)

        let service = try await makeLoadedService(worker: mock)
        let stream = await service.generate(prompt: "ErrorTest")

        do {
            for try await _ in stream { }
            XCTFail("Stream must throw decodeFailed")
        } catch let err as InferenceError {
            if case .decodeFailed(let code, _) = err {
                XCTAssertEqual(code, -1, "Original decode failure code must be preserved")
            } else {
                XCTFail("Expected .decodeFailed, got: \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await service.state
        if case .failed = state {
            // Correct: genuine error puts service in .failed
        } else {
            XCTFail("Service state must be .failed after decode error, got: \(state)")
        }
    }
}
