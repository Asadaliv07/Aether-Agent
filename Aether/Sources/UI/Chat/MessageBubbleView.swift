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
    @State private var isThoughtExpanded: Bool = false
    @State private var isToolResponseExpanded: Bool = false

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
                    VStack(alignment: .leading, spacing: 8) {
                        if containsAgentTags {
                            // 1. Thinking Process Block
                            if let thought = parsedThought, !thought.isEmpty {
                                DisclosureGroup(isExpanded: $isThoughtExpanded) {
                                    Text(thought)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .padding(.top, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "brain")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.purple)
                                        Text("Reasoning Process")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color.purple.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }

                            // 2. Tool Call Invocation Block
                            if let call = parsedToolCall {
                                HStack(spacing: 8) {
                                    Image(systemName: "wrench.and.screwdriver.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)
                                    Text("Tool Executed: \(call.toolName)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    if !call.parameters.isEmpty {
                                        Text("(\(call.parameters.keys.sorted().joined(separator: ", ")))")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            // 3. Tool Result Block
                            if let resp = parsedToolResponse {
                                DisclosureGroup(isExpanded: $isToolResponseExpanded) {
                                    Text(resp.body)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .padding(.top, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: resp.status == "success" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(resp.status == "success" ? .green : .red)
                                        Text("Tool Output (\(resp.name)): \(resp.status)")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }

                            // 4. Conversational Text Body
                            if !cleanConversationalText.isEmpty {
                                Text(cleanConversationalText)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(message.content)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }

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

    // MARK: - Agent Tag Decomposition

    private var containsAgentTags: Bool {
        message.content.contains("<thought>") ||
        message.content.contains("<tool_call>") ||
        message.content.contains("<tool_response")
    }

    private var parsedThought: String? {
        guard let start = message.content.range(of: "<thought>"),
              let end = message.content.range(of: "</thought>", range: start.upperBound..<message.content.endIndex) else {
            return nil
        }
        return String(message.content[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedToolCall: ToolCallInvocation? {
        AgentOrchestrator.parseToolCall(from: message.content)
    }

    private var parsedToolResponse: (name: String, status: String, body: String)? {
        guard let start = message.content.range(of: "<tool_response"),
              let tagEnd = message.content.range(of: ">", range: start.upperBound..<message.content.endIndex),
              let close = message.content.range(of: "</tool_response>", range: tagEnd.upperBound..<message.content.endIndex) else {
            return nil
        }
        let tagHeader = String(message.content[start.upperBound..<tagEnd.lowerBound])
        let body = String(message.content[tagEnd.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        var name = "tool"
        if let nameRange = tagHeader.range(of: "name=\"") {
            let afterName = tagHeader[nameRange.upperBound...]
            if let quote = afterName.firstIndex(of: "\"") {
                name = String(afterName[..<quote])
            }
        }

        var status = "success"
        if let statRange = tagHeader.range(of: "status=\"") {
            let afterStat = tagHeader[statRange.upperBound...]
            if let quote = afterStat.firstIndex(of: "\"") {
                status = String(afterStat[..<quote])
            }
        }

        return (name, status, body)
    }

    private var cleanConversationalText: String {
        var text = message.content
        if let s = text.range(of: "<thought>"), let e = text.range(of: "</thought>", range: s.upperBound..<text.endIndex) {
            text.removeSubrange(s.lowerBound..<e.upperBound)
        }
        if let s = text.range(of: "<tool_call>"), let e = text.range(of: "</tool_call>", range: s.upperBound..<text.endIndex) {
            text.removeSubrange(s.lowerBound..<e.upperBound)
        }
        if let s = text.range(of: "<tool_response"), let e = text.range(of: "</tool_response>", range: s.upperBound..<text.endIndex) {
            text.removeSubrange(s.lowerBound..<e.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
