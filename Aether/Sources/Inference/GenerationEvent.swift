import Foundation

/// Explicit events emitted during incremental text generation.
public enum GenerationEvent: Sendable, Equatable {
    /// A non-empty, valid UTF-8 piece of generated text.
    case chunk(String)

    /// Generation completed successfully (e.g., end-of-generation reached or token budget exhausted).
    case completed

    /// Generation was cancelled cooperatively by consumer or coordinator.
    case cancelled

    /// Generation failed with an unrecoverable error.
    case failed(InferenceError)
}
