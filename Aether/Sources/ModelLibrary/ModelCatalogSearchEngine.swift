import Foundation

// MARK: - Search & Filter Engine for the Model Hub

/// Search and filtering coordinator for the AI Model Hub.
public final class ModelCatalogSearchEngine: Sendable {
    public static let shared = ModelCatalogSearchEngine()

    private let baseRegistry: [ComprehensiveModelMetadata]

    public init(models: [ComprehensiveModelMetadata] = ModelCatalogRegistry.models) {
        self.baseRegistry = models
    }

    /// Filters and sorts models according to user criteria, category, search text, and device hardware.
    public func filterModels(
        category: HubCategory = .all,
        query: String = "",
        selectedFamily: String? = nil,
        selectedPublisher: String? = nil,
        selectedEngine: SupportedInferenceEngine? = nil,
        onlyLocallyNative: Bool = false,
        sort: HubSortOption = .mostPopular,
        installedRepoIds: Set<String> = [],
        additionalRemoteModels: [ComprehensiveModelMetadata] = [],
        profile: DeviceCapabilityProfile = DeviceCapabilityEngine.getProfile()
    ) -> [ComprehensiveModelMetadata] {
        // Merge base registry with any dynamically discovered remote models
        var combined = baseRegistry
        let existingIds = Set(combined.map { $0.repositoryId })
        for remote in additionalRemoteModels where !existingIds.contains(remote.repositoryId) {
            combined.append(remote)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return combined.filter { model in
            // 1. Category Filter
            if !matchesCategory(model: model, category: category, installedRepoIds: installedRepoIds) {
                return false
            }

            // 2. Query Search Filter
            if !trimmedQuery.isEmpty {
                if !matchesQuery(model: model, query: trimmedQuery) {
                    return false
                }
            }

            // 3. Family Filter
            if let selectedFamily, !selectedFamily.isEmpty, selectedFamily != "All" {
                if model.modelFamily.lowercased() != selectedFamily.lowercased() {
                    return false
                }
            }

            // 4. Publisher Filter
            if let selectedPublisher, !selectedPublisher.isEmpty, selectedPublisher != "All" {
                if model.publisher.lowercased() != selectedPublisher.lowercased() {
                    return false
                }
            }

            // 5. Engine Filter
            if let selectedEngine {
                if !model.supportedInferenceEngines.contains(selectedEngine) {
                    return false
                }
            }

            // 6. Locally Native Filter
            if onlyLocallyNative {
                let isNative = model.supportedInferenceEngines.contains(where: { $0.isLocallyNative })
                if !isNative {
                    return false
                }
            }

            return true
        }
        .sorted { a, b in
            sortModels(a: a, b: b, sort: sort, profile: profile)
        }
    }

    // MARK: - Category Matching

    private func matchesCategory(
        model: ComprehensiveModelMetadata,
        category: HubCategory,
        installedRepoIds: Set<String>
    ) -> Bool {
        switch category {
        case .all:
            return true
        case .popular:
            return model.isPopular || model.downloads > 1_000_000
        case .recentlyUpdated:
            return true
        case .generalChat:
            return model.taskType == .generalChat
        case .reasoning:
            return model.taskType == .reasoning
        case .coding:
            return model.taskType == .coding
        case .vision:
            return model.taskType == .visionLanguage
        case .embeddings:
            return model.taskType == .embedding
        case .audio:
            return model.taskType == .speechToText || model.taskType == .textToSpeech
        case .imageGen:
            return model.taskType == .imageGeneration
        case .small:
            return isSmallModel(model: model)
        case .medium:
            return isMediumModel(model: model)
        case .large:
            return isLargeModel(model: model)
        case .installed:
            return installedRepoIds.contains(model.repositoryId)
        }
    }

    private func isSmallModel(model: ComprehensiveModelMetadata) -> Bool {
        let p = model.parameterCount.lowercased()
        if p.contains("0.5b") || p.contains("1b") || p.contains("1.1b") || p.contains("1.2b") ||
           p.contains("1.5b") || p.contains("1.7b") || p.contains("2b") || p.contains("2.2b") ||
           p.contains("2.6b") || p.contains("3b") || p.contains("3.2b") || p.contains("3.4b") ||
           p.contains("3.8b") || p.contains("270m") || p.contains("450m") || p.contains("135m") ||
           p.contains("360m") || p.contains("335m") || p.contains("137m") || p.contains("74m") ||
           p.contains("350m") || p.contains("809m") {
            return true
        }
        return false
    }

    private func isMediumModel(model: ComprehensiveModelMetadata) -> Bool {
        let p = model.parameterCount.lowercased()
        if p.contains("7b") || p.contains("7.2b") || p.contains("7.6b") || p.contains("7.7b") ||
           p.contains("8b") || p.contains("8.8b") || p.contains("9b") || p.contains("9.2b") ||
           p.contains("11b") || p.contains("12b") || p.contains("12.4b") || p.contains("13b") ||
           p.contains("14b") || p.contains("14.7b") || p.contains("15b") || p.contains("16b") {
            return true
        }
        return false
    }

    private func isLargeModel(model: ComprehensiveModelMetadata) -> Bool {
        let p = model.parameterCount.lowercased()
        if p.contains("20b") || p.contains("22b") || p.contains("23.6b") || p.contains("24b") ||
           p.contains("27b") || p.contains("28b") || p.contains("32b") || p.contains("34b") ||
           p.contains("35b") || p.contains("46b") || p.contains("70b") || p.contains("72b") ||
           p.contains("78b") || p.contains("104b") || p.contains("236b") || p.contains("671b") {
            return true
        }
        return !isSmallModel(model: model) && !isMediumModel(model: model)
    }

    // MARK: - Query Matching

    private func matchesQuery(model: ComprehensiveModelMetadata, query: String) -> Bool {
        let searchTokens = query.split(separator: " ").map { String($0) }
        let searchableText = """
        \(model.displayName) \(model.officialName) \(model.publisher) \(model.modelFamily) \
        \(model.architecture) \(model.parameterCount) \(model.repositoryId) \(model.defaultQuantization) \
        \(model.taskType.rawValue) \(model.primaryCapabilities.joined(separator: " "))
        """.lowercased()

        // Every token must match somewhere in the model's searchable text
        for token in searchTokens {
            if !searchableText.contains(token) {
                return false
            }
        }
        return true
    }

    // MARK: - Sorting

    private func sortModels(
        a: ComprehensiveModelMetadata,
        b: ComprehensiveModelMetadata,
        sort: HubSortOption,
        profile: DeviceCapabilityProfile
    ) -> Bool {
        switch sort {
        case .mostPopular:
            if a.downloads != b.downloads {
                return a.downloads > b.downloads
            }
            return a.likes > b.likes

        case .recentlyUpdated:
            return a.lastVerificationDate > b.lastVerificationDate

        case .recentlyAdded:
            return a.lastVerificationDate > b.lastVerificationDate

        case .smallestSize:
            return a.estimatedDownloadSize < b.estimatedDownloadSize

        case .largestSize:
            return a.estimatedDownloadSize > b.estimatedDownloadSize

        case .alphabetical:
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending

        case .bestCompatibility:
            let suitA = DeviceCapabilityEngine.evaluateSuitability(model: a, profile: profile).isSmoothlyPlayable
            let suitB = DeviceCapabilityEngine.evaluateSuitability(model: b, profile: profile).isSmoothlyPlayable
            if suitA != suitB {
                return suitA && !suitB
            }
            return a.hardwareRequirements.minimumRAMBytes < b.hardwareRequirements.minimumRAMBytes
        }
    }

    // MARK: - Dynamic Remote Model Conversion

    /// Converts a discovered remote `HuggingFaceModel` into a unified `ComprehensiveModelMetadata` record.
    public static func convert(remoteModel: HuggingFaceModel) -> ComprehensiveModelMetadata {
        let identity = remoteModel.normalizedIdentity
        let firstFile = remoteModel.ggufFiles.first
        let quant = firstFile?.quantization ?? "Q4_K_M"
        let size = firstFile?.size ?? 0
        let arch = remoteModel.inferredArchitecture ?? "llama"

        let taskType: ModelTaskType
        switch identity.category {
        case .coding: taskType = .coding
        case .reasoning, .math: taskType = .reasoning
        default: taskType = .generalChat
        }

        let variants = remoteModel.ggufFiles.map { file in
            ModelQuantizationVariant(
                quantization: file.quantization,
                filename: file.filename,
                size: file.size,
                bitDepth: file.bitDepth,
                downloadURL: file.downloadURL,
                qualityDescription: "\(file.quantization) Quantization",
                memoryRequirementBytes: UInt64(Double(max(file.size, 1_000_000_000)) * 1.25)
            )
        }

        let estimatedRAM = UInt64(Double(max(size, 4_000_000_000)) * 1.3)

        return ComprehensiveModelMetadata(
            officialName: remoteModel.id,
            displayName: remoteModel.cleanDisplayName,
            publisher: remoteModel.publisher,
            modelFamily: identity.publisher,
            architecture: arch,
            parameterCount: identity.parameterScale ?? "Unknown",
            modelVersion: "1.0",
            description: remoteModel.cleanDescription,
            primaryCapabilities: [identity.category.rawValue],
            supportedLanguages: ["Multilingual"],
            contextWindow: 4096,
            modelFormat: .gguf,
            defaultQuantization: quant,
            estimatedDownloadSize: size,
            repositoryId: remoteModel.id,
            officialSourceURL: remoteModel.authoritativeCardURL,
            license: remoteModel.license ?? "Open Model License",
            hardwareRequirements: ModelHardwareRequirements(
                minimumRAMBytes: estimatedRAM,
                recommendedRAMBytes: estimatedRAM + 4_000_000_000,
                recommendedSiliconTier: "Apple Silicon M-Series"
            ),
            supportedInferenceEngines: [.llamaCppMetal],
            compatibilityStatus: .compatible,
            taskType: taskType,
            lastVerificationDate: remoteModel.lastModified ?? Date(),
            availableQuantizations: variants,
            isPopular: remoteModel.downloads > 100_000,
            downloads: remoteModel.downloads,
            likes: remoteModel.likes
        )
    }
}

