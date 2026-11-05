import Foundation

/// Internal contract defining operations executed on a dedicated serial inference worker.
///
/// Designed to enable isolated, deterministic unit testing of the `InferenceService` coordinator
/// without requiring heavy native model downloads or GPU allocations.
internal protocol InferenceWorkerProtocol: Sendable {
    /// Initializes native backend subsystems if not already active.
    func initializeBackend() async throws

    /// Loads a model from the specified filesystem path with the provided configuration.
    ///
    /// - Parameters:
    ///   - path: The verified local filesystem path to the model file.
    ///   - configuration: Hardware and offloading configuration parameters.
    /// - Returns: Descriptive metadata regarding the loaded model.
    func loadModel(at path: String, configuration: ModelConfiguration) async throws -> ModelInfo

    /// Unloads the active model and frees all associated native resources.
    ///
    /// Must be safe and idempotent to call when no model is loaded.
    func unloadModel() async throws

    /// Performs complete shutdown of the worker, tearing down native backends and threadpools.
    func shutdown() async

    /// Inspects whether a model is currently resident in worker memory.
    func isModelLoaded() async -> Bool

    /// Retrieves the embedded chat template string from model metadata, if present.
    func getModelChatTemplate() async -> String?

    /// Counts tokens for the specified text using the loaded model's vocabulary.
    func countTokens(for text: String) async throws -> Int

    /// Generates text incrementally for the specified prompt using the provided configuration.
    ///
    /// - Parameters:
    ///   - prompt: Validated input text prompt.
    ///   - configuration: Generation and sampling parameters.
    ///   - cancellationSignal: Thread-safe atomic cancellation signal.
    ///   - onToken: Callback invoked incrementally for each generated text piece.
    func generate(
        prompt: String,
        configuration: GenerationConfiguration,
        cancellationSignal: CancellationSignal,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws
}
