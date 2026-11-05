import SwiftUI
import AppKit

/// Renders an individual chat message with modern Apple Silicon aesthetics.
///
/// Distinguishes user prompts from assistant responses with distinctive layouts,
/// streaming animations, interrupted badges, and clipboard actions.
public struct MessageBubbleView: View {
    public let message: ChatMessage
    public let isHighlighted: Bool
    @State private var isHovering = false

    public init(message: ChatMessage, isHighlighted: Bool = false) {
        self.message = message
        self.isHighlighted = isHighlighted
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer(minLength: 60)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
                .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        )
        .onHover { isHovering = $0 }
    }

    // MARK: - User Message Bubble

    @ViewBuilder
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)

            HStack(spacing: 8) {
                if isHovering {
                    copyButton
                }
                timestampView
            }
            .padding(.trailing, 4)
        }
    }

    // MARK: - Assistant Message Bubble

    @ViewBuilder
    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            // Model Avatar / Icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.content)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

                        if message.isStreaming {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                                Text("Generating...")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    )
                }

                // Status indicators for interrupted or failed responses
                if message.isInterrupted {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.circle.fill")
                            .font(.caption)
                        Text("Generation Interrupted")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                } else if message.isFailed {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.caption)
                        Text("Generation Failed")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                }

                HStack(spacing: 8) {
                    timestampView
                    if message.tokenCount > 0 {
                        Text("• \(message.tokenCount) tokens")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if isHovering && !message.content.isEmpty {
                        copyButton
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    // MARK: - Accessories

    @ViewBuilder
    private var timestampView: some View {
        Text(message.createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var copyButton: some View {
        Button(action: copyToClipboard) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
    }
}
