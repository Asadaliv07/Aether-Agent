import Foundation

/// Strongly typed errors covering model lifecycle, resource management, and state conflicts.
public enum InferenceError: LocalizedError, Sendable, Equatable {
    /// The specified path is empty, malformed, or does not point to a regular file.
    case invalidModelPath(String)

    /// The model file does not exist at the designated path.
    case modelNotFound(String)

    /// Native llama.cpp failed to load the model file (e.g. invalid format, corrupt GGUF, or allocation failure).
    case modelLoadingFailed(String)

    /// A lifecycle operation was requested that contradicts the current state.
    case conflictingOperation(String)

    /// An attempt was made to load a model when one is already active.
    case alreadyLoaded(existingModel: String)

    /// An operation requiring a loaded model was invoked while unloaded.
    case notLoaded

    /// The dedicated background inference worker has been shut down or is unavailable.
    case workerUnavailable

    /// Failed to initialize the native llama.cpp backend subsystems.
    case backendInitializationFailed(String)

    /// The provided prompt is empty or invalid.
    case invalidPrompt(String)

    /// The generation configuration contains invalid parameters.
    case invalidConfiguration(String)

    /// Failed to initialize the native context from the loaded model.
    case contextInitializationFailed(String)

    /// The prompt token count plus generation tokens exceeds allocated context capacity.
    case contextExhausted(promptTokens: Int, maxContext: Int)

    /// Failed to tokenize the prompt into vocabulary token IDs.
    case tokenizationFailed(String)

    /// Native llama_decode failed with a specific return code.
    case decodeFailed(code: Int32, description: String)

    /// Generation was cancelled cooperatively before or during execution.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidModelPath(let path):
            return "Invalid model path: '\(path)'. Path must point to an existing regular file."
        case .modelNotFound(let path):
            return "Model file not found at path: '\(path)'."
        case .modelLoadingFailed(let reason):
            return "Failed to load model: \(reason)"
        case .conflictingOperation(let detail):
            return "Conflicting lifecycle operation: \(detail)"
        case .alreadyLoaded(let model):
            return "A model is already loaded ('\(model)'). Unload the current model before loading another."
        case .notLoaded:
            return "No model is currently loaded."
        case .workerUnavailable:
            return "The inference worker is shut down or unavailable."
        case .backendInitializationFailed(let reason):
            return "Failed to initialize native backend: \(reason)"
        case .invalidPrompt(let reason):
            return "Invalid prompt: \(reason)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .contextInitializationFailed(let reason):
            return "Failed to initialize context: \(reason)"
        case .contextExhausted(let promptTokens, let maxContext):
            return "Context exhausted: prompt has \(promptTokens) tokens, context size is \(maxContext)."
        case .tokenizationFailed(let reason):
            return "Tokenization failed: \(reason)"
        case .decodeFailed(let code, let description):
            return "Decode failed with code \(code): \(description)"
        case .cancelled:
            return "Generation was cancelled."
        }
    }
}
