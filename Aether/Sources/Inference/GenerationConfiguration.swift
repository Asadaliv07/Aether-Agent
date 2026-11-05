import Foundation

/// Configuration parameters for local text generation.
public struct GenerationConfiguration: Sendable, Equatable {
    /// Context size (in tokens) allocated for prompt processing and generation.
    public var contextLength: UInt32

    /// Maximum number of tokens to generate.
    public var maxTokens: Int32

    /// Sampling temperature. A value of 0.0 specifies deterministic greedy sampling.
    public var temperature: Float

    /// Top-K sampling cutoff. Values <= 0 disable Top-K.
    public var topK: Int32

    /// Top-P nucleus sampling threshold. Values >= 1.0 disable Top-P.
    public var topP: Float

    /// Random number generator seed for stochastic sampling.
    public var seed: UInt32

    /// Optional system prompt containing persona or task instructions.
    public var systemPrompt: String?

    /// Optional list of stop sequences that halt generation when encountered.
    public var stopSequences: [String]

    public init(
        contextLength: UInt32 = 2048,
        maxTokens: Int32 = 256,
        temperature: Float = 0.0,
        topK: Int32 = 40,
        topP: Float = 0.95,
        seed: UInt32 = 1234,
        systemPrompt: String? = nil,
        stopSequences: [String] = []
    ) {
        self.contextLength = contextLength
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.seed = seed
        self.systemPrompt = systemPrompt
        self.stopSequences = stopSequences
    }

    /// Conservative default configuration (greedy, 2048 context, max 256 tokens).
    public static let `default` = GenerationConfiguration()

    /// Deterministic greedy sampling configuration.
    public static let deterministic = GenerationConfiguration(temperature: 0.0)

    /// Creative sampling configuration with mild temperature and Top-P.
    public static let creative = GenerationConfiguration(temperature: 0.7, topP: 0.9)

    /// Validates parameter ranges before native execution.
    public func validate() throws {
        guard contextLength > 0 else {
            throw InferenceError.invalidConfiguration("contextLength must be greater than zero.")
        }
        guard maxTokens > 0 else {
            throw InferenceError.invalidConfiguration("maxTokens must be greater than zero.")
        }
        guard temperature >= 0.0 else {
            throw InferenceError.invalidConfiguration("temperature must be non-negative.")
        }
        guard topP > 0.0 && topP <= 1.0 else {
            throw InferenceError.invalidConfiguration("topP must be in (0.0, 1.0].")
        }
        if let systemPrompt {
            guard systemPrompt.count <= 32_768 else {
                throw InferenceError.invalidConfiguration("systemPrompt exceeds maximum supported length (32KB).")
            }
        }
        guard stopSequences.count <= 8 else {
            throw InferenceError.invalidConfiguration("stopSequences count must not exceed 8.")
        }
        for seq in stopSequences {
            guard !seq.isEmpty else {
                throw InferenceError.invalidConfiguration("stopSequences must not contain empty strings.")
            }
            guard seq.count <= 64 else {
                throw InferenceError.invalidConfiguration("stopSequence '\(seq)' exceeds maximum length of 64 characters.")
            }
        }
    }
}
