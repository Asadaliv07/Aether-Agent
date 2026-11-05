import Foundation
import Observation
import os

/// Segmented tabs for the native Model Library sheet.
public enum ModelLibraryTab: String, CaseIterable, Identifiable, Sendable {
    case installed = "Installed Models"
    case discover = "Discover Hugging Face"

    public var id: String { rawValue }
}

/// Main-actor isolated view model orchestrating the native SwiftUI chat interface.
///
/// Responsibilities:
/// - Coordinates conversation and message persistence via `ConversationDatabase`.
/// - Integrates asynchronous text generation and streaming via `InferenceService`.
/// - Manages UI states, including model readiness, generation streaming, cancellation barriers,
///   and conversation switching isolation.
/// - Preserves Swift 6 strict concurrency with zero native pointer leakage to the UI layer.
@Observable
@MainActor
public final class ChatViewModel {
    // MARK: - State Properties

    public private(set) var conversations: [ConversationRecord] = []
    public var selectedConversationId: UUID?
    public private(set) var messages: [ChatMessage] = []
    public var composerText: String = ""

    public private(set) var isGenerating: Bool = false
    public private(set) var activeGenerationConversationId: UUID?
    public private(set) var inferenceState: InferenceState = .unloaded
    public private(set) var isModelLoading: Bool = false
    public private(set) var loadingModelPath: String?
    public var showModelLibrary: Bool = false
    public private(set) var catalogModels: [ModelRecord] = []
    public var selectedModelId: UUID?
    public private(set) var loadedModelId: UUID?
    public private(set) var errorMessage: String?

    // MARK: - Generation Controls & Metrics
    public var currentSystemPrompt: String = ""
    public var currentTemperature: Float = 0.7
    public var currentMaxTokens: Int32 = 2048
    public var currentStopSequences: [String] = []
    public var showGenerationSettings: Bool = false
    public private(set) var lastTokensPerSecond: Double?
    public private(set) var lastGenerationDurationSeconds: Double?

    // MARK: - Search State & Navigation
    public var searchQuery: String = "" {
        didSet {
            scheduleSearch(query: searchQuery)
        }
    }
    public private(set) var searchResults: [SearchResultRecord] = []
    public private(set) var isSearching: Bool = false
    public var targetScrollMessageId: UUID?

    // MARK: - Remote Catalog & Download State
    public private(set) var huggingFaceModels: [HuggingFaceModel] = []
    public private(set) var isSearchingRemoteCatalog: Bool = false
    public private(set) var remoteCatalogError: String?
    public var remoteSearchQuery: String = ""
    public var selectedRemoteSortOrder: HuggingFaceSortOrder = .downloads
    public var selectedRemoteArchitecture: String?
    public var selectedRemoteCategory: ModelCategory?

    /// Filtered remote models adhering to active category and architecture selections.
    public var displayedRemoteModels: [HuggingFaceModel] {
        guard let category = selectedRemoteCategory else {
            return huggingFaceModels
        }
        return huggingFaceModels.filter { $0.category == category }
    }

    public private(set) var activeDownloads: [UUID: DownloadProgress] = [:]
    public var selectedLibraryTab: ModelLibraryTab = .installed
    public private(set) var repoMetadataLoading: Set<String> = []
    public private(set) var repoMetadataErrors: [String: String] = [:]

    // MARK: - Dependencies & Private Trackers

    public let inferenceService: InferenceService
    public let database: ConversationDatabase
    public let modelLibraryService: ModelLibraryService
    public let catalogService: HuggingFaceCatalogServiceProtocol
    public let downloadManager: ModelDownloadManager

    private var activeStream: InferenceStream?
    private var stateObservationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var remoteCatalogSearchTask: Task<Void, Never>?
    private var downloadPollingTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        inferenceService: InferenceService,
        database: ConversationDatabase,
        modelLibraryService: ModelLibraryService? = nil,
        catalogService: HuggingFaceCatalogServiceProtocol? = nil,
        downloadManager: ModelDownloadManager? = nil
    ) {
        self.inferenceService = inferenceService
        self.database = database
        let libService = modelLibraryService ?? ModelLibraryService(database: database)
        self.modelLibraryService = libService
        self.catalogService = catalogService ?? HuggingFaceCatalogService()
        self.downloadManager = downloadManager ?? ModelDownloadManager(database: database, modelLibraryService: libService)
    }

    /// Bootstraps the view model, synchronizes the database, and listens for inference state transitions.
    public func initialize() async {
        // 1. Recover any unfinished streaming messages from prior sessions
        do {
            _ = try await database.recoverInterruptedGenerations()
        } catch {
            self.errorMessage = "Failed to run recovery migration: \(error.localizedDescription)"
        }

        // 2. Fetch conversations
        await refreshConversations()

        // 3. Fetch model catalog & persisted downloads
        await refreshCatalog()
        await downloadManager.loadPersistedDownloads()
        await refreshDownloads()

        // 4. Select first conversation or create default
        if conversations.isEmpty {
            await createNewConversation(title: "New Chat")
        } else if selectedConversationId == nil {
            if let firstId = conversations.first?.id {
                await selectConversation(id: firstId)
            }
        }

        // 5. Start state observer
        await setupStateObserver()
    }

    private func setupStateObserver() async {
        // Read initial state
        self.inferenceState = await inferenceService.state
        updateModelLoadingFlag(from: self.inferenceState)

        // Observe continuous stream
        stateObservationTask?.cancel()
        stateObservationTask = Task { [weak self, inferenceService] in
            let stream = await inferenceService.stateStream
            for await newState in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.inferenceState = newState
                self.updateModelLoadingFlag(from: newState)
            }
        }
    }

    private func updateModelLoadingFlag(from state: InferenceState) {
        switch state {
        case .loading:
            self.isModelLoading = true
        default:
            self.isModelLoading = false
        }
    }

    // MARK: - Conversation Management

    public func refreshConversations() async {
        do {
            self.conversations = try await database.fetchConversations()
        } catch {
            self.errorMessage = "Failed to load conversations: \(error.localizedDescription)"
        }
    }

    public func createNewConversation(title: String = "New Chat") async {
        do {
            let modelName: String? = {
                if case .loaded(let info) = inferenceState {
                    return info.name
                }
                return nil
            }()

            let record = try await database.createConversation(title: title, modelName: modelName)
            self.conversations.insert(record, at: 0)
            self.selectedConversationId = record.id
            self.targetScrollMessageId = nil
            self.messages = []
            self.composerText = ""
            self.currentSystemPrompt = ""
            self.currentTemperature = 0.7
            self.currentMaxTokens = 2048
            self.currentStopSequences = []
        } catch {
            self.errorMessage = "Failed to create conversation: \(error.localizedDescription)"
        }
    }

    public func selectConversation(id: UUID) async {
        guard selectedConversationId != id else { return }
        self.selectedConversationId = id
        self.targetScrollMessageId = nil
        if let conv = conversations.first(where: { $0.id == id }) {
            self.currentSystemPrompt = conv.systemPrompt ?? ""
            self.currentTemperature = conv.temperature ?? 0.7
            self.currentMaxTokens = conv.maxTokens ?? 2048
            self.currentStopSequences = conv.stopSequences ?? []
        }
        await loadMessages(for: id)
    }

    public func updateCurrentConversationSettings(
        systemPrompt: String?,
        temperature: Float?,
        maxTokens: Int32?,
        stopSequences: [String]? = nil
    ) async {
        guard let id = selectedConversationId else { return }
        do {
            try await database.updateConversationSettings(
                id: id,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: maxTokens,
                stopSequences: stopSequences
            )
            if let idx = conversations.firstIndex(where: { $0.id == id }) {
                conversations[idx].systemPrompt = systemPrompt
                conversations[idx].temperature = temperature
                conversations[idx].maxTokens = maxTokens
                conversations[idx].stopSequences = stopSequences
            }
            self.currentSystemPrompt = systemPrompt ?? ""
            self.currentTemperature = temperature ?? 0.7
            self.currentMaxTokens = maxTokens ?? 2048
            self.currentStopSequences = stopSequences ?? []
        } catch {
            self.errorMessage = "Failed to update settings: \(error.localizedDescription)"
        }
    }

    public func deleteConversation(id: UUID) async {
        // If the deleted conversation is currently generating, cancel it first
        if activeGenerationConversationId == id {
            await cancelGeneration()
        }

        do {
            try await database.deleteConversation(id: id)
            self.conversations.removeAll { $0.id == id }
            self.searchResults.removeAll { $0.conversationId == id }

            if selectedConversationId == id {
                self.targetScrollMessageId = nil
                if let next = conversations.first {
                    await selectConversation(id: next.id)
                } else {
                    self.selectedConversationId = nil
                    self.messages = []
                    await createNewConversation()
                }
            } else if targetScrollMessageId != nil {
                if !messages.contains(where: { $0.id == targetScrollMessageId }) {
                    self.targetScrollMessageId = nil
                }
            }
        } catch {
            self.errorMessage = "Failed to delete conversation: \(error.localizedDescription)"
        }
    }

    // MARK: - Search Operations

    /// Schedules an asynchronous debounced search query.
    public func scheduleSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.searchResults = []
            self.isSearching = false
            self.targetScrollMessageId = nil
            return
        }

        self.isSearching = true
        searchTask = Task { [weak self, database] in
            // Cancellation-safe debounce (150ms)
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            do {
                let results = try await database.searchMessages(query: trimmed, limit: 50)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    self.searchResults = results
                    self.isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.searchResults = []
                self.isSearching = false
            }
        }
    }

    /// Clears the active search query and associated results.
    public func clearSearch() {
        searchTask?.cancel()
        self.searchQuery = ""
        self.searchResults = []
        self.isSearching = false
        self.targetScrollMessageId = nil
    }

    /// Selects a search result, navigates to the parent conversation, and sets the target scroll message.
    public func selectSearchResult(_ result: SearchResultRecord) async {
        if selectedConversationId != result.conversationId {
            await selectConversation(id: result.conversationId)
            // Allow SwiftUI layout cycle to populate message bubbles before scrolling
            try? await Task.sleep(nanoseconds: 50_000_000)
        } else if self.targetScrollMessageId == result.id {
            // Re-selection of the same active result: reset briefly to nil and yield so the
            // state transition fires SwiftUI's .onChange(of: targetScrollMessageId) handler.
            self.targetScrollMessageId = nil
            await Task.yield()
        }
        self.targetScrollMessageId = result.id
    }

    private func loadMessages(for conversationId: UUID) async {
        do {
            let records = try await database.fetchMessages(for: conversationId)
            // Stale check: Ensure user hasn't selected another conversation while fetching
            guard self.selectedConversationId == conversationId else { return }
            self.messages = records.map { ChatMessage(record: $0) }
        } catch {
            self.errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }
    }

    // MARK: - Generation & Streaming

    public func sendMessage() async {
        guard !isGenerating else { return }

        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Ensure active conversation exists
        let conversationId: UUID
        if let current = selectedConversationId {
            conversationId = current
        } else {
            await createNewConversation()
            guard let created = selectedConversationId else { return }
            conversationId = created
        }

        // Verify model readiness
        guard case .loaded = inferenceState else {
            self.errorMessage = "Please load a local model before generating responses."
            return
        }

        // Clear composer immediately
        self.composerText = ""
        self.errorMessage = nil

        // Auto-title conversation if this is the first message and title is "New Chat"
        if let conv = conversations.first(where: { $0.id == conversationId }),
           conv.title == "New Chat" {
            let generatedTitle = String(trimmed.prefix(32))
            try? await database.updateConversationTitle(id: conversationId, title: generatedTitle)
            await refreshConversations()
        }

        // 1. Create and persist User Message
        let userMessage = ChatMessage(
            conversationId: conversationId,
            role: .user,
            content: trimmed,
            status: .completed
        )
        self.messages.append(userMessage)

        do {
            try await database.insertMessage(userMessage.toRecord())
        } catch {
            self.errorMessage = "Failed to persist user message: \(error.localizedDescription)"
            return
        }

        // 2. Create and persist Assistant placeholder with status: .streaming
        let assistantMessageId = UUID()
        let assistantMessage = ChatMessage(
            id: assistantMessageId,
            conversationId: conversationId,
            role: .assistant,
            content: "",
            status: .streaming
        )
        self.messages.append(assistantMessage)

        do {
            try await database.insertMessage(assistantMessage.toRecord())
        } catch {
            self.errorMessage = "Failed to record assistant stream: \(error.localizedDescription)"
            return
        }

        // 3. Assemble multi-turn conversation context
        var promptMessages: [PromptMessage] = []
        let currentConv = conversations.first(where: { $0.id == conversationId })
        if let sysPrompt = currentConv?.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sysPrompt.isEmpty {
            promptMessages.append(PromptMessage(role: .system, content: sysPrompt))
        }

        // Fetch prior messages from database to guarantee persistence consistency
        do {
            let priorRecords = try await database.fetchMessages(for: conversationId)
            for record in priorRecords {
                if record.id == assistantMessageId { continue }
                if record.role == .assistant {
                    guard record.status == .completed,
                          !record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    promptMessages.append(PromptMessage(role: .assistant, content: record.content))
                } else if record.role == .user {
                    promptMessages.append(PromptMessage(role: .user, content: record.content))
                } else if record.role == .system {
                    promptMessages.append(PromptMessage(role: .system, content: record.content))
                }
            }
        } catch {
            for msg in self.messages {
                if msg.id == assistantMessageId { continue }
                if msg.role == .assistant {
                    guard msg.status == .completed,
                          !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    promptMessages.append(PromptMessage(role: .assistant, content: msg.content))
                } else if msg.role == .user {
                    promptMessages.append(PromptMessage(role: .user, content: msg.content))
                }
            }
        }

        // Ensure at least the current user turn is present
        if promptMessages.isEmpty || promptMessages.last?.role != MessageRole.user.rawValue {
            promptMessages.append(PromptMessage(role: .user, content: trimmed))
        }

        // 4. Configure generation parameters
        var config = GenerationConfiguration.default
        if let temp = currentConv?.temperature {
            config.temperature = temp
        }
        if let maxTok = currentConv?.maxTokens {
            config.maxTokens = maxTok
        }
        if let stops = currentConv?.stopSequences {
            config.stopSequences = stops
        }

        // 5. Initiate inference stream
        self.isGenerating = true
        self.activeGenerationConversationId = conversationId

        let stream: InferenceStream
        let startTime = ContinuousClock.now
        do {
            stream = try await inferenceService.generate(messages: promptMessages, configuration: config)
            self.activeStream = stream
        } catch {
            self.isGenerating = false
            self.activeGenerationConversationId = nil
            self.activeStream = nil
            self.markAssistantMessageFailed(id: assistantMessageId, errorDescription: error.localizedDescription)
            try? await database.updateMessageContentAndStatus(
                id: assistantMessageId,
                content: "Generation error: \(error.localizedDescription)",
                status: .failed,
                tokenCount: 0
            )
            return
        }

        // 6. Stream consumption loop with incremental persistence
        var accumulatedText = ""
        var tokenCount = 0
        var tokensSinceLastSave = 0
        let persistenceBatchSize = 16

        do {
            for try await tokenPiece in stream {
                accumulatedText.append(tokenPiece)
                tokenCount += 1
                tokensSinceLastSave += 1

                // Update UI in-place if current conversation is still selected
                if self.selectedConversationId == conversationId {
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                        self.messages[index].content = accumulatedText
                        self.messages[index].tokenCount = tokenCount
                    }
                }

                // Batch persist periodically to prevent SQLite write thrashing
                if tokensSinceLastSave >= persistenceBatchSize {
                    tokensSinceLastSave = 0
                    try? await database.updateMessageContentAndStatus(
                        id: assistantMessageId,
                        content: accumulatedText,
                        status: .streaming,
                        tokenCount: tokenCount
                    )
                }
            }

            // Completed normally
            let duration = startTime.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            self.lastGenerationDurationSeconds = seconds
            self.lastTokensPerSecond = seconds > 0 ? Double(tokenCount) / seconds : nil

            try await database.updateMessageContentAndStatus(
                id: assistantMessageId,
                content: accumulatedText,
                status: .completed,
                tokenCount: tokenCount
            )

            if self.selectedConversationId == conversationId {
                if let index = self.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    self.messages[index].content = accumulatedText
                    self.messages[index].status = .completed
                    self.messages[index].tokenCount = tokenCount
                }
            }
        } catch is CancellationError {
            // Settled as interrupted
            await handleInterruptedGeneration(
                messageId: assistantMessageId,
                conversationId: conversationId,
                accumulatedText: accumulatedText,
                tokenCount: tokenCount
            )
        } catch {
            if let infErr = error as? InferenceError, infErr == .cancelled {
                await handleInterruptedGeneration(
                    messageId: assistantMessageId,
                    conversationId: conversationId,
                    accumulatedText: accumulatedText,
                    tokenCount: tokenCount
                )
            } else {
                // Failure
                try? await database.updateMessageContentAndStatus(
                    id: assistantMessageId,
                    content: accumulatedText.isEmpty ? "Error: \(error.localizedDescription)" : accumulatedText,
                    status: .failed,
                    tokenCount: tokenCount
                )

                if self.selectedConversationId == conversationId {
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                        self.messages[index].status = .failed
                    }
                }
                self.errorMessage = error.localizedDescription
            }
        }

        self.isGenerating = false
        self.activeGenerationConversationId = nil
        self.activeStream = nil
    }

    private func handleInterruptedGeneration(
        messageId: UUID,
        conversationId: UUID,
        accumulatedText: String,
        tokenCount: Int
    ) async {
        try? await database.updateMessageContentAndStatus(
            id: messageId,
            content: accumulatedText,
            status: .interrupted,
            tokenCount: tokenCount
        )

        if self.selectedConversationId == conversationId {
            if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                self.messages[index].content = accumulatedText
                self.messages[index].status = .interrupted
                self.messages[index].tokenCount = tokenCount
            }
        }
    }

    private func markAssistantMessageFailed(id: UUID, errorDescription: String) {
        if let index = self.messages.firstIndex(where: { $0.id == id }) {
            self.messages[index].status = .failed
            self.messages[index].content = "Failed: \(errorDescription)"
        }
        self.errorMessage = errorDescription
    }

    // MARK: - Cancellation Barrier

    /// Cancels active generation and guarantees synchronization via the native termination barrier.
    public func cancelGeneration() async {
        guard let stream = activeStream else {
            // Also invoke inferenceService directly just in case
            await inferenceService.cancelGeneration()
            self.isGenerating = false
            self.activeGenerationConversationId = nil
            return
        }

        // 1. Signal cancellation
        stream.cancel()

        // 2. Mandatory synchronization barrier: await full native worker termination
        await stream.waitForTermination()

        self.isGenerating = false
        self.activeGenerationConversationId = nil
        self.activeStream = nil
    }

    // MARK: - Model Catalog & Lifecycle Management

    public func refreshCatalog() async {
        do {
            self.catalogModels = try await modelLibraryService.fetchCatalog()
            if selectedModelId == nil, let first = catalogModels.first(where: { !$0.isMissing }) {
                self.selectedModelId = first.id
            }
        } catch {
            self.errorMessage = "Failed to load model catalog: \(error.localizedDescription)"
        }
    }

    public func registerLocalModel(url: URL) async {
        self.errorMessage = nil
        do {
            let record = try await modelLibraryService.registerModel(at: url, allowReauthorization: true)
            await refreshCatalog()
            self.selectedModelId = record.id
        } catch {
            self.errorMessage = "Failed to add model: \(error.localizedDescription)"
        }
    }

    public func relinkModel(id: UUID, url: URL) async {
        self.errorMessage = nil
        do {
            let record = try await modelLibraryService.relinkModel(id: id, fileURL: url)
            await refreshCatalog()
            self.selectedModelId = record.id
        } catch {
            self.errorMessage = "Failed to relink model: \(error.localizedDescription)"
        }
    }

    public func removeModelFromCatalog(id: UUID) async {
        do {
            if loadedModelId == id {
                await unloadModel()
            }
            try await modelLibraryService.removeModelFromCatalog(id: id)
            if selectedModelId == id {
                selectedModelId = catalogModels.first(where: { $0.id != id })?.id
            }
            await refreshCatalog()
        } catch {
            self.errorMessage = "Failed to remove model from catalog: \(error.localizedDescription)"
        }
    }

    public func selectAndLoadModel(model: ModelRecord) async {
        guard !isModelLoading else { return }
        self.isModelLoading = true
        self.loadingModelPath = model.filePath
        self.errorMessage = nil

        let previousLoadedId = self.loadedModelId

        do {
            // 1. Prepare and activate security-scoped access for the new model BEFORE calling switchModel.
            // If bookmark resolution or file access fails, the existing model remains completely untouched.
            let resolvedPath = try await modelLibraryService.prepareModelForLoading(id: model.id)

            // 2. Switch model in InferenceService with preLoadAction
            // preLoadAction is called ONLY after active generation is cancelled, termination barrier has completed,
            // and previous native model resources are freed.
            try await inferenceService.switchModel(at: resolvedPath, configuration: .conservative) { [modelLibraryService] in
                if let prevId = previousLoadedId, prevId != model.id {
                    await modelLibraryService.releaseModelAccess(id: prevId)
                }
            }

            self.loadedModelId = model.id
            self.selectedModelId = model.id
            self.inferenceState = await inferenceService.state

            // Associate loaded model with active conversation
            if let convId = selectedConversationId {
                try? await database.updateConversationModel(id: convId, modelName: model.name)
                await refreshConversations()
            }

            await refreshCatalog()
        } catch {
            // Clean up newly acquired security scope if loading failed
            await modelLibraryService.releaseModelAccess(id: model.id)
            let currentState = await inferenceService.state
            if case .loaded = currentState {
                // Previous model remains loaded because failure occurred before switchModel unloaded it
            } else {
                self.loadedModelId = nil
            }
            self.errorMessage = "Failed to load model '\(model.name)': \(error.localizedDescription)"
            self.inferenceState = currentState
        }

        self.isModelLoading = false
        self.loadingModelPath = nil
        updateModelLoadingFlag(from: self.inferenceState)
    }

    public func loadModel(path: String) async {
        guard !isModelLoading else { return }
        self.isModelLoading = true
        self.loadingModelPath = path
        self.errorMessage = nil

        let previousLoadedId = self.loadedModelId

        do {
            try await inferenceService.switchModel(at: path) { [modelLibraryService] in
                if let prevId = previousLoadedId {
                    await modelLibraryService.releaseModelAccess(id: prevId)
                }
            }
            self.inferenceState = await inferenceService.state
            updateModelLoadingFlag(from: self.inferenceState)
            await refreshConversations()
            await refreshCatalog()
        } catch {
            let currentState = await inferenceService.state
            if case .loaded = currentState {
                // Still loaded
            } else {
                self.loadedModelId = nil
            }
            self.errorMessage = "Failed to load model: \(error.localizedDescription)"
            self.inferenceState = currentState
            updateModelLoadingFlag(from: self.inferenceState)
        }
        self.isModelLoading = false
        self.loadingModelPath = nil
    }

    public func unloadModel() async {
        guard !isModelLoading else { return }
        self.errorMessage = nil

        let currentId = self.loadedModelId

        do {
            try await inferenceService.unloadModel()
            if let id = currentId {
                await modelLibraryService.releaseModelAccess(id: id)
                self.loadedModelId = nil
            }
            self.inferenceState = await inferenceService.state
            updateModelLoadingFlag(from: self.inferenceState)
        } catch {
            self.errorMessage = "Failed to unload model: \(error.localizedDescription)"
            self.inferenceState = await inferenceService.state
            updateModelLoadingFlag(from: self.inferenceState)
        }
    }

    // MARK: - Remote Hugging Face Catalog & Downloads

    public func searchRemoteCatalog(query: String? = nil, architecture: String? = nil, sort: HuggingFaceSortOrder? = nil) async {
        let effectiveQuery = query ?? remoteSearchQuery
        let effectiveArch = architecture ?? selectedRemoteArchitecture
        let effectiveSort = sort ?? selectedRemoteSortOrder

        self.isSearchingRemoteCatalog = true
        self.remoteCatalogError = nil

        do {
            let results = try await catalogService.searchModels(
                query: effectiveQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : effectiveQuery,
                architecture: effectiveArch,
                sort: effectiveSort,
                limit: 20
            )
            self.huggingFaceModels = results
            self.isSearchingRemoteCatalog = false

            // Asynchronously enrich models with missing sizes without blocking the UI
            for model in results where model.ggufFiles.contains(where: { $0.size <= 0 }) {
                Task { [weak self] in
                    await self?.fetchAccurateSizes(for: model)
                }
            }
        } catch {
            self.remoteCatalogError = error.localizedDescription
            self.huggingFaceModels = []
            self.isSearchingRemoteCatalog = false
        }
    }

    /// Fetches accurate file sizes and evaluates compatibility for a discovered Hugging Face model repository.
    public func fetchAccurateSizes(for model: HuggingFaceModel, forceRefresh: Bool = false) async {
        let repoId = model.id
        guard !repoMetadataLoading.contains(repoId) else { return }

        if !forceRefresh && !model.ggufFiles.isEmpty && model.ggufFiles.allSatisfy({ $0.size > 0 }) {
            return
        }

        repoMetadataLoading.insert(repoId)
        repoMetadataErrors.removeValue(forKey: repoId)

        do {
            let enriched = try await catalogService.enrichModelWithAccurateFileSizes(model, forceRefresh: forceRefresh)
            if let idx = huggingFaceModels.firstIndex(where: { $0.id == repoId }) {
                huggingFaceModels[idx] = enriched
            }
        } catch {
            repoMetadataErrors[repoId] = error.localizedDescription
        }

        repoMetadataLoading.remove(repoId)
    }

    public func updateRemoteSearchQuery(_ query: String) {
        self.remoteSearchQuery = query
        remoteCatalogSearchTask?.cancel()
        remoteCatalogSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.searchRemoteCatalog()
        }
    }

    public func updateRemoteArchitecture(_ architecture: String?) async {
        self.selectedRemoteArchitecture = architecture
        await searchRemoteCatalog()
    }

    public func updateRemoteCategory(_ category: ModelCategory?) {
        self.selectedRemoteCategory = category
    }

    public func updateRemoteSortOrder(_ sort: HuggingFaceSortOrder) async {
        self.selectedRemoteSortOrder = sort
        await searchRemoteCatalog()
    }

    public func startModelDownload(model: HuggingFaceModel, file: HuggingFaceGGUFFile) async {
        self.errorMessage = nil
        do {
            _ = try await downloadManager.startDownload(
                repoId: model.id,
                filename: file.filename,
                downloadURL: file.downloadURL,
                expectedSize: file.size
            )
            await refreshDownloads()
            startDownloadPollingIfNeeded()
        } catch {
            self.errorMessage = "Failed to start download: \(error.localizedDescription)"
        }
    }

    public func pauseModelDownload(id: UUID) async {
        self.errorMessage = nil
        do {
            try await downloadManager.pauseDownload(id: id)
            await refreshDownloads()
        } catch {
            self.errorMessage = "Failed to pause download: \(error.localizedDescription)"
        }
    }

    public func resumeModelDownload(id: UUID) async {
        self.errorMessage = nil
        do {
            try await downloadManager.resumeDownload(id: id)
            await refreshDownloads()
            startDownloadPollingIfNeeded()
        } catch {
            self.errorMessage = "Failed to resume download: \(error.localizedDescription)"
        }
    }

    public func cancelModelDownload(id: UUID) async {
        self.errorMessage = nil
        do {
            try await downloadManager.cancelDownload(id: id)
            await refreshDownloads()
        } catch {
            self.errorMessage = "Failed to cancel download: \(error.localizedDescription)"
        }
    }

    public func refreshDownloads() async {
        let active = await downloadManager.getActiveDownloads()
        var newMap: [UUID: DownloadProgress] = [:]
        var hasNewlyCompleted = false

        for item in active {
            newMap[item.id] = item
            if item.status == .completed {
                if activeDownloads[item.id]?.status != .completed {
                    hasNewlyCompleted = true
                }
            }
        }
        self.activeDownloads = newMap

        if hasNewlyCompleted {
            await refreshCatalog()
        }
    }

    private func startDownloadPollingIfNeeded() {
        guard downloadPollingTask == nil else { return }
        downloadPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { break }
                await self.refreshDownloads()

                let hasActive = self.activeDownloads.values.contains { $0.status == .downloading }
                if !hasActive {
                    break
                }
            }
            guard let self else { return }
            self.downloadPollingTask = nil
        }
    }
}
