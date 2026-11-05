import Foundation

/// Configuration options for loading a model into memory.
public struct ModelConfiguration: Sendable, Equatable {
    /// Number of layers to offload to the Metal GPU. A value of -1 offloads all layers.
    public let gpuLayers: Int32

    /// Whether to memory-map the model file for on-demand paging.
    public let useMmap: Bool

    /// Whether to lock model pages into physical RAM to prevent swapping.
    public let useMlock: Bool

    /// Whether to validate tensor headers and checksums upon loading.
    public let checkTensors: Bool

    public init(
        gpuLayers: Int32 = -1,
        useMmap: Bool = true,
        useMlock: Bool = false,
        checkTensors: Bool = false
    ) {
        self.gpuLayers = gpuLayers
        self.useMmap = useMmap
        self.useMlock = useMlock
        self.checkTensors = checkTensors
    }

    /// Conservative configuration tailored for baseline Apple Silicon operation.
    public static let conservative = ModelConfiguration(
        gpuLayers: -1,
        useMmap: true,
        useMlock: false,
        checkTensors: false
    )
}

/// Metadata describing a loaded model.
public struct ModelInfo: Sendable, Equatable {
    /// The canonical filesystem path to the model file.
    public let path: String

    /// The human-readable name of the model (derived from filename or metadata).
    public let name: String

    /// The size of the model file on disk in bytes.
    public let sizeInBytes: Int64

    /// The architecture or format description reported by llama.cpp.
    public let description: String

    public init(
        path: String,
        name: String,
        sizeInBytes: Int64,
        description: String
    ) {
        self.path = path
        self.name = name
        self.sizeInBytes = sizeInBytes
        self.description = description
    }
}

/// Explicit lifecycle states for the inference service.
public enum InferenceState: Sendable, Equatable, CustomStringConvertible {
    /// No model is loaded; native engine is idle and resources are freed.
    case unloaded

    /// A model is actively being loaded from the specified path.
    case loading(path: String)

    /// A model is loaded in memory and ready for downstream operations.
    case loaded(modelInfo: ModelInfo)

    /// A text generation operation is actively in progress.
    case generating(modelInfo: ModelInfo)

    /// The active model is actively being unloaded and resources freed.
    case unloading

    /// The last lifecycle operation failed with an error description.
    case failed(errorDescription: String)

    public var description: String {
        switch self {
        case .unloaded:
            return "Unloaded"
        case .loading(let path):
            return "Loading (\(path))"
        case .loaded(let info):
            return "Loaded: \(info.name)"
        case .generating(let info):
            return "Generating: \(info.name)"
        case .unloading:
            return "Unloading"
        case .failed(let err):
            return "Failed: \(err)"
        }
    }
}
