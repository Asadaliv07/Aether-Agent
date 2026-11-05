import XCTest
@testable import Aether

/// Mock worker for deterministic ChatViewModel unit tests.
private actor MockChatWorker: InferenceWorkerProtocol {
    private var isLoaded: Bool = false
    private var tokenSequence: [String] = ["Hello", " world", "!"]
    private var delayPerToken: UInt64 = 0
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var isGated: Bool = false

    func setTokens(_ tokens: [String]) {
        self.tokenSequence = tokens
    }

    func setDelayPerToken(nanoseconds: UInt64) {
        self.delayPerToken = nanoseconds
    }

    func setGated(_ gated: Bool) {
        self.isGated = gated
    }

    func openGate() {
        gateContinuation?.resume()
        gateContinuation = nil
        isGated = false
    }

    func initializeBackend() async throws {}

    func loadModel(at path: String, configuration: ModelConfiguration) async throws -> ModelInfo {
        self.isLoaded = true
        return ModelInfo(
            path: path,
            name: "Mock-Model-7B",
            sizeInBytes: 1024 * 1024 * 100,
            description: "Mock Model"
        )
    }

    func unloadModel() async throws {
        self.isLoaded = false
    }

    func shutdown() async {
        self.isLoaded = false
    }

    func isModelLoaded() async -> Bool {
        return self.isLoaded
    }

    private var customChatTemplate: String? = nil
    private var lastConfiguration: GenerationConfiguration? = nil

    func setCustomChatTemplate(_ template: String?) {
        self.customChatTemplate = template
    }

    func getLastConfiguration() -> GenerationConfiguration? {
        return self.lastConfiguration
    }

    func getModelChatTemplate() async -> String? {
        return self.customChatTemplate
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
        self.lastConfiguration = configuration
        if isGated {
            while isGated && !cancellationSignal.isCancelled && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        for token in tokenSequence {
            if cancellationSignal.isCancelled || Task.isCancelled {
                throw InferenceError.cancelled
            }
            if delayPerToken > 0 {
                try? await Task.sleep(nanoseconds: delayPerToken)
            }
            if cancellationSignal.isCancelled || Task.isCancelled {
                throw InferenceError.cancelled
            }
            onToken(token)
        }
    }
}

@MainActor
final class ChatViewModelTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var database: ConversationDatabase!
    private var worker: MockChatWorker!
    private var inferenceService: InferenceService!
    private var viewModel: ChatViewModel!
    private var mockModelPath: String!

    override func setUp() async throws {
        try await super.setUp()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDirectoryURL = tempDir

        let dbURL = tempDir.appendingPathComponent("chat_test.sqlite")
        self.database = try ConversationDatabase(fileURL: dbURL)

        let modelFile = tempDir.appendingPathComponent("mock.gguf")
        FileManager.default.createFile(atPath: modelFile.path, contents: Data("test".utf8))
        self.mockModelPath = modelFile.path

        self.worker = MockChatWorker()
        self.inferenceService = InferenceService(worker: worker)
        self.viewModel = ChatViewModel(inferenceService: inferenceService, database: database)
    }

    override func tearDown() async throws {
        await database?.close()
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - Lifecycle & Initialization

    func testViewModelInitializationCreatesInitialConversation() async throws {
        await viewModel.initialize()

        XCTAssertFalse(viewModel.conversations.isEmpty)
        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.conversations.first?.title, "New Chat")
        XCTAssertEqual(viewModel.selectedConversationId, viewModel.conversations.first?.id)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testConversationSwitchingUpdatesLoadedMessages() async throws {
        await viewModel.initialize()

        // Create two conversations with distinct messages in DB
        let convA = try await database.createConversation(title: "Conv A")
        let convB = try await database.createConversation(title: "Conv B")

        let msgA = MessageRecord(conversationId: convA.id, role: .user, content: "Msg for A", status: .completed)
        let msgB = MessageRecord(conversationId: convB.id, role: .user, content: "Msg for B", status: .completed)

        try await database.insertMessage(msgA)
        try await database.insertMessage(msgB)

        await viewModel.refreshConversations()

        // Select Conv A
        await viewModel.selectConversation(id: convA.id)
        XCTAssertEqual(viewModel.selectedConversationId, convA.id)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.content, "Msg for A")

        // Switch to Conv B
        await viewModel.selectConversation(id: convB.id)
        XCTAssertEqual(viewModel.selectedConversationId, convB.id)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.content, "Msg for B")
    }

    // MARK: - Sending & Streaming

    func testSendMessagePersistsUserAndStreamsAssistantToCompletion() async throws {
        await viewModel.initialize()

        // Simulate loaded model state
        await worker.setTokens(["Hello", " from", " Aether", "!"])
        await viewModel.loadModel(path: mockModelPath)

        guard let convId = viewModel.selectedConversationId else {
            XCTFail("Selected conversation expected")
            return
        }

        viewModel.composerText = "Test greeting prompt"
        await viewModel.sendMessage()

        // Verify composer was cleared
        XCTAssertTrue(viewModel.composerText.isEmpty)
        XCTAssertFalse(viewModel.isGenerating)

        // Verify in-memory messages
        XCTAssertEqual(viewModel.messages.count, 2)
        let userMsg = viewModel.messages[0]
        let assistantMsg = viewModel.messages[1]

        XCTAssertEqual(userMsg.role, .user)
        XCTAssertEqual(userMsg.content, "Test greeting prompt")
        XCTAssertEqual(userMsg.status, .completed)

        XCTAssertEqual(assistantMsg.role, .assistant)
        XCTAssertEqual(assistantMsg.content, "Hello from Aether!")
        XCTAssertEqual(assistantMsg.status, .completed)
        XCTAssertEqual(assistantMsg.tokenCount, 4)

        // Verify persistent SQLite database records
        let records = try await database.fetchMessages(for: convId)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].content, "Test greeting prompt")
        XCTAssertEqual(records[0].status, .completed)
        XCTAssertEqual(records[1].content, "Hello from Aether!")
        XCTAssertEqual(records[1].status, .completed)
        XCTAssertEqual(records[1].tokenCount, 4)
    }

    // MARK: - Cancellation & Interruption

    func testCancelGenerationSettlesAsInterrupted() async throws {
        await viewModel.initialize()
        await worker.setGated(true)
        await worker.setTokens(["Chunk1", "Chunk2"])
        await viewModel.loadModel(path: mockModelPath)

        guard let convId = viewModel.selectedConversationId else {
            XCTFail("Selected conversation expected")
            return
        }

        viewModel.composerText = "Cancel test"

        let sendTask = Task {
            await viewModel.sendMessage()
        }

        // Wait a brief moment for the generation to launch and become active
        try await Task.sleep(nanoseconds: 30_000_000) // 30ms

        XCTAssertTrue(viewModel.isGenerating)
        XCTAssertEqual(viewModel.activeGenerationConversationId, convId)

        // Cancel while gated
        await viewModel.cancelGeneration()
        _ = await sendTask.value

        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.activeGenerationConversationId)

        // Verify assistant message status is settled as .interrupted
        if let assistantMsg = viewModel.messages.last(where: { $0.isAssistant }) {
            XCTAssertEqual(assistantMsg.status, .interrupted)
        } else {
            XCTFail("Expected assistant message")
        }

        // Verify database also records .interrupted
        let records = try await database.fetchMessages(for: convId)
        if let assistantRecord = records.last(where: { $0.role == .assistant }) {
            XCTAssertEqual(assistantRecord.status, .interrupted)
        } else {
            XCTFail("Expected assistant message record")
        }
    }

    // MARK: - Concurrency & Duplicate Send Prevention

    func testConcurrentSendMessageIsSafelyRejected() async throws {
        await viewModel.initialize()
        await worker.setGated(true)
        await viewModel.loadModel(path: mockModelPath)

        viewModel.composerText = "First prompt"
        let task1 = Task {
            await viewModel.sendMessage()
        }

        try await Task.sleep(nanoseconds: 30_000_000) // 30ms
        XCTAssertTrue(viewModel.isGenerating)

        // Attempting to send while generating should be ignored
        viewModel.composerText = "Second prompt during generation"
        await viewModel.sendMessage()

        // Composer text should NOT be cleared because send was rejected
        XCTAssertEqual(viewModel.composerText, "Second prompt during generation")

        // Cancel task 1
        await viewModel.cancelGeneration()
        _ = await task1.value

        XCTAssertFalse(viewModel.isGenerating)
    }

    // MARK: - Isolation During Conversation Switch

    func testConversationSwitchDuringGenerationDoesNotClobberOtherConversation() async throws {
        await viewModel.initialize()
        await worker.setDelayPerToken(nanoseconds: 20_000_000) // 20ms per token
        await worker.setTokens(["Token1", " Token2", " Token3"])
        await viewModel.loadModel(path: mockModelPath)

        let conv1Id = viewModel.selectedConversationId!

        // Create a second conversation
        let conv2 = try await database.createConversation(title: "Second Conversation")
        let msg2 = MessageRecord(conversationId: conv2.id, role: .user, content: "Existing Conv2 Msg", status: .completed)
        try await database.insertMessage(msg2)
        await viewModel.refreshConversations()

        // Start generating in Conv 1
        viewModel.composerText = "Prompt in Conv 1"
        let genTask = Task {
            await viewModel.sendMessage()
        }

        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Switch to Conv 2 while Conv 1 is generating
        await viewModel.selectConversation(id: conv2.id)
        XCTAssertEqual(viewModel.selectedConversationId, conv2.id)

        // Conv 2 messages should only contain Conv 2 messages
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.content, "Existing Conv2 Msg")

        // Wait for Conv 1 generation to complete
        _ = await genTask.value

        // Conv 2 UI must still NOT be polluted by Conv 1 output
        XCTAssertEqual(viewModel.selectedConversationId, conv2.id)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.content, "Existing Conv2 Msg")

        // Verify Conv 1 received its completed messages in SQLite
        let conv1Records = try await database.fetchMessages(for: conv1Id)
        XCTAssertEqual(conv1Records.count, 2)
        XCTAssertEqual(conv1Records[1].content, "Token1 Token2 Token3")
        XCTAssertEqual(conv1Records[1].status, .completed)
    }

    // MARK: - Batching & Resilience Tests (Phase 3.5.1 Validation)

    func test16TokenIncrementalBatchingPersistence() async throws {
        await viewModel.initialize()

        // Generate 35 tokens (triggers 16-token flush at 16, 32, and final completion at 35)
        let tokenArray = (1...35).map { " tok\($0)" }
        await worker.setTokens(tokenArray)
        await viewModel.loadModel(path: mockModelPath)

        guard let convId = viewModel.selectedConversationId else {
            XCTFail("Selected conversation expected")
            return
        }

        viewModel.composerText = "Run 35 tokens"
        await viewModel.sendMessage()

        XCTAssertFalse(viewModel.isGenerating)
        let records = try await database.fetchMessages(for: convId)
        XCTAssertEqual(records.count, 2)

        let assistantRecord = records[1]
        XCTAssertEqual(assistantRecord.role, .assistant)
        XCTAssertEqual(assistantRecord.status, .completed)
        XCTAssertEqual(assistantRecord.tokenCount, 35)
        XCTAssertEqual(assistantRecord.content, tokenArray.joined())
    }

    func testPartialResponsePreservedOnCancellation() async throws {
        await viewModel.initialize()
        await worker.setDelayPerToken(nanoseconds: 10_000_000) // 10ms per token
        let tokens = (1...20).map { "word\($0) " }
        await worker.setTokens(tokens)
        await viewModel.loadModel(path: mockModelPath)

        guard let convId = viewModel.selectedConversationId else {
            XCTFail("Selected conversation expected")
            return
        }

        viewModel.composerText = "Cancel midway"
        let genTask = Task {
            await viewModel.sendMessage()
        }

        // Sleep to let several tokens emit (e.g. 50ms = ~5 tokens)
        try await Task.sleep(nanoseconds: 50_000_000)

        await viewModel.cancelGeneration()
        _ = await genTask.value

        XCTAssertFalse(viewModel.isGenerating)
        let records = try await database.fetchMessages(for: convId)
        XCTAssertEqual(records.count, 2)

        let assistantRecord = records[1]
        XCTAssertEqual(assistantRecord.role, .assistant)
        XCTAssertEqual(assistantRecord.status, .interrupted)
        // Verify partial response is NOT empty and was preserved
        XCTAssertFalse(assistantRecord.content.isEmpty, "Partial assistant tokens must be preserved in SQLite")
    }

    func testRapidRepeatedCancelCallsAreSafe() async throws {
        await viewModel.initialize()
        await worker.setGated(true)
        await viewModel.loadModel(path: mockModelPath)

        viewModel.composerText = "Rapid cancel test"
        let genTask = Task {
            await viewModel.sendMessage()
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(viewModel.isGenerating)

        // Dispatch 10 concurrent cancellation requests
        var cancelTasks: [Task<Void, Never>] = []
        for _ in 0..<10 {
            cancelTasks.append(Task { @MainActor in
                await self.viewModel.cancelGeneration()
            })
        }
        for task in cancelTasks {
            await task.value
        }

        _ = await genTask.value
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertNil(viewModel.activeGenerationConversationId)
    }

    func testModelUnloadWhileGeneratingIsSafelyGuarded() async throws {
        await viewModel.initialize()
        await worker.setGated(true)
        await viewModel.loadModel(path: mockModelPath)

        viewModel.composerText = "Unload while generating"
        let genTask = Task {
            await viewModel.sendMessage()
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(viewModel.isGenerating)

        // Attempt to unload model while generating (safely rejected by InferenceService)
        await viewModel.unloadModel()
        XCTAssertNotNil(viewModel.errorMessage)

        // Cancel generation so gated worker exits cleanly
        await viewModel.cancelGeneration()
        _ = await genTask.value
        XCTAssertFalse(viewModel.isGenerating)
    }

    // MARK: - Phase 3.7 Multi-Turn Context & Generation Settings Tests

    func testMultiTurnHistoryAssembledInSubsequentGeneration() async throws {
        await viewModel.initialize()
        await viewModel.loadModel(path: mockModelPath)

        // Turn 1
        viewModel.composerText = "Hello from user 1"
        await viewModel.sendMessage()

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Hello from user 1")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].status, .completed)

        // Turn 2
        viewModel.composerText = "Follow-up question 2"
        await viewModel.sendMessage()

        XCTAssertEqual(viewModel.messages.count, 4)
        XCTAssertEqual(viewModel.messages[2].role, .user)
        XCTAssertEqual(viewModel.messages[2].content, "Follow-up question 2")
        XCTAssertEqual(viewModel.messages[3].role, .assistant)
        XCTAssertEqual(viewModel.messages[3].status, .completed)

        // Verify metrics were computed
        XCTAssertNotNil(viewModel.lastGenerationDurationSeconds)
        XCTAssertNotNil(viewModel.lastTokensPerSecond)
    }

    func testConversationSettingsLoadedAndIsolated() async throws {
        await viewModel.initialize()

        guard let firstConvId = viewModel.selectedConversationId else {
            XCTFail("Must have initial conversation")
            return
        }

        // Set settings on conversation 1
        await viewModel.updateCurrentConversationSettings(
            systemPrompt: "System prompt for conv 1",
            temperature: 0.35,
            maxTokens: 512
        )

        XCTAssertEqual(viewModel.currentSystemPrompt, "System prompt for conv 1")
        XCTAssertEqual(viewModel.currentTemperature, 0.35)
        XCTAssertEqual(viewModel.currentMaxTokens, 512)

        // Create conversation 2
        await viewModel.createNewConversation(title: "Second Chat")
        guard let secondConvId = viewModel.selectedConversationId, secondConvId != firstConvId else {
            XCTFail("Must have selected second conversation")
            return
        }

        // New conversation should have defaults
        XCTAssertEqual(viewModel.currentSystemPrompt, "")
        XCTAssertEqual(viewModel.currentTemperature, 0.7)
        XCTAssertEqual(viewModel.currentMaxTokens, 2048)

        // Switch back to conversation 1
        await viewModel.selectConversation(id: firstConvId)
        XCTAssertEqual(viewModel.currentSystemPrompt, "System prompt for conv 1")
        XCTAssertEqual(viewModel.currentTemperature, 0.35)
        XCTAssertEqual(viewModel.currentMaxTokens, 512)
    }

    func testStopSequencesLoadedAndIsolatedBetweenConversations() async throws {
        await viewModel.initialize()

        guard let firstConvId = viewModel.selectedConversationId else {
            XCTFail("Must have initial conversation")
            return
        }

        // Set stop sequences on conversation 1
        let stops1 = ["###", "</s>"]
        await viewModel.updateCurrentConversationSettings(
            systemPrompt: "Conv 1 prompt",
            temperature: 0.5,
            maxTokens: 100,
            stopSequences: stops1
        )

        XCTAssertEqual(viewModel.currentStopSequences, stops1)

        // Create conversation 2
        await viewModel.createNewConversation(title: "Second Chat")
        guard let secondConvId = viewModel.selectedConversationId, secondConvId != firstConvId else {
            XCTFail("Must have selected second conversation")
            return
        }

        // Conversation 2 should have empty stop sequences
        XCTAssertEqual(viewModel.currentStopSequences, [])

        // Switch back to conversation 1
        await viewModel.selectConversation(id: firstConvId)
        XCTAssertEqual(viewModel.currentStopSequences, stops1)
    }

    func testStopSequencesPassedToInferenceConfiguration() async throws {
        await viewModel.initialize()

        // Load mock model
        try await inferenceService.loadModel(at: mockModelPath, configuration: ModelConfiguration())

        // Set stop sequences
        let configuredStops = ["<|im_end|>", "\nUser:"]
        await viewModel.updateCurrentConversationSettings(
            systemPrompt: "Test System",
            temperature: 0.1,
            maxTokens: 50,
            stopSequences: configuredStops
        )

        // Send a message
        viewModel.composerText = "Hello model"
        await viewModel.sendMessage()

        // Verify the configuration passed to worker contains configured stop sequences
        let lastConfig = await worker.getLastConfiguration()
        XCTAssertNotNil(lastConfig)
        XCTAssertEqual(lastConfig?.stopSequences, configuredStops)
    }

    // MARK: - Phase 3.8 Search State & Navigation Tests

    func testSearchQueryDebouncingAndResultPopulation() async throws {
        await viewModel.initialize()

        // Insert messages into database
        let conv = try await database.createConversation(title: "Searchable Chat")
        let msg = MessageRecord(
            conversationId: conv.id,
            role: .assistant,
            content: "Metal shaders accelerate local tensor matrix operations on Apple Silicon.",
            status: .completed
        )
        try await database.insertMessage(msg)

        // Set search query
        viewModel.searchQuery = "accelerate tensor"

        // Initially immediately after setting, debounce is active
        XCTAssertTrue(viewModel.isSearching)

        // Wait for 150ms debounce + database fetch
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first?.id, msg.id)
        XCTAssertEqual(viewModel.searchResults.first?.conversationTitle, "Searchable Chat")
        XCTAssertTrue(viewModel.searchResults.first?.snippet.contains("[[MARK]]") == true)
    }

    func testClearSearchResetsQueryAndResults() async throws {
        await viewModel.initialize()

        let conv = try await database.createConversation(title: "Clear Test")
        let msg = MessageRecord(conversationId: conv.id, role: .user, content: "Ephemeral search term", status: .completed)
        try await database.insertMessage(msg)

        viewModel.searchQuery = "Ephemeral"
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(viewModel.searchResults.count, 1)

        // Clear search
        viewModel.clearSearch()

        XCTAssertTrue(viewModel.searchQuery.isEmpty)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testSelectSearchResultNavigatesToConversationAndSetsScrollTarget() async throws {
        await viewModel.initialize()

        let convA = try await database.createConversation(title: "Chat Alpha")
        let convB = try await database.createConversation(title: "Chat Beta")

        let msgA = MessageRecord(conversationId: convA.id, role: .user, content: "Alpha message", status: .completed)
        let msgB = MessageRecord(conversationId: convB.id, role: .assistant, content: "Unique target Beta message finding", status: .completed)

        try await database.insertMessage(msgA)
        try await database.insertMessage(msgB)

        await viewModel.refreshConversations()
        await viewModel.selectConversation(id: convA.id)
        XCTAssertEqual(viewModel.selectedConversationId, convA.id)

        // Search for Beta message
        let searchHits = try await database.searchMessages(query: "Unique target Beta")
        XCTAssertEqual(searchHits.count, 1)
        guard let targetHit = searchHits.first else {
            XCTFail("Search hit expected")
            return
        }

        // Select the search hit
        await viewModel.selectSearchResult(targetHit)

        // Verify view model switched to conversation B and loaded messages
        XCTAssertEqual(viewModel.selectedConversationId, convB.id)
        XCTAssertEqual(viewModel.targetScrollMessageId, msgB.id)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.id, msgB.id)
    }

    func testDeleteConversationRemovesStaleSearchResults() async throws {
        await viewModel.initialize()

        let conv1 = try await database.createConversation(title: "Chat One")
        let conv2 = try await database.createConversation(title: "Chat Two")

        let msg1 = MessageRecord(conversationId: conv1.id, role: .user, content: "Common keyword alpha in conv 1", status: .completed)
        let msg2 = MessageRecord(conversationId: conv2.id, role: .user, content: "Common keyword alpha in conv 2", status: .completed)

        try await database.insertMessage(msg1)
        try await database.insertMessage(msg2)
        await viewModel.refreshConversations()

        viewModel.searchQuery = "Common keyword"
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(viewModel.searchResults.count, 2)

        // Delete conversation 1
        await viewModel.deleteConversation(id: conv1.id)

        // Search results should now only contain results from conversation 2
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first?.conversationId, conv2.id)
    }

    func testRapidSearchTypingCancelsStaleQueries() async throws {
        await viewModel.initialize()

        let conv = try await database.createConversation(title: "Rapid Typing Chat")
        let msg1 = MessageRecord(conversationId: conv.id, role: .user, content: "First intermediate token", status: .completed)
        let msg2 = MessageRecord(conversationId: conv.id, role: .assistant, content: "Final destination term reached", status: .completed)

        try await database.insertMessage(msg1)
        try await database.insertMessage(msg2)

        // Simulate rapid keystrokes without waiting for debounce
        viewModel.searchQuery = "First"
        viewModel.searchQuery = "First inter"
        viewModel.searchQuery = "Final destination"

        // Wait for the final query to settle
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first?.id, msg2.id)
        XCTAssertEqual(viewModel.searchResults.first?.conversationTitle, "Rapid Typing Chat")
    }

    // MARK: - DEF-38-03 Regression Tests

    func testClearSearchResetsTargetScrollMessageId() async throws {
        await viewModel.initialize()

        let conv = try await database.createConversation(title: "Target Search Chat")
        let msg = MessageRecord(conversationId: conv.id, role: .assistant, content: "Scrollable message content", status: .completed)
        try await database.insertMessage(msg)
        await viewModel.refreshConversations()

        let hits = try await database.searchMessages(query: "Scrollable message")
        guard let hit = hits.first else {
            XCTFail("Expected search hit")
            return
        }

        // Select the hit -> scroll target must be set
        await viewModel.selectSearchResult(hit)
        XCTAssertEqual(viewModel.targetScrollMessageId, msg.id)

        // Clear search explicitly
        viewModel.clearSearch()
        XCTAssertNil(viewModel.targetScrollMessageId)
        XCTAssertTrue(viewModel.searchQuery.isEmpty)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testEmptySearchQueryResetsTargetScrollMessageId() async throws {
        await viewModel.initialize()

        let conv = try await database.createConversation(title: "Target Search Chat")
        let msg = MessageRecord(conversationId: conv.id, role: .assistant, content: "Scrollable message content", status: .completed)
        try await database.insertMessage(msg)
        await viewModel.refreshConversations()

        let hits = try await database.searchMessages(query: "Scrollable message")
        guard let hit = hits.first else {
            XCTFail("Expected search hit")
            return
        }

        await viewModel.selectSearchResult(hit)
        XCTAssertEqual(viewModel.targetScrollMessageId, msg.id)

        // Setting query to empty triggers scheduleSearch with empty query -> resets scroll target
        viewModel.searchQuery = ""
        XCTAssertNil(viewModel.targetScrollMessageId)
    }

    func testSwitchingConversationsResetsTargetScrollMessageId() async throws {
        await viewModel.initialize()

        let convA = try await database.createConversation(title: "Chat Alpha")
        let convB = try await database.createConversation(title: "Chat Beta")
        let msgA = MessageRecord(conversationId: convA.id, role: .user, content: "Alpha target message", status: .completed)
        try await database.insertMessage(msgA)
        await viewModel.refreshConversations()

        let hits = try await database.searchMessages(query: "Alpha target")
        guard let hit = hits.first else {
            XCTFail("Expected search hit")
            return
        }

        await viewModel.selectSearchResult(hit)
        XCTAssertEqual(viewModel.targetScrollMessageId, msgA.id)
        XCTAssertEqual(viewModel.selectedConversationId, convA.id)

        // Switch to conversation B
        await viewModel.selectConversation(id: convB.id)
        XCTAssertEqual(viewModel.selectedConversationId, convB.id)
        XCTAssertNil(viewModel.targetScrollMessageId, "Switching conversations must reset targetScrollMessageId")

        // Re-arm scroll target
        await viewModel.selectSearchResult(hit)
        XCTAssertEqual(viewModel.targetScrollMessageId, msgA.id)

        // Creating a new conversation also resets scroll target
        await viewModel.createNewConversation()
        XCTAssertNil(viewModel.targetScrollMessageId, "Creating a new conversation must reset targetScrollMessageId")
    }

    func testRepeatedSelectionOfSameSearchResultRetriggersScrollTarget() async throws {
        await viewModel.initialize()

        let conv = try await database.createConversation(title: "Repeat Selection Chat")
        let msg = MessageRecord(conversationId: conv.id, role: .assistant, content: "Repeat scroll target message", status: .completed)
        try await database.insertMessage(msg)
        await viewModel.refreshConversations()

        let hits = try await database.searchMessages(query: "Repeat scroll")
        guard let hit = hits.first else {
            XCTFail("Expected search hit")
            return
        }

        // First selection
        await viewModel.selectSearchResult(hit)
        XCTAssertEqual(viewModel.targetScrollMessageId, msg.id)

        // Repeated selection of the exact same result:
        // Internally, selectSearchResult yields through nil to trigger SwiftUI .onChange,
        // and finishes with targetScrollMessageId set to msg.id
        await viewModel.selectSearchResult(hit)
        XCTAssertEqual(viewModel.targetScrollMessageId, msg.id)
    }

    // MARK: - Remote Catalog Metadata Enrichment Tests

    private struct MockCatalogService: HuggingFaceCatalogServiceProtocol {
        var modelsToReturn: [HuggingFaceModel] = []
        var sizesToReturn: [String: Int64] = [:]
        var errorToThrow: Error? = nil

        func searchModels(query: String?, architecture: String?, sort: HuggingFaceSortOrder, limit: Int) async throws -> [HuggingFaceModel] {
            if let errorToThrow { throw errorToThrow }
            return modelsToReturn
        }

        func fetchModelDetails(repoId: String) async throws -> HuggingFaceModel {
            if let errorToThrow { throw errorToThrow }
            guard let first = modelsToReturn.first(where: { $0.id == repoId }) else {
                throw HuggingFaceCatalogError.repoNotFound(repoId: repoId)
            }
            return first
        }

        func fetchRepoFileSizes(repoId: String, revision: String, forceRefresh: Bool) async throws -> [String: Int64] {
            if let errorToThrow { throw errorToThrow }
            return sizesToReturn
        }

        func enrichModelWithAccurateFileSizes(_ model: HuggingFaceModel, forceRefresh: Bool) async throws -> HuggingFaceModel {
            if let errorToThrow { throw errorToThrow }
            let sizes = sizesToReturn
            let updated = model.ggufFiles.map { file in
                if let size = sizes[file.filename] {
                    return file.withUpdatedSize(size, architecture: model.inferredArchitecture)
                }
                return file
            }
            return model.withUpdatedGGUFFiles(updated)
        }
    }

    func testChatViewModelFetchAccurateSizesSuccess() async throws {
        let initialFile = HuggingFaceGGUFFile(
            repoId: "test/model-1",
            filename: "model.q4_k_m.gguf",
            size: 0,
            quantization: "Q4_K_M",
            bitDepth: 4,
            isShard: false,
            downloadURL: URL(string: "https://example.com/model.q4_k_m.gguf")!,
            compatibility: HuggingFaceQuantUtils.evaluateFileCompatibility(architecture: "llama", fileSize: 0)
        )
        let initialModel = HuggingFaceModel(
            id: "test/model-1",
            author: "test",
            name: "model-1",
            downloads: 100,
            likes: 10,
            tags: ["llama"],
            pipelineTag: "text-generation",
            description: nil,
            license: nil,
            isGated: false,
            lastModified: nil,
            siblings: [],
            ggufFiles: [initialFile]
        )

        var mockCatalog = MockCatalogService()
        mockCatalog.modelsToReturn = [initialModel]
        mockCatalog.sizesToReturn = ["model.q4_k_m.gguf": 3_500_000_000]

        let vm = ChatViewModel(
            inferenceService: inferenceService,
            database: database,
            catalogService: mockCatalog
        )

        await vm.searchRemoteCatalog()
        XCTAssertEqual(vm.huggingFaceModels.count, 1)

        await vm.fetchAccurateSizes(for: initialModel)

        XCTAssertFalse(vm.repoMetadataLoading.contains("test/model-1"))
        XCTAssertNil(vm.repoMetadataErrors["test/model-1"])
        XCTAssertEqual(vm.huggingFaceModels[0].ggufFiles[0].size, 3_500_000_000)
        XCTAssertEqual(vm.huggingFaceModels[0].ggufFiles[0].compatibility, .compatible)
    }

    func testChatViewModelFetchAccurateSizesHandlesError() async throws {
        let initialFile = HuggingFaceGGUFFile(
            repoId: "test/model-error",
            filename: "model.q4_k_m.gguf",
            size: 0,
            quantization: "Q4_K_M",
            bitDepth: 4,
            isShard: false,
            downloadURL: URL(string: "https://example.com/model.q4_k_m.gguf")!,
            compatibility: .unknown("Awaiting size")
        )
        let initialModel = HuggingFaceModel(
            id: "test/model-error",
            author: "test",
            name: "model-error",
            downloads: 100,
            likes: 10,
            tags: ["llama"],
            pipelineTag: "text-generation",
            description: nil,
            license: nil,
            isGated: false,
            lastModified: nil,
            siblings: [],
            ggufFiles: [initialFile]
        )

        var mockCatalog = MockCatalogService()
        mockCatalog.modelsToReturn = [initialModel]
        mockCatalog.errorToThrow = HuggingFaceCatalogError.serverError(statusCode: 503)

        let vm = ChatViewModel(
            inferenceService: inferenceService,
            database: database,
            catalogService: mockCatalog
        )

        await vm.fetchAccurateSizes(for: initialModel)

        XCTAssertFalse(vm.repoMetadataLoading.contains("test/model-error"))
        XCTAssertNotNil(vm.repoMetadataErrors["test/model-error"])
        XCTAssertTrue(vm.repoMetadataErrors["test/model-error"]?.contains("503") == true)
    }
}



