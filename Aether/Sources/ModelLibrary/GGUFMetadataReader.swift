import Foundation
import llama

/// Thread-safe reader for extracting metadata from local GGUF model files.
///
/// Performance Guarantee:
/// Uses native `llama.framework` `gguf_init_from_file` with `params.no_alloc = true`.
/// Header and key-value metadata are read directly from memory-mapped header pages
/// without allocating or loading model weight tensors into memory. Execution completes in < 2ms.
public final class GGUFMetadataReader: Sendable {

    public init() {}

    /// Reads and parses GGUF metadata from the specified filesystem path.
    ///
    /// - Parameter path: The canonical path to a local `.gguf` file.
    /// - Returns: Parsed `GGUFMetadata` containing architecture, quantization, context length, etc.
    /// - Throws: `ModelLibraryError` if the file is missing, corrupt, or lacks essential GGUF headers.
    public func readMetadata(at path: String) throws -> GGUFMetadata {
        // 1. Filesystem existence & basic validation
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ModelLibraryError.fileNotFound(path)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDir) else {
            throw ModelLibraryError.fileNotFound(trimmedPath)
        }

        guard !isDir.boolValue else {
            throw ModelLibraryError.invalidGGUF("Path is a directory, expected regular GGUF file: '\(trimmedPath)'")
        }

        // 2. Validate magic bytes before invoking native parser
        try validateGGUFMagic(at: trimmedPath)

        // 3. Initialize native GGUF context with zero tensor allocation
        var params = gguf_init_params(no_alloc: true, ctx: nil)
        guard let ctx = gguf_init_from_file(trimmedPath, params) else {
            throw ModelLibraryError.invalidGGUF("Failed to initialize GGUF context from '\(trimmedPath)'")
        }
        defer {
            gguf_free(ctx)
        }

        // 4. Extract required architecture
        guard let architecture = getGGUFString(ctx: ctx, key: "general.architecture") else {
            throw ModelLibraryError.invalidGGUF("Missing required 'general.architecture' metadata key.")
        }

        // 5. Extract optional / derived metadata
        let name = getGGUFString(ctx: ctx, key: "general.name") ?? (trimmedPath as NSString).lastPathComponent
        let contextLength = getGGUFUInt(ctx: ctx, key: "\(architecture).context_length")
            ?? getGGUFUInt(ctx: ctx, key: "llama.context_length")
            ?? 2048
        let blockCount = getGGUFUInt(ctx: ctx, key: "\(architecture).block_count")
            ?? getGGUFUInt(ctx: ctx, key: "llama.block_count")
            ?? 0

        let fileTypeInt = getGGUFUInt(ctx: ctx, key: "general.file_type")
        let quantizationStr = Self.quantizationName(for: fileTypeInt)

        let paramCount = getGGUFUInt(ctx: ctx, key: "general.parameter_count")
        let tensorCount = Int(gguf_get_n_tensors(ctx))
        let chatTemplate = getGGUFString(ctx: ctx, key: "tokenizer.chat_template")
        let license = getGGUFString(ctx: ctx, key: "general.license")

        let headCount = getGGUFUInt(ctx: ctx, key: "\(architecture).attention.head_count")
            ?? getGGUFUInt(ctx: ctx, key: "llama.attention.head_count")
        let headCountKV = getGGUFUInt(ctx: ctx, key: "\(architecture).attention.head_count_kv")
            ?? getGGUFUInt(ctx: ctx, key: "llama.attention.head_count_kv")
        let embeddingLength = getGGUFUInt(ctx: ctx, key: "\(architecture).embedding_length")
            ?? getGGUFUInt(ctx: ctx, key: "llama.embedding_length")
        let keyLength = getGGUFUInt(ctx: ctx, key: "\(architecture).attention.key_length")
            ?? getGGUFUInt(ctx: ctx, key: "llama.attention.key_length")

        return GGUFMetadata(
            architecture: architecture,
            name: name,
            quantization: quantizationStr,
            contextLength: Int(contextLength),
            blockCount: Int(blockCount),
            parameterCount: paramCount.map { Int64($0) },
            tensorCount: tensorCount,
            chatTemplate: chatTemplate,
            license: license,
            headCount: headCount.map { Int($0) },
            headCountKV: headCountKV.map { Int($0) },
            embeddingLength: embeddingLength.map { Int($0) },
            keyLength: keyLength.map { Int($0) }
        )
    }

    // MARK: - Runtime Memory Budgeting & Safety (DEF-39-04)

    /// Estimates the total runtime memory demand for a model, accounting for weights,
    /// KV cache allocation, compute graph buffers, and system/application headroom.
    public static func estimateRuntimeMemory(
        metadata: GGUFMetadata,
        fileSize: Int64,
        targetContextLength: Int? = nil,
        cacheType: KVCacheDataType = .f16,
        hostRAM: UInt64? = nil
    ) -> RuntimeMemoryEstimate {
        let totalRAM = hostRAM ?? ProcessInfo.processInfo.physicalMemory

        // Guard against invalid or overflow inputs
        let safeFileSize = max(0, fileSize)
        let effectiveCtx = targetContextLength ?? (metadata.contextLength > 0 ? metadata.contextLength : 2048)
        let safeCtx = max(1, effectiveCtx)

        // 1. Weight bytes
        let weightBytes = safeFileSize

        // 2. KV cache bytes:
        // Formula: 2 * n_layers * n_head_kv * d_head * bytes_per_element * n_ctx
        // Defaults if metadata absent: 32 layers, 8 kv heads, 128 head dim
        let layers = metadata.blockCount > 0 ? metadata.blockCount : 32
        let kvHeads = metadata.headCountKV ?? metadata.headCount ?? 8
        let headDim: Int
        if let keyLen = metadata.keyLength, keyLen > 0 {
            headDim = keyLen
        } else if let embd = metadata.embeddingLength, let heads = metadata.headCount, heads > 0 {
            headDim = max(1, embd / heads)
        } else {
            headDim = 128
        }

        // Use overflow-safe arithmetic for KV cache
        let bytesPerToken = 2.0 * Double(layers) * Double(kvHeads) * Double(headDim) * cacheType.bytesPerElement
        let kvCacheBytes: Int64
        if bytesPerToken.isFinite && !bytesPerToken.isNaN && Double(safeCtx) * bytesPerToken < Double(Int64.max / 2) {
            kvCacheBytes = Int64(Double(safeCtx) * bytesPerToken)
        } else {
            kvCacheBytes = Int64.max / 4
        }

        // 3. Compute buffer overhead:
        // In llama.cpp sched_reserve, activation buffers for prompt processing worst-case:
        // min(n_ctx, n_batch) * n_embd * sizeof(float) * pipeline_factor
        let computeBufferBytes = estimateComputeBufferBytes(contextLength: safeCtx, hiddenDim: metadata.embeddingLength ?? 4096)

        // 4. Application reserve
        let appReserve: Int64 = 200 * 1024 * 1024 // 200 MiB

        // 5. System reserve (macOS kernel, WindowServer, system daemons)
        let sysReserve = systemReserveBytes(for: totalRAM)

        // 6. Total demand (saturating to prevent overflow wrapping to negative)
        let rawDemand = Double(weightBytes) + Double(kvCacheBytes) + Double(computeBufferBytes) + Double(appReserve)
        let totalDemand: Int64
        if rawDemand >= Double(Int64.max) || rawDemand.isNaN || !rawDemand.isFinite {
            totalDemand = Int64.max
        } else {
            totalDemand = Int64(rawDemand)
        }

        // 7. Headroom
        let safeHostRAM: Int64 = totalRAM > UInt64(Int64.max) ? Int64.max : Int64(totalRAM)
        let effectiveCapacity = max(0, safeHostRAM &- sysReserve)
        let isCompatible = totalDemand <= effectiveCapacity

        let warningReason: String?
        if !isCompatible {
            let demandGB = String(format: "%.1f", Double(totalDemand) / (1024 * 1024 * 1024))
            let capGB = String(format: "%.1f", Double(effectiveCapacity) / (1024 * 1024 * 1024))
            let ramGB = Int(round(Double(totalRAM) / (1024 * 1024 * 1024)))
            warningReason = "Estimated runtime memory demand (\(demandGB) GB) exceeds conservative budget (\(capGB) GB) on \(ramGB) GB systems."
        } else {
            warningReason = nil
        }

        return RuntimeMemoryEstimate(
            weightBytes: weightBytes,
            kvCacheBytes: kvCacheBytes,
            computeBufferBytes: computeBufferBytes,
            applicationReserveBytes: appReserve,
            systemReserveBytes: sysReserve,
            totalDemandBytes: totalDemand,
            effectiveHeadroomBytes: effectiveCapacity,
            isCompatible: isCompatible,
            warningReason: warningReason
        )
    }

    /// Estimates compute buffer requirements for the worst-case prompt evaluation batch.
    public static func estimateComputeBufferBytes(contextLength: Int, batchSize: Int = 512, hiddenDim: Int = 4096) -> Int64 {
        let tokens = max(1, min(contextLength, batchSize))
        let dim = max(1, hiddenDim)
        // ~4 intermediate buffers in graph (attention QK, V projection, FFN, logits)
        let rawActivation = Double(tokens) * Double(dim) * 16.0
        let minReservation: Double = 250 * 1024 * 1024 // 250 MiB minimum
        let maxReservation: Double = 750 * 1024 * 1024 // 750 MiB cap
        let bounded = max(minReservation, min(rawActivation, maxReservation))
        return Int64(bounded)
    }

    /// Returns the conservative macOS system reserve for the specified physical RAM tier.
    public static func systemReserveBytes(for totalRAM: UInt64) -> Int64 {
        let gigabytes = Double(totalRAM) / (1024 * 1024 * 1024)
        if gigabytes <= 9.0 {
            // 8 GB Apple Silicon tier: 3.0 GB reserved for macOS
            return Int64(3.0 * 1024 * 1024 * 1024)
        } else if gigabytes <= 17.0 {
            // 16 GB Apple Silicon tier: 4.5 GB reserved for macOS
            return Int64(4.5 * 1024 * 1024 * 1024)
        } else {
            // 24 GB+ systems: 5.5 GB reserved for macOS
            return Int64(5.5 * 1024 * 1024 * 1024)
        }
    }

    /// Evaluates compatibility of extracted metadata against the pinned inference backend and memory budget.
    public func evaluateCompatibility(
        metadata: GGUFMetadata,
        fileSize: Int64,
        targetContextLength: Int? = nil,
        cacheType: KVCacheDataType = .f16,
        hostRAM: UInt64? = nil
    ) -> ModelCompatibility {
        let arch = metadata.architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !arch.isEmpty else {
            return .unknown("Architecture is unverified or missing")
        }

        guard Self.supportedArchitectures.contains(arch) else {
            return .unsupportedArchitecture(metadata.architecture)
        }

        guard metadata.tensorCount > 0 else {
            return .unknown("Model tensor metadata is missing or invalid")
        }

        guard fileSize > 0 else {
            return .unknown("File size unknown or non-positive; memory requirements cannot be evaluated")
        }

        // Memory tier budget evaluation
        let estimate = Self.estimateRuntimeMemory(
            metadata: metadata,
            fileSize: fileSize,
            targetContextLength: targetContextLength,
            cacheType: cacheType,
            hostRAM: hostRAM
        )

        if !estimate.isCompatible, let warning = estimate.warningReason {
            return .memoryWarning(warning)
        }

        return .compatible
    }

    // MARK: - Private Helpers

    private func validateGGUFMagic(at path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ModelLibraryError.unreadableFile(path)
        }
        defer {
            try? handle.close()
        }

        guard let magicData = try? handle.read(upToCount: 4), magicData.count == 4 else {
            throw ModelLibraryError.invalidGGUF("File is truncated or smaller than 4 bytes.")
        }

        let magicString = String(data: magicData, encoding: .ascii)
        guard magicString == "GGUF" else {
            throw ModelLibraryError.invalidGGUF("Magic header mismatch: expected 'GGUF', found '\(magicString ?? "unknown")'")
        }
    }

    private func getGGUFString(ctx: OpaquePointer, key: String) -> String? {
        let keyIdx = gguf_find_key(ctx, key)
        guard keyIdx >= 0 else { return nil }
        guard gguf_get_kv_type(ctx, keyIdx) == GGUF_TYPE_STRING else { return nil }
        guard let cStr = gguf_get_val_str(ctx, keyIdx) else { return nil }
        return String(cString: cStr)
    }

    private func getGGUFUInt(ctx: OpaquePointer, key: String) -> UInt64? {
        let keyIdx = gguf_find_key(ctx, key)
        guard keyIdx >= 0 else { return nil }
        let type = gguf_get_kv_type(ctx, keyIdx)
        switch type {
        case GGUF_TYPE_UINT32:
            return UInt64(gguf_get_val_u32(ctx, keyIdx))
        case GGUF_TYPE_INT32:
            let val = gguf_get_val_i32(ctx, keyIdx)
            return val >= 0 ? UInt64(val) : nil
        case GGUF_TYPE_UINT64:
            return gguf_get_val_u64(ctx, keyIdx)
        case GGUF_TYPE_INT64:
            let val = gguf_get_val_i64(ctx, keyIdx)
            return val >= 0 ? UInt64(val) : nil
        default:
            return nil
        }
    }

    // MARK: - Quantization Mapping

    public static func quantizationName(for fileType: UInt64?) -> String {
        guard let ft = fileType else { return "Unknown" }
        switch ft {
        case 0:  return "F32"
        case 1:  return "F16"
        case 2:  return "Q4_0"
        case 3:  return "Q4_1"
        case 7:  return "Q8_0"
        case 8:  return "Q5_0"
        case 9:  return "Q5_1"
        case 10: return "Q2_K"
        case 11: return "Q3_K_S"
        case 12: return "Q3_K_M"
        case 13: return "Q3_K_L"
        case 14: return "Q4_K_S"
        case 15: return "Q4_K_M"
        case 16: return "Q5_K_S"
        case 17: return "Q5_K_M"
        case 18: return "Q6_K"
        case 19: return "IQ2_XXS"
        case 20: return "IQ2_XS"
        case 21: return "Q2_K_S"
        case 22: return "IQ3_XS"
        case 23: return "IQ3_XXS"
        case 24: return "IQ1_S"
        case 25: return "IQ4_NL"
        case 26: return "IQ3_S"
        case 27: return "IQ3_M"
        case 28: return "IQ2_S"
        case 29: return "IQ2_M"
        default: return "Type_\(ft)"
        }
    }

    // MARK: - Supported Architectures List (Pinned llama.cpp b11718)

    public static let supportedArchitectures: Set<String> = [
        "llama",
        "qwen",
        "qwen2",
        "qwen2moe",
        "qwen2vl",
        "qwen3",
        "gemma",
        "gemma2",
        "phi2",
        "phi3",
        "mistral",
        "deepseek",
        "deepseek2",
        "starcoder",
        "starcoder2",
        "bloom",
        "stablelm",
        "command-r",
        "command_r",
        "falcon",
        "baichuan",
        "gpt2",
        "gptj",
        "gptneox",
        "mpt",
        "bert",
        "nomic_bert",
        "jamba",
        "olmo",
        "olmo2",
        "arctic",
        "chatglm",
        "smollm3",
        "granite",
        "exaone",
        "bitnet"
    ]
}
