import Foundation

// MARK: - Model Task Type & Categories

/// The primary functional capability or task category of an AI model.
public enum ModelTaskType: String, Sendable, CaseIterable, Identifiable, Codable {
    case generalChat = "General Chat"
    case coding = "Coding"
    case reasoning = "Reasoning"
    case visionLanguage = "Vision & Multimodal"
    case embedding = "Embeddings"
    case speechToText = "Speech-to-Text"
    case textToSpeech = "Text-to-Speech"
    case imageGeneration = "Image Generation"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .generalChat: return "bubble.left.and.bubble.right"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .reasoning: return "brain.head.profile"
        case .visionLanguage: return "eye"
        case .embedding: return "point.3.connected.trianglepath.dotted"
        case .speechToText: return "mic"
        case .textToSpeech: return "speaker.wave.2"
        case .imageGeneration: return "photo.artframe"
        }
    }

    public var description: String {
        switch self {
        case .generalChat: return "Conversational dialogue, roleplay, instruction following, and general knowledge."
        case .coding: return "Code generation, debugging, refactoring, and multi-language software engineering."
        case .reasoning: return "Complex step-by-step logic, math problem-solving, and deliberate thinking."
        case .visionLanguage: return "Image understanding, visual question answering, and OCR."
        case .embedding: return "Text vector embeddings for semantic search, RAG, and classification."
        case .speechToText: return "Audio transcription and automatic speech recognition."
        case .textToSpeech: return "High-fidelity synthetic voice and audio waveform generation."
        case .imageGeneration: return "Text-to-image synthesis and diffusion generation."
        }
    }
}

// MARK: - Model Formats

/// Supported physical serialization formats for model weights.
public enum ModelFormat: String, Sendable, CaseIterable, Identifiable, Codable {
    case gguf = "GGUF"
    case safetensors = "Safetensors"
    case onnx = "ONNX"
    case coreml = "CoreML"
    case diffusers = "Diffusers"

    public var id: String { rawValue }

    public var displayName: String { rawValue }
}

// MARK: - Supported Inference Engines

/// The execution engine capable of running the specified model.
public enum SupportedInferenceEngine: String, Sendable, CaseIterable, Identifiable, Codable {
    case llamaCppMetal = "llama.cpp (Metal Accelerated)"
    case whisperCpp = "whisper.cpp"
    case stableDiffusionCpp = "stable-diffusion.cpp"
    case mlxCoreML = "MLX / CoreML"
    case externalEngine = "External Inference Server"

    public var id: String { rawValue }

    /// Indicates whether Aether's embedded Metal engine can directly load and execute this model natively.
    public var isLocallyNative: Bool {
        self == .llamaCppMetal
    }

    public var badgeLabel: String {
        switch self {
        case .llamaCppMetal: return "Metal Native"
        case .whisperCpp: return "Audio Engine"
        case .stableDiffusionCpp: return "Diffusion Engine"
        case .mlxCoreML: return "MLX / CoreML"
        case .externalEngine: return "External Server"
        }
    }
}

// MARK: - Compatibility Status

/// Compatibility evaluation with Aether's local runtime and the user's host hardware.
public enum ModelCompatibilityStatus: Sendable, Equatable {
    case compatible
    case requiresSpecializedEngine(SupportedInferenceEngine)
    case memoryWarning(String)
    case incompatible(String)

    public var isExecutableLocally: Bool {
        switch self {
        case .compatible, .memoryWarning:
            return true
        case .requiresSpecializedEngine, .incompatible:
            return false
        }
    }

    public var badgeLabel: String {
        switch self {
        case .compatible:
            return "Fully Compatible"
        case .requiresSpecializedEngine(let engine):
            return "Requires \(engine.badgeLabel)"
        case .memoryWarning:
            return "High RAM Demand"
        case .incompatible:
            return "Incompatible"
        }
    }
}

// MARK: - Hardware Requirements

/// Hardware resource requirements estimated or declared for running a model.
public struct ModelHardwareRequirements: Sendable, Codable, Equatable {
    public let minimumRAMBytes: UInt64
    public let recommendedRAMBytes: UInt64
    public let recommendedSiliconTier: String
    public let supportsMetalGPU: Bool

    public init(
        minimumRAMBytes: UInt64,
        recommendedRAMBytes: UInt64,
        recommendedSiliconTier: String,
        supportsMetalGPU: Bool = true
    ) {
        self.minimumRAMBytes = minimumRAMBytes
        self.recommendedRAMBytes = recommendedRAMBytes
        self.recommendedSiliconTier = recommendedSiliconTier
        self.supportsMetalGPU = supportsMetalGPU
    }

    public var minimumRAMFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(minimumRAMBytes), countStyle: .memory)
    }

    public var recommendedRAMFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(recommendedRAMBytes), countStyle: .memory)
    }
}

// MARK: - Quantization Variants

/// An individual quantization variant available for a model.
public struct ModelQuantizationVariant: Sendable, Identifiable, Equatable {
    public var id: String { "\(filename)-\(quantization)" }
    public let quantization: String
    public let filename: String
    public let size: Int64
    public let bitDepth: Int?
    public let downloadURL: URL
    public let qualityDescription: String
    public let memoryRequirementBytes: UInt64

    public init(
        quantization: String,
        filename: String,
        size: Int64,
        bitDepth: Int?,
        downloadURL: URL,
        qualityDescription: String,
        memoryRequirementBytes: UInt64
    ) {
        self.quantization = quantization
        self.filename = filename
        self.size = size
        self.bitDepth = bitDepth
        self.downloadURL = downloadURL
        self.qualityDescription = qualityDescription
        self.memoryRequirementBytes = memoryRequirementBytes
    }

    public var formattedSize: String {
        guard size > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var bitDepthLabel: String? {
        guard let bitDepth else { return nil }
        return "\(bitDepth)-bit"
    }
}

// MARK: - Comprehensive Model Metadata Record (Phase 2 - 22 Fields)

/// Structured model metadata holding all 22 required fields for the AI Model Hub.
public struct ComprehensiveModelMetadata: Sendable, Identifiable, Equatable {
    // 1. Official model name
    public let officialName: String
    // 2. Human-readable display name
    public let displayName: String
    // 3. Official publisher or developer
    public let publisher: String
    // 4. Model family
    public let modelFamily: String
    // 5. Model architecture
    public let architecture: String
    // 6. Parameter count
    public let parameterCount: String
    // 7. Model version
    public let modelVersion: String
    // 8. Model description
    public let description: String
    // 9. Primary capabilities
    public let primaryCapabilities: [String]
    // 10. Supported languages
    public let supportedLanguages: [String]
    // 11. Context window
    public let contextWindow: Int
    // 12. Model format
    public let modelFormat: ModelFormat
    // 13. Quantization format
    public let defaultQuantization: String
    // 14. Download size
    public let estimatedDownloadSize: Int64
    // 15. Repository identifier
    public let repositoryId: String
    // 16. Official source link
    public let officialSourceURL: URL
    // 17. License
    public let license: String
    // 18. Hardware requirements
    public let hardwareRequirements: ModelHardwareRequirements
    // 19. Supported inference engines
    public let supportedInferenceEngines: [SupportedInferenceEngine]
    // 20. Compatibility status
    public let compatibilityStatus: ModelCompatibilityStatus
    // 21. Model task type
    public let taskType: ModelTaskType
    // 22. Last metadata verification date
    public let lastVerificationDate: Date

    // Additional structured properties
    public let availableQuantizations: [ModelQuantizationVariant]
    public let isPopular: Bool
    public let downloads: Int
    public let likes: Int

    public var id: String { repositoryId }

    public init(
        officialName: String,
        displayName: String,
        publisher: String,
        modelFamily: String,
        architecture: String,
        parameterCount: String,
        modelVersion: String,
        description: String,
        primaryCapabilities: [String],
        supportedLanguages: [String],
        contextWindow: Int,
        modelFormat: ModelFormat = .gguf,
        defaultQuantization: String,
        estimatedDownloadSize: Int64,
        repositoryId: String,
        officialSourceURL: URL,
        license: String,
        hardwareRequirements: ModelHardwareRequirements,
        supportedInferenceEngines: [SupportedInferenceEngine],
        compatibilityStatus: ModelCompatibilityStatus = .compatible,
        taskType: ModelTaskType,
        lastVerificationDate: Date,
        availableQuantizations: [ModelQuantizationVariant] = [],
        isPopular: Bool = false,
        downloads: Int = 0,
        likes: Int = 0
    ) {
        self.officialName = officialName
        self.displayName = displayName
        self.publisher = publisher
        self.modelFamily = modelFamily
        self.architecture = architecture
        self.parameterCount = parameterCount
        self.modelVersion = modelVersion
        self.description = description
        self.primaryCapabilities = primaryCapabilities
        self.supportedLanguages = supportedLanguages
        self.contextWindow = contextWindow
        self.modelFormat = modelFormat
        self.defaultQuantization = defaultQuantization
        self.estimatedDownloadSize = estimatedDownloadSize
        self.repositoryId = repositoryId
        self.officialSourceURL = officialSourceURL
        self.license = license
        self.hardwareRequirements = hardwareRequirements
        self.supportedInferenceEngines = supportedInferenceEngines
        self.compatibilityStatus = compatibilityStatus
        self.taskType = taskType
        self.lastVerificationDate = lastVerificationDate
        self.availableQuantizations = availableQuantizations
        self.isPopular = isPopular
        self.downloads = downloads
        self.likes = likes
    }

    public var formattedSize: String {
        guard estimatedDownloadSize > 0 else { return "Size varies by quant" }
        return ByteCountFormatter.string(fromByteCount: estimatedDownloadSize, countStyle: .file)
    }

    public var formattedContextWindow: String {
        if contextWindow >= 1024 {
            let k = contextWindow / 1024
            return "\(k)k tokens"
        }
        return "\(contextWindow) tokens"
    }

    public var formattedDownloads: String {
        if downloads >= 1_000_000 {
            return String(format: "%.1fM", Double(downloads) / 1_000_000.0)
        } else if downloads >= 1_000 {
            return String(format: "%.1fk", Double(downloads) / 1_000.0)
        }
        return "\(downloads)"
    }
}

// MARK: - Model Hub Category & Sort Options

/// Categories for navigation in the Model Hub.
public enum HubCategory: String, Sendable, CaseIterable, Identifiable {
    case all = "All Models"
    case popular = "Popular"
    case recentlyUpdated = "Recently Updated"
    case generalChat = "General Chat"
    case reasoning = "Reasoning"
    case coding = "Coding"
    case vision = "Vision & Multimodal"
    case embeddings = "Embeddings"
    case audio = "Audio & Speech"
    case imageGen = "Image Generation"
    case small = "Small (<4B)"
    case medium = "Medium (4B–14B)"
    case large = "Large (>14B)"
    case installed = "Installed Models"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .popular: return "flame"
        case .recentlyUpdated: return "clock.arrow.circlepath"
        case .generalChat: return "bubble.left.and.bubble.right"
        case .reasoning: return "brain.head.profile"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .vision: return "eye"
        case .embeddings: return "point.3.connected.trianglepath.dotted"
        case .audio: return "waveform"
        case .imageGen: return "photo.artframe"
        case .small: return "bolt"
        case .medium: return "cpu"
        case .large: return "server.rack"
        case .installed: return "checkmark.circle"
        }
    }
}

/// Sort criteria for the Model Hub.
public enum HubSortOption: String, Sendable, CaseIterable, Identifiable {
    case mostPopular = "Most Popular"
    case recentlyUpdated = "Recently Updated"
    case recentlyAdded = "Recently Added"
    case smallestSize = "Smallest Size"
    case largestSize = "Largest Size"
    case alphabetical = "Alphabetical (A-Z)"
    case bestCompatibility = "Best for this Mac"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .mostPopular: return "flame"
        case .recentlyUpdated: return "clock"
        case .recentlyAdded: return "sparkles"
        case .smallestSize: return "arrow.down"
        case .largestSize: return "arrow.up"
        case .alphabetical: return "textformat"
        case .bestCompatibility: return "apple.logo"
        }
    }
}

