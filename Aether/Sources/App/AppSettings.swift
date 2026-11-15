import Foundation
import Observation
import SwiftUI

/// App-wide settings and user preferences model with robust UserDefaults persistence.
///
/// Manages General, Model, Chat, Download, and Advanced configuration options
/// with real-time effect on inference parameters and UI presentation.
@Observable
@MainActor
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    // MARK: - Keys
    private enum Keys {
        static let appTheme = "aether.settings.appTheme"
        static let fontSize = "aether.settings.fontSize"
        static let interfaceDensity = "aether.settings.interfaceDensity"

        static let defaultModelId = "aether.settings.defaultModelId"
        static let contextLength = "aether.settings.contextLength"
        static let maxTokens = "aether.settings.maxTokens"
        static let temperature = "aether.settings.temperature"
        static let topP = "aether.settings.topP"
        static let topK = "aether.settings.topK"
        static let repetitionPenalty = "aether.settings.repetitionPenalty"
        static let metalGPUAcceleration = "aether.settings.metalGPUAcceleration"
        static let metalGPULayers = "aether.settings.metalGPULayers"

        static let defaultSystemPrompt = "aether.settings.defaultSystemPrompt"
        static let isStreamingEnabled = "aether.settings.isStreamingEnabled"
        static let sendOnEnter = "aether.settings.sendOnEnter"
        static let autoScrollOnStream = "aether.settings.autoScrollOnStream"
        static let isAgentModeEnabled = "aether.settings.isAgentModeEnabled"
        static let multiAgentFramework = "aether.settings.multiAgentFramework"

        static let customModelStoragePath = "aether.settings.customModelStoragePath"
        static let verifyChecksums = "aether.settings.verifyChecksums"
        static let maxConcurrentDownloads = "aether.settings.maxConcurrentDownloads"

        static let debugLoggingEnabled = "aether.settings.debugLoggingEnabled"
        static let showTokenRate = "aether.settings.showTokenRate"
    }

    // MARK: - General Settings
    public var appTheme: String {
        didSet { defaults.set(appTheme, forKey: Keys.appTheme) }
    }

    public var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    public var interfaceDensity: String {
        didSet { defaults.set(interfaceDensity, forKey: Keys.interfaceDensity) }
    }

    // MARK: - Model & Inference Settings
    public var defaultModelId: String? {
        didSet { defaults.set(defaultModelId, forKey: Keys.defaultModelId) }
    }

    public var contextLength: Int {
        didSet { defaults.set(contextLength, forKey: Keys.contextLength) }
    }

    public var maxTokens: Int32 {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }

    public var temperature: Float {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    public var topP: Float {
        didSet { defaults.set(topP, forKey: Keys.topP) }
    }

    public var topK: Int32 {
        didSet { defaults.set(topK, forKey: Keys.topK) }
    }

    public var repetitionPenalty: Float {
        didSet { defaults.set(repetitionPenalty, forKey: Keys.repetitionPenalty) }
    }

    public var metalGPUAcceleration: Bool {
        didSet { defaults.set(metalGPUAcceleration, forKey: Keys.metalGPUAcceleration) }
    }

    public var metalGPULayers: Int32 {
        didSet { defaults.set(metalGPULayers, forKey: Keys.metalGPULayers) }
    }

    // MARK: - Chat Settings
    public var defaultSystemPrompt: String {
        didSet { defaults.set(defaultSystemPrompt, forKey: Keys.defaultSystemPrompt) }
    }

    public var isStreamingEnabled: Bool {
        didSet { defaults.set(isStreamingEnabled, forKey: Keys.isStreamingEnabled) }
    }

    public var sendOnEnter: Bool {
        didSet { defaults.set(sendOnEnter, forKey: Keys.sendOnEnter) }
    }

    public var autoScrollOnStream: Bool {
        didSet { defaults.set(autoScrollOnStream, forKey: Keys.autoScrollOnStream) }
    }

    public var isAgentModeEnabled: Bool {
        didSet { defaults.set(isAgentModeEnabled, forKey: Keys.isAgentModeEnabled) }
    }

    public var multiAgentFramework: String {
        didSet { defaults.set(multiAgentFramework, forKey: Keys.multiAgentFramework) }
    }

    // MARK: - Download Settings
    public var customModelStoragePath: String {
        didSet { defaults.set(customModelStoragePath, forKey: Keys.customModelStoragePath) }
    }

    public var verifyChecksums: Bool {
        didSet { defaults.set(verifyChecksums, forKey: Keys.verifyChecksums) }
    }

    public var maxConcurrentDownloads: Int {
        didSet { defaults.set(maxConcurrentDownloads, forKey: Keys.maxConcurrentDownloads) }
    }

    // MARK: - Advanced Settings
    public var debugLoggingEnabled: Bool {
        didSet { defaults.set(debugLoggingEnabled, forKey: Keys.debugLoggingEnabled) }
    }

    public var showTokenRate: Bool {
        didSet { defaults.set(showTokenRate, forKey: Keys.showTokenRate) }
    }

    // MARK: - Initialization
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load General
        self.appTheme = defaults.string(forKey: Keys.appTheme) ?? "system"
        let loadedFontSize = defaults.double(forKey: Keys.fontSize)
        self.fontSize = loadedFontSize > 0 ? loadedFontSize : 13.0
        self.interfaceDensity = defaults.string(forKey: Keys.interfaceDensity) ?? "comfortable"

        // Load Model & Inference
        self.defaultModelId = defaults.string(forKey: Keys.defaultModelId)
        let loadedContext = defaults.integer(forKey: Keys.contextLength)
        self.contextLength = loadedContext > 0 ? loadedContext : 4096
        let loadedMaxTokens = defaults.integer(forKey: Keys.maxTokens)
        self.maxTokens = loadedMaxTokens > 0 ? Int32(loadedMaxTokens) : 2048
        let loadedTemp = defaults.object(forKey: Keys.temperature) as? Float
        self.temperature = loadedTemp ?? 0.7
        let loadedTopP = defaults.object(forKey: Keys.topP) as? Float
        self.topP = loadedTopP ?? 0.9
        let loadedTopK = defaults.integer(forKey: Keys.topK)
        self.topK = loadedTopK > 0 ? Int32(loadedTopK) : 40
        let loadedRep = defaults.object(forKey: Keys.repetitionPenalty) as? Float
        self.repetitionPenalty = loadedRep ?? 1.1
        self.metalGPUAcceleration = defaults.object(forKey: Keys.metalGPUAcceleration) as? Bool ?? true
        let loadedLayers = defaults.integer(forKey: Keys.metalGPULayers)
        self.metalGPULayers = loadedLayers != 0 ? Int32(loadedLayers) : 99

        // Load Chat
        self.defaultSystemPrompt = defaults.string(forKey: Keys.defaultSystemPrompt) ??
            "You are Aether, an intelligent, privacy-first local AI assistant running natively on Apple Silicon."
        self.isStreamingEnabled = defaults.object(forKey: Keys.isStreamingEnabled) as? Bool ?? true
        self.sendOnEnter = defaults.object(forKey: Keys.sendOnEnter) as? Bool ?? true
        self.autoScrollOnStream = defaults.object(forKey: Keys.autoScrollOnStream) as? Bool ?? true
        self.isAgentModeEnabled = defaults.object(forKey: Keys.isAgentModeEnabled) as? Bool ?? true
        self.multiAgentFramework = defaults.string(forKey: Keys.multiAgentFramework) ?? "maf"

        // Load Download
        self.customModelStoragePath = defaults.string(forKey: Keys.customModelStoragePath) ?? ""
        self.verifyChecksums = defaults.object(forKey: Keys.verifyChecksums) as? Bool ?? true
        let loadedMaxDownloads = defaults.integer(forKey: Keys.maxConcurrentDownloads)
        self.maxConcurrentDownloads = loadedMaxDownloads > 0 ? loadedMaxDownloads : 1

        // Load Advanced
        self.debugLoggingEnabled = defaults.bool(forKey: Keys.debugLoggingEnabled)
        self.showTokenRate = defaults.object(forKey: Keys.showTokenRate) as? Bool ?? true
    }

    // MARK: - Actions

    public func resetToDefaults() {
        appTheme = "system"
        fontSize = 13.0
        interfaceDensity = "comfortable"

        defaultModelId = nil
        contextLength = 4096
        maxTokens = 2048
        temperature = 0.7
        topP = 0.9
        topK = 40
        repetitionPenalty = 1.1
        metalGPUAcceleration = true
        metalGPULayers = 99

        defaultSystemPrompt = "You are Aether, an intelligent, privacy-first local AI assistant running natively on Apple Silicon."
        isStreamingEnabled = true
        sendOnEnter = true
        autoScrollOnStream = true
        isAgentModeEnabled = true
        multiAgentFramework = "maf"

        customModelStoragePath = ""
        verifyChecksums = true
        maxConcurrentDownloads = 1

        debugLoggingEnabled = false
        showTokenRate = true
    }

    /// Computes the disk storage space used by downloaded models in the Application Support directory.
    public func computeModelStorageUsage() -> (usedBytes: Int64, fileCount: Int) {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aether", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        guard let dirURL = appSupport, fileManager.fileExists(atPath: dirURL.path) else {
            return (0, 0)
        }

        var totalSize: Int64 = 0
        var count = 0

        if let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   resourceValues.isRegularFile == true,
                   let size = resourceValues.fileSize {
                    totalSize += Int64(size)
                    count += 1
                }
            }
        }

        return (totalSize, count)
    }

    /// Cleans up incomplete or temporary downloads (`.tmp`, `.download`, `.part`).
    public func clearTemporaryCache() -> Int {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aether", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        guard let dirURL = appSupport, fileManager.fileExists(atPath: dirURL.path) else {
            return 0
        }

        var deletedCount = 0
        if let contents = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            for file in contents {
                let ext = file.pathExtension.lowercased()
                if ext == "tmp" || ext == "part" || ext == "download" || file.lastPathComponent.hasPrefix(".") {
                    try? fileManager.removeItem(at: file)
                    deletedCount += 1
                }
            }
        }
        return deletedCount
    }
}

