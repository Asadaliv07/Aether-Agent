import Foundation

/// Represents a persistent or discovered model in Aether's local catalog.
public struct ModelRecord: Sendable, Identifiable, Equatable {
    /// Stable catalog UUID.
    public let id: UUID

    /// Human-readable display name.
    public var name: String

    /// Canonical filesystem path to the model file.
    public var filePath: String

    /// File size in bytes on disk.
    public let fileSize: Int64

    /// Model architecture identifier (e.g. "qwen2", "llama", "mistral", "gemma").
    public let architecture: String

    /// Quantization format description (e.g. "Q4_K_M", "Q8_0", "F16").
    public let quantization: String

    /// Maximum training context length reported by GGUF metadata.
    public let contextLength: Int

    /// Estimated or reported parameter count, if known.
    public let parameterCount: Int64?

    /// Date the model was added to Aether's catalog.
    public let createdAt: Date

    /// Date the model was last selected or loaded for inference.
    public var lastUsedAt: Date?

    /// Optional security-scoped bookmark data for App Sandbox persistence.
    public var bookmarkData: Data?

    /// Runtime availability status: whether the file exists and is accessible.
    public var isMissing: Bool

    /// Model compatibility assessment.
    public var compatibilityStatus: ModelCompatibility

    public init(
        id: UUID = UUID(),
        name: String,
        filePath: String,
        fileSize: Int64,
        architecture: String,
        quantization: String,
        contextLength: Int,
        parameterCount: Int64? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        bookmarkData: Data? = nil,
        isMissing: Bool = false,
        compatibilityStatus: ModelCompatibility = .compatible
    ) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.fileSize = fileSize
        self.architecture = architecture
        self.quantization = quantization
        self.contextLength = contextLength
        self.parameterCount = parameterCount
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.bookmarkData = bookmarkData
        self.isMissing = isMissing
        self.compatibilityStatus = compatibilityStatus
    }

    /// Formatted file size string for UI presentation.
    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Formatted parameter count string (e.g. "7B", "1.5B").
    public var formattedParameterCount: String? {
        guard let count = parameterCount, count > 0 else { return nil }
        if count >= 1_000_000_000 {
            let billions = Double(count) / 1_000_000_000.0
            return String(format: "%.1fB", billions)
        } else if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000.0
            return String(format: "%.1fM", millions)
        }
        return "\(count)"
    }

    /// Human-readable, normalized display title for catalog, UI cards, and chat selection.
    public var displayName: String {
        ModelCatalogNormalizer.normalize(installedName: name, filePath: filePath, architecture: architecture)
    }

    /// Detected or verified parameter scale (e.g. "7B", "3B").
    public var parameterScale: String? {
        if let params = formattedParameterCount {
            return params
        }
        return ModelCatalogNormalizer.extractParameterScale(from: "\(name) \(filePath)")
    }

    /// Inferred model capability category.
    public var category: ModelCategory {
        ModelCatalogNormalizer.extractModelCategory(tags: [], name: "\(name) \(filePath)", pipelineTag: nil)
    }
}

/// Model compatibility status with the current hardware and inference backend.
public enum ModelCompatibility: Sendable, Equatable {
    /// Fully compatible and ready for loading.
    case compatible

    /// Architecture is not supported by the pinned llama.cpp backend.
    case unsupportedArchitecture(String)

    /// GGUF header is corrupt or truncated.
    case corruptHeader(String)

    /// Model size exceeds recommended thresholds for the system's memory tier.
    case memoryWarning(String)

    /// Compatibility cannot be determined (e.g. file size or architecture unknown before download).
    case unknown(String)

    public var isUsable: Bool {
        switch self {
        case .compatible, .memoryWarning:
            return true
        case .unsupportedArchitecture, .corruptHeader, .unknown:
            return false
        }
    }

    public var displayMessage: String? {
        switch self {
        case .compatible:
            return nil
        case .unsupportedArchitecture(let arch):
            return "Unsupported architecture: \(arch)"
        case .corruptHeader(let err):
            return "Corrupt GGUF: \(err)"
        case .memoryWarning(let warning):
            return "Memory warning: \(warning)"
        case .unknown(let reason):
            return "Compatibility unknown: \(reason)"
        }
    }
}

/// Detailed GGUF metadata parsed directly from file header.
public struct GGUFMetadata: Sendable, Equatable {
    public let architecture: String
    public let name: String
    public let quantization: String
    public let contextLength: Int
    public let blockCount: Int
    public let parameterCount: Int64?
    public let tensorCount: Int
    public let chatTemplate: String?
    public let license: String?
    public let headCount: Int?
    public let headCountKV: Int?
    public let embeddingLength: Int?
    public let keyLength: Int?

    public init(
        architecture: String,
        name: String,
        quantization: String,
        contextLength: Int,
        blockCount: Int = 0,
        parameterCount: Int64? = nil,
        tensorCount: Int = 0,
        chatTemplate: String? = nil,
        license: String? = nil,
        headCount: Int? = nil,
        headCountKV: Int? = nil,
        embeddingLength: Int? = nil,
        keyLength: Int? = nil
    ) {
        self.architecture = architecture
        self.name = name
        self.quantization = quantization
        self.contextLength = contextLength
        self.blockCount = blockCount
        self.parameterCount = parameterCount
        self.tensorCount = tensorCount
        self.chatTemplate = chatTemplate
        self.license = license
        self.headCount = headCount
        self.headCountKV = headCountKV
        self.embeddingLength = embeddingLength
        self.keyLength = keyLength
    }
}

/// Supported KV cache precision types.
public enum KVCacheDataType: String, Sendable, CaseIterable {
    case f16 = "f16"
    case q8_0 = "q8_0"
    case q4_0 = "q4_0"
    case f32 = "f32"

    /// Returns the approximate bytes per element for the given KV cache type.
    public var bytesPerElement: Double {
        switch self {
        case .f32: return 4.0
        case .f16: return 2.0
        case .q8_0: return 1.0625 // ggml 34 bytes per 32-value block
        case .q4_0: return 0.5625 // ggml 18 bytes per 32-value block
        }
    }
}

/// Structured breakdown of estimated runtime memory demand for a model.
public struct RuntimeMemoryEstimate: Sendable, Equatable {
    public let weightBytes: Int64
    public let kvCacheBytes: Int64
    public let computeBufferBytes: Int64
    public let applicationReserveBytes: Int64
    public let systemReserveBytes: Int64
    public let totalDemandBytes: Int64
    public let effectiveHeadroomBytes: Int64
    public let isCompatible: Bool
    public let warningReason: String?

    public init(
        weightBytes: Int64,
        kvCacheBytes: Int64,
        computeBufferBytes: Int64,
        applicationReserveBytes: Int64,
        systemReserveBytes: Int64,
        totalDemandBytes: Int64,
        effectiveHeadroomBytes: Int64,
        isCompatible: Bool,
        warningReason: String? = nil
    ) {
        self.weightBytes = weightBytes
        self.kvCacheBytes = kvCacheBytes
        self.computeBufferBytes = computeBufferBytes
        self.applicationReserveBytes = applicationReserveBytes
        self.systemReserveBytes = systemReserveBytes
        self.totalDemandBytes = totalDemandBytes
        self.effectiveHeadroomBytes = effectiveHeadroomBytes
        self.isCompatible = isCompatible
        self.warningReason = warningReason
    }
}

/// Errors occurring during model catalog and GGUF inspection operations.
public enum ModelLibraryError: LocalizedError, Equatable {
    case fileNotFound(String)
    case unreadableFile(String)
    case invalidGGUF(String)
    case unsupportedArchitecture(String)
    case duplicateModel(path: String)
    case modelNotFoundInCatalog(UUID)
    case accessDenied(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Model file not found at path: \(path)"
        case .unreadableFile(let path):
            return "Unable to read model file: \(path)"
        case .invalidGGUF(let reason):
            return "Invalid GGUF file: \(reason)"
        case .unsupportedArchitecture(let arch):
            return "Unsupported model architecture: '\(arch)'. Pinned llama.cpp backend does not support this format."
        case .duplicateModel(let path):
            return "A model file with path '\(path)' is already registered in the library."
        case .modelNotFoundInCatalog(let id):
            return "Model with ID \(id) not found in library catalog."
        case .accessDenied(let reason):
            return "Access to model file denied: \(reason)"
        }
    }
}
