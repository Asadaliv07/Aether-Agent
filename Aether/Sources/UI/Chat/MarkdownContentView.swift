import SwiftUI
import AppKit

/// Represents an element of parsed chat content: either regular formatted prose or a fenced code block.
public enum ParsedChatSegment: Identifiable, Equatable {
    case prose(id: String, content: String)
    case codeBlock(id: String, language: String, code: String)

    public var id: String {
        switch self {
        case .prose(let id, _): return id
        case .codeBlock(let id, _, _): return id
        }
    }
}

/// Parses raw markdown text into alternating prose and code block segments.
public struct MarkdownContentParser {
    public static func parse(_ text: String) -> [ParsedChatSegment] {
        var segments: [ParsedChatSegment] = []
        let fence = "```"
        var remaining = text[...]
        var segmentIndex = 0

        while let openRange = remaining.range(of: fence) {
            // Text before the opening fence
            let beforeFence = String(remaining[..<openRange.lowerBound])
            if !beforeFence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.prose(id: "prose_\(segmentIndex)", content: beforeFence))
                segmentIndex += 1
            }

            // Past the opening ```
            let restAfterOpen = remaining[openRange.upperBound...]

            // Look for optional language indicator before the first newline
            if let firstNewlineRange = restAfterOpen.range(of: "\n") {
                let language = String(restAfterOpen[..<firstNewlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let codeStart = restAfterOpen[firstNewlineRange.upperBound...]

                // Find closing ```
                if let closeRange = codeStart.range(of: fence) {
                    let code = String(codeStart[..<closeRange.lowerBound])
                    segments.append(.codeBlock(
                        id: "code_\(segmentIndex)",
                        language: language.isEmpty ? "code" : language.lowercased(),
                        code: code
                    ))
                    segmentIndex += 1
                    remaining = codeStart[closeRange.upperBound...]
                } else {
                    // Unclosed code block (e.g. streaming in progress)
                    let partialCode = String(codeStart)
                    segments.append(.codeBlock(
                        id: "code_\(segmentIndex)",
                        language: language.isEmpty ? "code" : language.lowercased(),
                        code: partialCode
                    ))
                    segmentIndex += 1
                    remaining = remaining[remaining.endIndex...]
                    break
                }
            } else {
                // Fenced block at the very end of streaming without a newline yet
                let langOrCode = String(restAfterOpen)
                segments.append(.codeBlock(id: "code_\(segmentIndex)", language: "code", code: langOrCode))
                segmentIndex += 1
                remaining = remaining[remaining.endIndex...]
                break
            }
        }

        // Remaining prose after all code blocks
        if !remaining.isEmpty {
            let trailingProse = String(remaining)
            if !trailingProse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.prose(id: "prose_\(segmentIndex)", content: trailingProse))
            }
        }

        if segments.isEmpty && !text.isEmpty {
            segments.append(.prose(id: "prose_0", content: text))
        }

        return segments
    }
}

/// Renders parsed chat content with markdown typography for prose and interactive cards for code blocks.
public struct MarkdownContentView: View {
    public let text: String
    public let isUser: Bool

    public init(text: String, isUser: Bool = false) {
        self.text = text
        self.isUser = isUser
    }

    public var body: some View {
        let segments = MarkdownContentParser.parse(text)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                switch segment {
                case .prose(_, let content):
                    ProseSegmentView(content: content, isUser: isUser)

                case .codeBlock(_, let language, let code):
                    CodeBlockCardView(language: language, code: code)
                }
            }
        }
    }
}

// MARK: - Prose Rendering

public struct ProseSegmentView: View {
    public let content: String
    public let isUser: Bool

    public var body: some View {
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.body)
                .foregroundStyle(isUser ? .white : .primary)
                .textSelection(.enabled)
                .lineSpacing(3)
        } else {
            Text(content)
                .font(.body)
                .foregroundStyle(isUser ? .white : .primary)
                .textSelection(.enabled)
                .lineSpacing(3)
        }
    }
}

// MARK: - Code Block Card

public struct CodeBlockCardView: View {
    public let language: String
    public let code: String

    @State private var isCopied: Bool = false

    public init(language: String, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Code Block Header
            HStack {
                Text(language.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isCopied ? .green : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))

            Divider()

            // Monospace Code Stream
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            isCopied = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                isCopied = false
            }
        }
    }
}

