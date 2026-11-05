import Foundation

/// Presentation model representing an individual chat message in the UI layer.
///
/// Decoupled from native inference structures and safe for `@MainActor` SwiftUI observation.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let conversationId: UUID
    public let role: MessageRole
    public var content: String
    public let createdAt: Date
    public var status: MessageStatus
    public var tokenCount: Int

    public var isUser: Bool {
        role == .user
    }

    public var isAssistant: Bool {
        role == .assistant
    }

    public var isStreaming: Bool {
        status == .streaming
    }

    public var isInterrupted: Bool {
        status == .interrupted
    }

    public var isFailed: Bool {
        status == .failed
    }

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

    /// Initializes a UI message from a persisted SQLite `MessageRecord`.
    public init(record: MessageRecord) {
        self.id = record.id
        self.conversationId = record.conversationId
        self.role = record.role
        self.content = record.content
        self.createdAt = record.createdAt
        self.status = record.status
        self.tokenCount = record.tokenCount
    }

    /// Converts to a persisted SQLite `MessageRecord`.
    public func toRecord() -> MessageRecord {
        MessageRecord(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            createdAt: createdAt,
            status: status,
            tokenCount: tokenCount
        )
    }
}
