import Foundation

/// Represents an immutable conversation message formatted for LLM prompt assembly.
///
/// Decoupled from presentation models and database entities; conforms to `Sendable`
/// for safe concurrency boundaries.
public struct PromptMessage: Sendable, Equatable {
    /// Role identifier (e.g. "system", "user", "assistant").
    public let role: String

    /// The text content of the message.
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    /// Convenience initializer for standard role enum.
    public init(role: MessageRole, content: String) {
        self.role = role.rawValue
        self.content = content
    }
}
