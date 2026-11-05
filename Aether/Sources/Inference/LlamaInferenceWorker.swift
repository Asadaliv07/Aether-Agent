import Foundation
import os
import llama

/// Concrete inference worker managing native `llama.cpp` resources on a dedicated serial execution context.
///
/// Thread Safety & Concurrency Guarantee:
/// All mutable state—including raw C model pointers (`llama_model *`), context pointers (`llama_context *`),
/// batches, and sampler chains—is strictly confined to `queue` (`com.aether.inference.worker`).
/// No native pointer ever escapes across thread or queue boundaries.
internal final class LlamaInferenceWorker: InferenceWorkerProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.aether.Aether", category: "LlamaInferenceWorker")

    /// Dedicated private serial queue for all native C calls and model state mutation.
    private let queue: DispatchQueue

    /// Unique dispatch key associated with this worker's serial queue to detect re-entrant teardown.
    private let queueKey = DispatchSpecificKey<Void>()

    /// Pointer to the loaded native `llama_model`.
    /// Strictly accessed and mutated only within `queue`.
    private var model: OpaquePointer?

    /// Pointer to the active native `llama_context`.
    /// Strictly accessed and mutated only within `queue`.
    private var context: OpaquePointer?

    /// Allocated context length of the active native context.
    private var allocatedContextLength: UInt32 = 0

    /// Metadata corresponding to the active model.
    private var loadedModelInfo: ModelInfo?

    /// Tracks whether `llama_backend_init()` has been successfully executed.
    private var isBackendInitialized: Bool = false

    /// Tracks whether the worker has been permanently shut down.
    private var isShutdown: Bool = false

    public init(queueLabel: String = "com.aether.inference.worker") {
        let q = DispatchQueue(label: queueLabel, qos: .userInitiated)
        q.setSpecific(key: self.queueKey, value: ())
        self.queue = q
    }

    #if DEBUG
    /// Internal queue accessor for lifecycle regression testing.
    internal var executionQueue: DispatchQueue { queue }
    #endif

    deinit {
        // Ensure native resources are cleaned up deterministically upon deallocation in verified destruction order:
        // context -> model -> backend.
        let ctxPtr = self.context
        let modelPtr = self.model
        let wasBackendInit = self.isBackendInitialized
        guard ctxPtr != nil || modelPtr != nil || wasBackendInit else {
            return
        }

        let cleanup = {
            if let ctx = ctxPtr {
                llama_synchronize(ctx)
                llama_free(ctx)
            }
            if let ptr = modelPtr {
                llama_model_free(ptr)
            }
            if wasBackendInit {
                llama_backend_free()
            }
        }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            // DEF-38-05: Re-entrancy detection.
            // If deinitialization is invoked while already on this worker's serial queue
            // (e.g. the final release occurred during closure destruction on the queue),
            // executing queue.sync would result in a libdispatch self-deadlock (__DISPATCH_WAIT_FOR_QUEUE__).
            // Clean up native resources directly inline on the worker queue.
            cleanup()
        } else {
            // Invoked from an external thread: synchronize with the worker queue to ensure
            // native llama.cpp pointer destruction is safely serialized.
            queue.sync(execute: cleanup)
        }
    }

    // MARK: - InferenceWorkerProtocol

    public func initializeBackend() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.syncInitializeBackend()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func loadModel(at path: String, configuration: ModelConfiguration) async throws -> ModelInfo {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let info = try self.syncLoadModel(at: path, configuration: configuration)
                    continuation.resume(returning: info)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func unloadModel() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.syncUnloadModel()
                continuation.resume()
            }
        }
    }

    public func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.syncShutdown()
                continuation.resume()
            }
        }
    }

    public func isModelLoaded() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.model != nil)
            }
        }
    }

    public func getModelChatTemplate() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let model = self.model else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let tmplPtr = llama_model_chat_template(model, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let tmpl = String(cString: tmplPtr)
                continuation.resume(returning: tmpl.isEmpty ? nil : tmpl)
            }
        }
    }

    public func countTokens(for text: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let model = self.model else {
                    continuation.resume(throwing: InferenceError.notLoaded)
                    return
                }
                guard let vocab = llama_model_get_vocab(model) else {
                    continuation.resume(throwing: InferenceError.tokenizationFailed("Failed to obtain vocabulary from model."))
                    return
                }
                if text.isEmpty {
                    continuation.resume(returning: 0)
                    return
                }
                let textUtf8Count = Int32(text.utf8.count)
                let nTokens = llama_tokenize(vocab, text, textUtf8Count, nil, 0, false, true)
                if nTokens < 0 {
                    continuation.resume(returning: Int(-nTokens))
                } else {
                    continuation.resume(returning: Int(nTokens))
                }
            }
        }
    }

    public func generate(
        prompt: String,
        configuration: GenerationConfiguration,
        cancellationSignal: CancellationSignal,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.syncGenerate(
                        prompt: prompt,
                        configuration: configuration,
                        cancellationSignal: cancellationSignal,
                        onToken: onToken
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synchronous Queue-Confined Implementations

    private func syncInitializeBackend() throws {
        guard !isShutdown else {
            throw InferenceError.workerUnavailable
        }
        guard !isBackendInitialized else {
            return
        }

        llama_backend_init()
        isBackendInitialized = true
    }

    private func syncLoadModel(at path: String, configuration: ModelConfiguration) throws -> ModelInfo {
        guard !isShutdown else {
            throw InferenceError.workerUnavailable
        }

        // Prevent silent overwrite of an existing model.
        if model != nil {
            let name = loadedModelInfo?.name ?? "Unknown"
            throw InferenceError.alreadyLoaded(existingModel: name)
        }

        // Preliminary filesystem validation.
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceError.invalidModelPath(path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw InferenceError.modelNotFound(path)
        }

        guard !isDirectory.boolValue else {
            throw InferenceError.invalidModelPath(path)
        }

        // Ensure backend subsystems are initialized prior to model loading.
        try syncInitializeBackend()

        // Prepare verified llama.cpp model parameters.
        var params = llama_model_default_params()
        params.n_gpu_layers = configuration.gpuLayers
        params.check_tensors = configuration.checkTensors

        // Invoke native model load.
        guard let loadedModel = llama_model_load_from_file(path, params) else {
            throw InferenceError.modelLoadingFailed("llama_model_load_from_file returned null for '\(path)'")
        }

        // Extract model descriptive metadata.
        let descBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
        descBuffer.initialize(repeating: 0, count: 256)
        defer {
            descBuffer.deallocate()
        }

        let descChars = llama_model_desc(loadedModel, descBuffer, 256)
        let descString: String
        if descChars > 0 {
            descString = String(cString: descBuffer)
        } else {
            descString = "GGUF Model"
        }

        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        let modelName = (path as NSString).lastPathComponent
        let info = ModelInfo(
            path: path,
            name: modelName,
            sizeInBytes: fileSize,
            description: descString
        )

        self.model = loadedModel
        self.loadedModelInfo = info
        return info
    }

    private func syncUnloadModel() {
        guard !isShutdown else {
            return
        }

        // Verified teardown order: free context before model.
        if let ctx = context {
            llama_synchronize(ctx)
            llama_free(ctx)
            context = nil
            allocatedContextLength = 0
        }

        if let ptr = model {
            llama_model_free(ptr)
            model = nil
            loadedModelInfo = nil
        }
    }

    private func syncShutdown() {
        guard !isShutdown else {
            return
        }

        // 1. Teardown active context if present.
        if let ctx = context {
            llama_synchronize(ctx)
            llama_free(ctx)
            context = nil
            allocatedContextLength = 0
        }

        // 2. Teardown active model if present.
        if let ptr = model {
            llama_model_free(ptr)
            model = nil
            loadedModelInfo = nil
        }

        // 3. Teardown native backend if initialized.
        if isBackendInitialized {
            llama_backend_free()
            isBackendInitialized = false
        }

        isShutdown = true
    }

    private func syncGenerate(
        prompt: String,
        configuration: GenerationConfiguration,
        cancellationSignal: CancellationSignal,
        onToken: (String) -> Void
    ) throws {
        guard !isShutdown else {
            throw InferenceError.workerUnavailable
        }

        guard let model else {
            throw InferenceError.notLoaded
        }

        try configuration.validate()

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw InferenceError.invalidPrompt("Prompt cannot be empty or whitespace only.")
        }

        if cancellationSignal.isCancelled {
            throw InferenceError.cancelled
        }

        guard let vocab = llama_model_get_vocab(model) else {
            throw InferenceError.tokenizationFailed("Failed to obtain vocabulary from model.")
        }

        // Tokenize prompt
        let promptUtf8Count = Int32(trimmedPrompt.utf8.count)
        let neededTokens = -llama_tokenize(vocab, trimmedPrompt, promptUtf8Count, nil, 0, true, true)
        guard neededTokens > 0 else {
            throw InferenceError.tokenizationFailed("Prompt tokenization returned empty or invalid token count (\(neededTokens)).")
        }

        var promptTokens = [llama_token](repeating: 0, count: Int(neededTokens))
        let tokenCount = llama_tokenize(vocab, trimmedPrompt, promptUtf8Count, &promptTokens, Int32(promptTokens.count), true, true)
        guard tokenCount > 0 else {
            throw InferenceError.tokenizationFailed("Prompt tokenization failed with code \(tokenCount).")
        }

        // Check context capacity before initiating context work
        guard Int(tokenCount) + 1 <= Int(configuration.contextLength) else {
            throw InferenceError.contextExhausted(promptTokens: Int(tokenCount), maxContext: Int(configuration.contextLength))
        }

        // Reuse existing context if contextLength matches, otherwise reallocate
        let ctx: OpaquePointer
        if let existingCtx = self.context, self.allocatedContextLength == configuration.contextLength {
            llama_memory_clear(llama_get_memory(existingCtx), true)
            ctx = existingCtx
        } else {
            if let existingCtx = self.context {
                llama_synchronize(existingCtx)
                llama_free(existingCtx)
                self.context = nil
                self.allocatedContextLength = 0
            }

            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = configuration.contextLength
            ctxParams.n_batch = min(configuration.contextLength, 512)
            let nThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
            ctxParams.n_threads = Int32(nThreads)
            ctxParams.n_threads_batch = Int32(nThreads)
            ctxParams.no_perf = true

            guard let newCtx = llama_init_from_model(model, ctxParams) else {
                throw InferenceError.contextInitializationFailed("llama_init_from_model failed to allocate context of size \(configuration.contextLength).")
            }
            self.context = newCtx
            self.allocatedContextLength = configuration.contextLength
            ctx = newCtx
        }

        // Register C abort callback with atomic signal
        llama_set_abort_callback(ctx, aether_abort_callback, cancellationSignal.rawPointer)
        defer {
            llama_set_abort_callback(ctx, nil, nil)
        }

        // Initialize sampler chain
        let sparams = llama_sampler_chain_default_params()
        guard let smpl = llama_sampler_chain_init(sparams) else {
            throw InferenceError.contextInitializationFailed("llama_sampler_chain_init returned null.")
        }
        defer {
            llama_sampler_free(smpl)
        }

        if configuration.temperature <= 0.0 {
            llama_sampler_chain_add(smpl, llama_sampler_init_greedy())
        } else {
            if configuration.topK > 0 {
                llama_sampler_chain_add(smpl, llama_sampler_init_top_k(configuration.topK))
            }
            if configuration.topP < 1.0 {
                llama_sampler_chain_add(smpl, llama_sampler_init_top_p(configuration.topP, 1))
            }
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(configuration.temperature))
            llama_sampler_chain_add(smpl, llama_sampler_init_dist(configuration.seed))
        }

        // Prepare batch for prompt evaluation in bounded chunks of maxBatchSize <= n_batch.
        // Chunking prevents GGML_ASSERT(n_tokens_all <= cparams.n_batch) and ggml_abort()
        // when prompts (such as long pastes or multi-turn history) exceed n_batch (512).
        let maxBatchSize = Int(min(configuration.contextLength, 512))
        var promptBatch = llama_batch_init(Int32(maxBatchSize), 0, 1)
        defer {
            llama_batch_free(promptBatch)
        }

        var promptOffset = 0
        let totalTokens = Int(tokenCount)

        while promptOffset < totalTokens {
            if cancellationSignal.isCancelled {
                llama_synchronize(ctx)
                llama_memory_clear(llama_get_memory(ctx), true)
                throw InferenceError.cancelled
            }

            let chunkSize = min(totalTokens - promptOffset, maxBatchSize)
            promptBatch.n_tokens = Int32(chunkSize)

            for i in 0..<chunkSize {
                let globalIndex = promptOffset + i
                promptBatch.token[i] = promptTokens[globalIndex]
                promptBatch.pos[i] = llama_pos(globalIndex)
                promptBatch.n_seq_id[i] = 1
                guard let seqPtr = promptBatch.seq_id[i] else {
                    throw InferenceError.contextInitializationFailed("Batch seq_id allocation failed at index \(i).")
                }
                seqPtr[0] = 0
                // Logits required only for the final token of the full prompt
                promptBatch.logits[i] = (globalIndex == totalTokens - 1) ? 1 : 0
            }

            let promptDecodeRes = llama_decode(ctx, promptBatch)
            if promptDecodeRes != 0 {
                llama_synchronize(ctx)
                llama_memory_clear(llama_get_memory(ctx), true)
                if promptDecodeRes == 2 || cancellationSignal.isCancelled {
                    throw InferenceError.cancelled
                } else if promptDecodeRes == 1 {
                    throw InferenceError.contextExhausted(promptTokens: totalTokens, maxContext: Int(configuration.contextLength))
                } else {
                    throw InferenceError.decodeFailed(code: promptDecodeRes, description: "Prompt evaluation failed at token offset \(promptOffset) / \(totalTokens).")
                }
            }

            promptOffset += chunkSize
        }

        logger.debug("Prompt evaluation completed: \(totalTokens) tokens evaluated in \((totalTokens + maxBatchSize - 1) / maxBatchSize) chunks.")

        // Incremental generation loop
        var nCur: Int32 = Int32(tokenCount)
        var nDecoded: Int32 = 0
        var utf8Buffer = UTF8Buffer()
        var stopFilter = StreamingStopFilter(stopSequences: configuration.stopSequences)

        var singleBatch = llama_batch_init(1, 0, 1)
        defer {
            llama_batch_free(singleBatch)
        }

        while nDecoded < configuration.maxTokens {
            if cancellationSignal.isCancelled {
                llama_synchronize(ctx)
                llama_memory_clear(llama_get_memory(ctx), true)
                throw InferenceError.cancelled
            }

            if nCur >= Int32(configuration.contextLength) {
                break
            }

            let newToken = llama_sampler_sample(smpl, ctx, -1)
            llama_sampler_accept(smpl, newToken)

            if llama_vocab_is_eog(vocab, newToken) {
                break
            }

            if !llama_vocab_is_control(vocab, newToken) {
                let pieceChars = self.tokenToPiece(vocab: vocab, token: newToken)
                if !pieceChars.isEmpty {
                    let decodedString = utf8Buffer.processBytes(pieceChars.map { UInt8(bitPattern: $0) })
                    if !decodedString.isEmpty {
                        let (textToEmit, didHitStop) = stopFilter.append(decodedString)
                        if !textToEmit.isEmpty {
                            onToken(textToEmit)
                        }
                        if didHitStop {
                            break
                        }
                    }
                }
            }

            nCur += 1
            nDecoded += 1

            // Terminate before singleBatch decode if maxTokens boundary has been reached
            if nDecoded >= configuration.maxTokens {
                break
            }

            singleBatch.token[0] = newToken
            singleBatch.pos[0] = nCur - 1
            singleBatch.n_seq_id[0] = 1
            guard let singleSeqPtr = singleBatch.seq_id[0] else {
                throw InferenceError.contextInitializationFailed("Single batch seq_id allocation failed.")
            }
            singleSeqPtr[0] = 0
            singleBatch.logits[0] = 1
            singleBatch.n_tokens = 1

            let decodeRes = llama_decode(ctx, singleBatch)
            if decodeRes != 0 {
                llama_synchronize(ctx)
                llama_memory_clear(llama_get_memory(ctx), true)
                if decodeRes == 2 || cancellationSignal.isCancelled {
                    throw InferenceError.cancelled
                } else if decodeRes == 1 {
                    // KV cache limit reached
                    break
                } else {
                    throw InferenceError.decodeFailed(code: decodeRes, description: "Token decode failed at token \(nDecoded).")
                }
            }
        }

        // Flush any remaining characters in the UTF-8 accumulator through the stop filter
        let remainingUtf8 = utf8Buffer.flush()
        let (finalSafeText, didHitStop) = stopFilter.append(remainingUtf8)
        if !finalSafeText.isEmpty {
            onToken(finalSafeText)
        }
        if !didHitStop {
            let flushedText = stopFilter.flush()
            if !flushedText.isEmpty {
                onToken(flushedText)
            }
        }

        // Synchronize outstanding GPU operations and clean up KV cache
        llama_synchronize(ctx)
        llama_memory_clear(llama_get_memory(ctx), true)
    }

    private func tokenToPiece(vocab: OpaquePointer, token: llama_token) -> [CChar] {
        let bufSize = 8
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: bufSize)
        result.initialize(repeating: Int8(0), count: bufSize)
        defer {
            result.deallocate()
        }

        let nTokens = llama_token_to_piece(vocab, token, result, Int32(bufSize), 0, false)
        if nTokens < 0 {
            let actualSize = Int(-nTokens)
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: actualSize)
            newResult.initialize(repeating: Int8(0), count: actualSize)
            defer {
                newResult.deallocate()
            }

            let nNew = llama_token_to_piece(vocab, token, newResult, Int32(actualSize), 0, false)
            guard nNew > 0 else {
                return []
            }
            return Array(UnsafeBufferPointer(start: newResult, count: Int(nNew)))
        } else if nTokens > 0 {
            return Array(UnsafeBufferPointer(start: result, count: Int(nTokens)))
        } else {
            return []
        }
    }
}





