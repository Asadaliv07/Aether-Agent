import Foundation

/// Role of a participant in a conversation.
public enum MessageRole: String, Sendable, Codable, Equatable {
    case user
    case assistant
    case system
}

/// Lifecycle status of an individual message.
public enum MessageStatus: String, Sendable, Codable, Equatable {
    /// Message generation completed normally.
    case completed
    /// Generation currently active and streaming.
    case streaming
    /// Generation was interrupted before normal completion (e.g. user cancelled or app restart).
    case interrupted
    /// Generation failed due to an error.
    case failed
}

/// Represents an immutable or persisted conversation record in SQLite.
public struct ConversationRecord: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public var modelName: String?
    public var systemPrompt: String?
    public var temperature: Float?
    public var maxTokens: Int32?
    public var stopSequences: [String]?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        modelName: String? = nil,
        systemPrompt: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int32? = nil,
        stopSequences: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelName = modelName
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }
}

/// Represents an immutable or persisted message record in SQLite.
public struct MessageRecord: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let conversationId: UUID
    public let role: MessageRole
    public let content: String
    public let createdAt: Date
    public let status: MessageStatus
    public let tokenCount: Int

    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        role: MessageRole,
        content: String,
        createdAt: Date = Date(),
        status: MessageStatus = .completed,
        tokenCount: Int = 0
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.status = status
        self.tokenCount = tokenCount
    }
}

/// Represents a structured result returned from a full-text message search query.
public struct SearchResultRecord: Sendable, Identifiable, Equatable {
    /// The unique identifier of the matching message.
    public let id: UUID
    /// The parent conversation identifier.
    public let conversationId: UUID
    /// The title of the parent conversation.
    public let conversationTitle: String
    /// The role of the matching message participant.
    public let role: MessageRole
    /// The formatted snippet with highlight delimiters (`[[MARK]]` and `[[/MARK]]`).
    public let snippet: String
    /// BM25 ranking score computed by SQLite FTS5 (lower/more negative indicates higher relevance).
    public let rank: Double
    /// Message creation timestamp.
    public let createdAt: Date

    public init(
        id: UUID,
        conversationId: UUID,
        conversationTitle: String,
        role: MessageRole,
        snippet: String,
        rank: Double,
        createdAt: Date
    ) {
        self.id = id
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.role = role
        self.snippet = snippet
        self.rank = rank
        self.createdAt = createdAt
    }
}

/// Lifecycle status of a model file download.
public enum DownloadStatus: String, Sendable, Codable, Equatable {
    case pending
    case downloading
    case paused
    case completed
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Represents a persistent model file download record in SQLite.
public struct ModelDownloadRecord: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let repoId: String
    public let filename: String
    public let remoteURL: String
    public let destinationPath: String
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var status: DownloadStatus
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var resumeData: Data?

    public init(
        id: UUID = UUID(),
        repoId: String,
        filename: String,
        remoteURL: String,
        destinationPath: String,
        totalBytes: Int64,
        downloadedBytes: Int64 = 0,
        status: DownloadStatus = .pending,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resumeData: Data? = nil
    ) {
        self.id = id
        self.repoId = repoId
        self.filename = filename
        self.remoteURL = remoteURL
        self.destinationPath = destinationPath
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resumeData = resumeData
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0.0), 1.0)
    }

    public var formattedProgress: String {
        let downloadedStr = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        if totalBytes > 0 {
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let percent = Int(fractionCompleted * 100)
            return "\(percent)% • \(downloadedStr) / \(totalStr)"
        } else {
            return downloadedStr
        }
    }
}

