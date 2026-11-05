import Foundation
import os

/// High-level actor coordinating inference engine lifecycle, state transitions, and worker operations.
///
/// Execution Architecture:
/// `InferenceService` acts as a high-level asynchronous state machine. It does **not** execute
/// synchronous native C/C++ model-loading or inference calls on its executor. Instead, all native
/// work is delegated to an `InferenceWorkerProtocol` instance backed by a dedicated serial execution context.
public actor InferenceService {
    /// The current high-level state of the inference engine.
    public private(set) var state: InferenceState = .unloaded {
        didSet {
            notifyStateChange(state)
        }
    }

    /// The underlying worker executing queue-confined native llama.cpp operations.
    private let worker: any InferenceWorkerProtocol

    /// Active cancellation signal for in-flight generation.
    private var activeCancellationSignal: CancellationSignal?

    /// Active generation background task reference to coordinate clean shutdown.
    private var activeGenerationTask: Task<Void, Never>?

    /// Unique token identifying the active generation session to prevent stale cleanups.
    private var activeGenerationId: UUID?

    /// Registered state change listeners (invoked on the MainActor for SwiftUI updates).
    private var stateObservers: [@MainActor @Sendable (InferenceState) -> Void] = []

    /// Stream continuation for asynchronous state sequence consumers.
    private var stateContinuations: [UUID: AsyncStream<InferenceState>.Continuation] = [:]

    /// Creates an inference service with the default production native worker.
    public init() {
        self.worker = LlamaInferenceWorker()
    }

    /// Internal initializer for dependency injection during unit testing.
    ///
    /// - Parameter worker: A mock or custom worker instance conforming to `InferenceWorkerProtocol`.
    internal init(worker: any InferenceWorkerProtocol) {
        self.worker = worker
    }

    // MARK: - UI-Observable State Stream & Observers

    /// An asynchronous sequence of state updates suitable for SwiftUI observation.
    public var stateStream: AsyncStream<InferenceState> {
        AsyncStream { continuation in
            let id = UUID()
            self.stateContinuations[id] = continuation
            continuation.yield(self.state)

            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    /// Registers a state change observer callback invoked on the MainActor.
    public func addStateObserver(_ observer: @escaping @MainActor @Sendable (InferenceState) -> Void) {
        stateObservers.append(observer)
        let currentState = self.state
        Task { @MainActor in
            observer(currentState)
        }
    }

    private func removeContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func notifyStateChange(_ newState: InferenceState) {
        for observer in stateObservers {
            Task { @MainActor in
                observer(newState)
            }
        }
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    // MARK: - Lifecycle Operations

    /// Loads a model from the specified local filesystem path.
    ///
    /// Legal State Transitions:
    /// - From `.unloaded` or `.failed`: transitions to `.loading(path:)`, then `.loaded(modelInfo:)` on success
    ///   or `.failed(errorDescription:)` on failure.
    /// - From `.loading`: throws `InferenceError.conflictingOperation`.
    /// - From `.generating`: throws `InferenceError.conflictingOperation`.
    /// - From `.loaded`: throws `InferenceError.alreadyLoaded`.
    /// - From `.unloading`: throws `InferenceError.conflictingOperation`.
    ///
    /// - Parameters:
    ///   - path: The filesystem path pointing to a regular GGUF model file.
    ///   - configuration: Model loading and GPU offloading configuration.
    /// - Returns: Descriptive metadata regarding the successfully loaded model.
    @discardableResult
    public func loadModel(at path: String, configuration: ModelConfiguration = .conservative) async throws -> ModelInfo {
        switch state {
        case .loading:
            throw InferenceError.conflictingOperation("A model load operation is already in progress.")
        case .generating:
            throw InferenceError.conflictingOperation("Cannot load a model while text generation is in progress.")
        case .loaded(let existingInfo):
            throw InferenceError.alreadyLoaded(existingModel: existingInfo.name)
        case .unloading:
            throw InferenceError.conflictingOperation("Cannot load a model while an unload operation is in progress.")
        case .unloaded, .failed:
            break
        }

        // Validate path before entering loading state.
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            let error = InferenceError.invalidModelPath(path)
            state = .failed(errorDescription: error.localizedDescription)
            throw error
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDir) else {
            let error = InferenceError.modelNotFound(trimmedPath)
            state = .failed(errorDescription: error.localizedDescription)
            throw error
        }

        guard !isDir.boolValue else {
            let error = InferenceError.invalidModelPath(trimmedPath)
            state = .failed(errorDescription: error.localizedDescription)
            throw error
        }

        state = .loading(path: trimmedPath)

        do {
            let info = try await worker.loadModel(at: trimmedPath, configuration: configuration)
            state = .loaded(modelInfo: info)
            return info
        } catch {
            let mappedError: InferenceError
            if let infErr = error as? InferenceError {
                mappedError = infErr
            } else {
                mappedError = .modelLoadingFailed(error.localizedDescription)
            }
            state = .failed(errorDescription: mappedError.localizedDescription)
            throw mappedError
        }
    }

    /// Unloads the active model and releases native memory.
    ///
    /// Legal State Transitions:
    /// - From `.loaded`: transitions to `.unloading`, then `.unloaded`.
    /// - From `.unloaded`: no-op, returns immediately.
    /// - From `.loading`: throws `InferenceError.conflictingOperation`.
    /// - From `.generating`: throws `InferenceError.conflictingOperation`.
    /// - From `.unloading`: throws `InferenceError.conflictingOperation`.
    /// - From `.failed`: transitions to `.unloading`, tears down native remnants, and transitions to `.unloaded`.
    public func unloadModel() async throws {
        switch state {
        case .unloaded:
            // Safe idempotent no-op.
            return
        case .loading:
            throw InferenceError.conflictingOperation("Cannot unload a model while a load operation is in progress.")
        case .generating:
            throw InferenceError.conflictingOperation("Cannot unload a model while text generation is in progress.")
        case .unloading:
            throw InferenceError.conflictingOperation("An unload operation is already in progress.")
        case .loaded, .failed:
            break
        }

        state = .unloading

        do {
            try await worker.unloadModel()
            state = .unloaded
        } catch {
            let desc = error.localizedDescription
            state = .failed(errorDescription: "Unload failed: \(desc)")
            throw error
        }
    }

    /// Safely switches to a new model at the specified path, unloading any previously loaded model.
    ///
    /// Preserves the Single Active Model Invariant:
    /// At most one native model is loaded in memory at any time.
    /// If generation is actively running, it is safely cancelled and its termination barrier is awaited
    /// before unloading the prior model and loading the replacement.
    @discardableResult
    public func switchModel(
        at path: String,
        configuration: ModelConfiguration = .conservative,
        preLoadAction: (@Sendable () async throws -> Void)? = nil
    ) async throws -> ModelInfo {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            let error = InferenceError.invalidModelPath(path)
            state = .failed(errorDescription: error.localizedDescription)
            throw error
        }

        // 1. If the requested model is already loaded and ready, no-op return
        if case .loaded(let existingInfo) = state, existingInfo.path == trimmedPath {
            return existingInfo
        }

        // 2. Reject conflicting lifecycle transitions
        switch state {
        case .loading:
            throw InferenceError.conflictingOperation("Cannot switch model while a load operation is already in progress.")
        case .unloading:
            throw InferenceError.conflictingOperation("Cannot switch model while an unload operation is already in progress.")
        case .generating:
            // Safely cancel active generation and wait for full worker termination barrier
            if let task = activeGenerationTask {
                activeCancellationSignal?.cancel()
                _ = await task.value
            }
        case .loaded, .unloaded, .failed:
            break
        }

        // 3. Unload prior model if loaded (releases llama_model and llama_context native resources)
        if case .loaded = state {
            try await unloadModel()
        }

        // 4. Execute pre-load action (e.g. release prior security scope, acquire replacement scope)
        // strictly AFTER prior model native teardown is confirmed complete
        if let preLoadAction {
            try await preLoadAction()
        }

        // 5. Load replacement model
        return try await loadModel(at: trimmedPath, configuration: configuration)
    }

    // MARK: - Text Generation

    /// Generates text incrementally for the specified prompt using the provided configuration.
    ///
    /// - Parameters:
    ///   - prompt: The input text prompt.
    ///   - configuration: Generation and sampling configuration parameters.
    /// - Returns: An asynchronous stream of text chunks adhering to `InferenceStream`.
    public func generate(
        prompt: String,
        configuration: GenerationConfiguration = .default
    ) -> InferenceStream {
        // 1. Synchronously validate actor state before mutating any properties or creating streams
        guard case .loaded(let modelInfo) = state else {
            let error: InferenceError
            switch state {
            case .unloaded, .failed:
                error = .notLoaded
            case .loading:
                error = .conflictingOperation("Cannot generate while a model is loading.")
            case .generating:
                error = .conflictingOperation("A generation operation is already in progress.")
            case .unloading:
                error = .conflictingOperation("Cannot generate while a model is unloading.")
            case .loaded:
                error = .notLoaded
            }
            return InferenceStream.preFailed(error: error)
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return InferenceStream.preFailed(error: InferenceError.invalidPrompt("Prompt cannot be empty or whitespace only."))
        }

        do {
            try configuration.validate()
        } catch let configError as InferenceError {
            return InferenceStream.preFailed(error: configError)
        } catch {
            return InferenceStream.preFailed(error: InferenceError.invalidConfiguration(error.localizedDescription))
        }

        // 2. Atomically reserve generation and set ownership token
        let generationId = UUID()
        let signal = CancellationSignal()

        self.activeGenerationId = generationId
        self.activeCancellationSignal = signal
        self.state = .generating(modelInfo: modelInfo)

        let (baseStream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        // 3. Spawns generation task strictly owned by InferenceStream
        let generationTask = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: InferenceError.workerUnavailable)
                return
            }
            do {
                try await self.executeGeneration(
                    generationId: generationId,
                    modelInfo: modelInfo,
                    prompt: trimmedPrompt,
                    configuration: configuration,
                    signal: signal,
                    continuation: continuation
                )
            } catch {
                continuation.finish(throwing: error)
            }
        }

        self.activeGenerationTask = generationTask

        let onTermination: @Sendable () -> Void = {
            signal.cancel()
            generationTask.cancel()
        }

        continuation.onTermination = { @Sendable _ in
            onTermination()
        }

        return InferenceStream(
            base: baseStream,
            signal: signal,
            generationTask: generationTask,
            onCancel: onTermination
        )
    }

    /// Synchronously signals cancellation to any active text generation.
    public func cancelGeneration() {
        activeCancellationSignal?.cancel()
    }

    private func executeGeneration(
        generationId: UUID,
        modelInfo: ModelInfo,
        prompt: String,
        configuration: GenerationConfiguration,
        signal: CancellationSignal,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        defer {
            if self.activeGenerationId == generationId {
                self.activeGenerationId = nil
                self.activeCancellationSignal = nil
                self.activeGenerationTask = nil
                if case .generating = self.state {
                    self.state = .loaded(modelInfo: modelInfo)
                }
            }
        }

        if signal.isCancelled || Task.isCancelled {
            continuation.finish(throwing: InferenceError.cancelled)
            throw InferenceError.cancelled
        }

        do {
            try await worker.generate(
                prompt: prompt,
                configuration: configuration,
                cancellationSignal: signal,
                onToken: { tokenPiece in
                    let result = continuation.yield(tokenPiece)
                    if case .terminated = result {
                        signal.cancel()
                    }
                }
            )
            continuation.finish()
        } catch {
            let mappedError: InferenceError
            if let infErr = error as? InferenceError {
                mappedError = infErr
            } else if error is CancellationError {
                mappedError = .cancelled
            } else {
                mappedError = .decodeFailed(code: -1, description: error.localizedDescription)
            }

            if mappedError != .cancelled {
                if self.activeGenerationId == generationId {
                    self.state = .failed(errorDescription: mappedError.localizedDescription)
                }
            }
            continuation.finish(throwing: mappedError)
            throw mappedError
        }
    }

    /// Generates text incrementally for a multi-turn conversation represented by `[PromptMessage]`.
    /// Applies native model chat templating and context window budgeting.
    ///
    /// - Parameters:
    ///   - messages: Chronologically ordered conversation messages.
    ///   - configuration: Generation and sampling configuration parameters.
    ///   - modelArchitecture: Optional model architecture identifier (e.g., "llama-3", "mistral") for template fallbacks.
    /// - Returns: An asynchronous stream of text chunks adhering to `InferenceStream`.
    public func generate(
        messages: [PromptMessage],
        configuration: GenerationConfiguration = .default,
        modelArchitecture: String? = nil
    ) -> InferenceStream {
        // 1. Synchronously validate actor state before mutating any properties or creating streams
        guard case .loaded(let modelInfo) = state else {
            let error: InferenceError
            switch state {
            case .unloaded, .failed:
                error = .notLoaded
            case .loading:
                error = .conflictingOperation("Cannot generate while a model is loading.")
            case .generating:
                error = .conflictingOperation("A generation operation is already in progress.")
            case .unloading:
                error = .conflictingOperation("Cannot generate while a model is unloading.")
            case .loaded:
                error = .notLoaded
            }
            return InferenceStream.preFailed(error: error)
        }

        guard !messages.isEmpty else {
            return InferenceStream.preFailed(error: InferenceError.invalidPrompt("Conversation messages cannot be empty."))
        }

        do {
            try configuration.validate()
        } catch let configError as InferenceError {
            return InferenceStream.preFailed(error: configError)
        } catch {
            return InferenceStream.preFailed(error: InferenceError.invalidConfiguration(error.localizedDescription))
        }

        // 2. Atomically reserve generation and set ownership token
        let generationId = UUID()
        let signal = CancellationSignal()

        self.activeGenerationId = generationId
        self.activeCancellationSignal = signal
        self.state = .generating(modelInfo: modelInfo)

        let (baseStream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        // 3. Spawns generation task strictly owned by InferenceStream
        let generationTask = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: InferenceError.workerUnavailable)
                return
            }
            do {
                try await self.executeConversationGeneration(
                    generationId: generationId,
                    modelInfo: modelInfo,
                    messages: messages,
                    configuration: configuration,
                    modelArchitecture: modelArchitecture,
                    signal: signal,
                    continuation: continuation
                )
            } catch {
                continuation.finish(throwing: error)
            }
        }

        self.activeGenerationTask = generationTask

        let onTermination: @Sendable () -> Void = {
            signal.cancel()
            generationTask.cancel()
        }

        continuation.onTermination = { @Sendable _ in
            onTermination()
        }

        return InferenceStream(
            base: baseStream,
            signal: signal,
            generationTask: generationTask,
            onCancel: onTermination
        )
    }

    private func executeConversationGeneration(
        generationId: UUID,
        modelInfo: ModelInfo,
        messages: [PromptMessage],
        configuration: GenerationConfiguration,
        modelArchitecture: String?,
        signal: CancellationSignal,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        defer {
            if self.activeGenerationId == generationId {
                self.activeGenerationId = nil
                self.activeCancellationSignal = nil
                self.activeGenerationTask = nil
                if case .generating = self.state {
                    self.state = .loaded(modelInfo: modelInfo)
                }
            }
        }

        if signal.isCancelled || Task.isCancelled {
            continuation.finish(throwing: InferenceError.cancelled)
            throw InferenceError.cancelled
        }

        do {
            // Retrieve embedded template from model metadata
            let template = await worker.getModelChatTemplate()

            // Perform context budgeting with exact token counts from worker
            let budgetResult = try await ContextBudgeter.budget(
                messages: messages,
                contextLength: Int(configuration.contextLength),
                maxTokens: Int(configuration.maxTokens),
                tokenizer: { [worker] text in
                    try await worker.countTokens(for: text)
                }
            )

            // Format budgeted messages using native llama.cpp chat template
            let formattedPrompt = try ChatTemplateFormatter.apply(
                template: template,
                messages: budgetResult.budgetedMessages,
                addAssistantPrompt: true,
                modelArchitecture: modelArchitecture
            )

            if signal.isCancelled || Task.isCancelled {
                continuation.finish(throwing: InferenceError.cancelled)
                throw InferenceError.cancelled
            }

            // Forward formatted prompt to native worker
            try await worker.generate(
                prompt: formattedPrompt,
                configuration: configuration,
                cancellationSignal: signal,
                onToken: { tokenPiece in
                    let result = continuation.yield(tokenPiece)
                    if case .terminated = result {
                        signal.cancel()
                    }
                }
            )
            continuation.finish()
        } catch {
            let mappedError: InferenceError
            if let infErr = error as? InferenceError {
                mappedError = infErr
            } else if error is CancellationError {
                mappedError = .cancelled
            } else {
                mappedError = .decodeFailed(code: -1, description: error.localizedDescription)
            }

            if mappedError != .cancelled {
                if self.activeGenerationId == generationId {
                    self.state = .failed(errorDescription: mappedError.localizedDescription)
                }
            }
            continuation.finish(throwing: mappedError)
            throw mappedError
        }
    }

    /// Counts tokens for the specified text using the loaded model's vocabulary.
    public func countTokens(for text: String) async throws -> Int {
        guard case .loaded = state else {
            throw InferenceError.notLoaded
        }
        return try await worker.countTokens(for: text)
    }

    /// Retrieves the embedded chat template string from the loaded model metadata, if present.
    public func getModelChatTemplate() async throws -> String? {
        guard case .loaded = state else {
            throw InferenceError.notLoaded
        }
        return await worker.getModelChatTemplate()
    }

    /// Performs complete shutdown of the inference engine and associated native backends.
    public func shutdown() async {
        activeCancellationSignal?.cancel()
        if let task = activeGenerationTask {
            _ = await task.value
        }
        activeCancellationSignal = nil
        activeGenerationId = nil
        activeGenerationTask = nil

        // Attempt to unload any resident model first.
        try? await worker.unloadModel()
        await worker.shutdown()

        state = .unloaded

        for continuation in stateContinuations.values {
            continuation.finish()
        }
        stateContinuations.removeAll()
        stateObservers.removeAll()
    }
}

// MARK: - InferenceStream & Controlled Lifecycle

/// An asynchronous sequence delivering generated text chunks incrementally to a consumer.
///
/// Lifecycle & Ownership Guarantees:
/// - Explicit Ownership: The stream owns the background generation task and its atomic cancellation signal.
/// - Early Consumer Termination: If the consumer breaks or returns early, or if the stream is abandoned
///   without iteration, `cancel()` halts the underlying worker and returns the service to `.loaded`.
/// - Single-Consumer Enforcement: `makeAsyncIterator()` permits exactly one active consumer. A second iteration
///   attempt immediately throws `InferenceError.conflictingOperation`.
/// - Pre-Failed Support: If state validation fails synchronously on reservation, a pre-failed stream delivers
///   the error upon iteration without ever launching background native work or corrupting active generation state.
public final class InferenceStream: AsyncSequence, Sendable {
    public typealias Element = String
    public typealias Failure = Error

    private let base: AsyncThrowingStream<String, Error>
    private let signal: CancellationSignal?
    private let generationTask: Task<Void, Never>?
    private let onCancel: (@Sendable () -> Void)?
    private let preFailedError: Error?
    private let hasIterated = OSAllocatedUnfairLock(initialState: false)
    private let isTerminated = OSAllocatedUnfairLock(initialState: false)

    internal init(
        base: AsyncThrowingStream<String, Error>,
        signal: CancellationSignal,
        generationTask: Task<Void, Never>,
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.base = base
        self.signal = signal
        self.generationTask = generationTask
        self.onCancel = onCancel
        self.preFailedError = nil
    }

    internal static func preFailed(error: Error) -> InferenceStream {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.finish(throwing: error)
        return InferenceStream(preFailedStream: stream, error: error)
    }

    private init(preFailedStream: AsyncThrowingStream<String, Error>, error: Error) {
        self.base = preFailedStream
        self.signal = nil
        self.generationTask = nil
        self.onCancel = nil
        self.preFailedError = error
    }

    deinit {
        cancel()
    }

    /// Explicitly cancels in-flight text generation and releases associated worker resources.
    public func cancel() {
        let shouldCancel = isTerminated.withLock { terminated -> Bool in
            if terminated { return false }
            terminated = true
            return true
        }
        if shouldCancel {
            signal?.cancel()
            generationTask?.cancel()
            onCancel?()
        }
    }

    /// Awaits the complete termination and exit of the underlying generation task and worker execution.
    public func waitForTermination() async {
        _ = await generationTask?.value
    }

    private final class EarlyExitTracker: @unchecked Sendable {
        private let stream: InferenceStream
        private let completed = OSAllocatedUnfairLock(initialState: false)

        init(stream: InferenceStream) {
            self.stream = stream
        }

        func markCompleted() {
            completed.withLock { $0 = true }
        }

        deinit {
            let wasCompleted = completed.withLock { $0 }
            if !wasCompleted {
                stream.cancel()
            }
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private final class Storage: @unchecked Sendable {
            private var baseIterator: AsyncThrowingStream<String, Error>.AsyncIterator?

            init(baseIterator: AsyncThrowingStream<String, Error>.AsyncIterator?) {
                self.baseIterator = baseIterator
            }

            func next() async throws -> String? {
                guard var iter = baseIterator else { return nil }
                let item = try await iter.next()
                self.baseIterator = iter
                return item
            }

            func clear() {
                baseIterator = nil
            }
        }

        private let storage: Storage
        private let stream: InferenceStream?
        private let tracker: EarlyExitTracker?
        private let immediateError: Error?

        fileprivate init(baseIterator: AsyncThrowingStream<String, Error>.AsyncIterator, stream: InferenceStream) {
            self.storage = Storage(baseIterator: baseIterator)
            self.stream = stream
            self.tracker = EarlyExitTracker(stream: stream)
            self.immediateError = nil
        }

        fileprivate init(immediateError: Error) {
            self.storage = Storage(baseIterator: nil)
            self.stream = nil
            self.tracker = nil
            self.immediateError = immediateError
        }

        public mutating func next() async throws -> String? {
            if let immediateError {
                throw immediateError
            }

            if Task.isCancelled {
                tracker?.markCompleted()
                stream?.cancel()
                throw CancellationError()
            }

            let stream = self.stream
            let tracker = self.tracker

            do {
                let item = try await withTaskCancellationHandler {
                    try await storage.next()
                } onCancel: {
                    stream?.cancel()
                }

                if let item {
                    return item
                } else {
                    storage.clear()
                    if Task.isCancelled {
                        tracker?.markCompleted()
                        stream?.cancel()
                        throw CancellationError()
                    }
                    tracker?.markCompleted()
                    stream?.markCompleted()
                    return nil
                }
            } catch {
                storage.clear()
                tracker?.markCompleted()
                stream?.cancel()
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                } else if let infError = error as? InferenceError, infError == .cancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
    }

    fileprivate func markCompleted() {
        isTerminated.withLock { $0 = true }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        if let preFailedError {
            return AsyncIterator(immediateError: preFailedError)
        }

        let alreadyIterated = hasIterated.withLock { iterated -> Bool in
            if iterated { return true }
            iterated = true
            return false
        }

        guard !alreadyIterated else {
            return AsyncIterator(immediateError: InferenceError.conflictingOperation("InferenceStream does not support multiple concurrent iterations."))
        }

        return AsyncIterator(baseIterator: base.makeAsyncIterator(), stream: self)
    }
}
