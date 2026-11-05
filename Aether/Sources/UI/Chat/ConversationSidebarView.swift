import SwiftUI
import AppKit

/// Sidebar view for conversation navigation and local model status.
public struct ConversationSidebarView: View {
    @Bindable var viewModel: ChatViewModel
    @Binding var showSystemTelemetry: Bool

    public init(viewModel: ChatViewModel, showSystemTelemetry: Binding<Bool>) {
        self.viewModel = viewModel
        self._showSystemTelemetry = showSystemTelemetry
    }

    public var body: some View {
        VStack(spacing: 0) {
            // New Chat Action Bar
            HStack {
                Button(action: {
                    Task {
                        await viewModel.createNewConversation()
                    }
                }) {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("n", modifiers: .command)
                .help("Create a new conversation (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Search Input Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Search messages...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if viewModel.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                } else if !viewModel.searchQuery.isEmpty {
                    Button(action: {
                        viewModel.clearSearch()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Conversation / Search Results List
            List(selection: Binding(
                get: { viewModel.selectedConversationId },
                set: { newId in
                    if let newId {
                        Task {
                            await viewModel.selectConversation(id: newId)
                        }
                    }
                }
            )) {
                if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Results (\(viewModel.searchResults.count))") {
                        if viewModel.searchResults.isEmpty {
                            if viewModel.isSearching {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Searching...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            } else {
                                Text("No matching messages")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            }
                        } else {
                            ForEach(viewModel.searchResults) { result in
                                SearchResultRowView(
                                    result: result,
                                    isSelected: viewModel.selectedConversationId == result.conversationId && viewModel.targetScrollMessageId == result.id,
                                    onSelect: {
                                        Task {
                                            await viewModel.selectSearchResult(result)
                                        }
                                    }
                                )
                            }
                        }
                    }
                } else {
                    Section("Conversations") {
                        ForEach(viewModel.conversations) { conv in
                            ConversationRowView(
                                conversation: conv,
                                isSelected: viewModel.selectedConversationId == conv.id,
                                onDelete: {
                                    Task {
                                        await viewModel.deleteConversation(id: conv.id)
                                    }
                                }
                            )
                            .tag(conv.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Model Readiness & Footer
            sidebarFooter
        }
        .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
    }

    // MARK: - Sidebar Footer

    @ViewBuilder
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Model Status Card
            HStack(spacing: 8) {
                statusIndicatorCircle

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelStatusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(modelStatusSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                modelActionButton
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Secondary controls
            HStack {
                Button(action: {
                    viewModel.showModelLibrary = true
                }) {
                    Label("Model Library", systemImage: "cpu")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: {
                    showSystemTelemetry.toggle()
                }) {
                    Label("System Info", systemImage: "info.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Model Status Helpers

    @ViewBuilder
    private var statusIndicatorCircle: some View {
        switch viewModel.inferenceState {
        case .loaded:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .generating:
            Circle().fill(Color.blue).frame(width: 8, height: 8)
        case .loading:
            ProgressView().controlSize(.mini)
        case .failed:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .unloaded, .unloading:
            Circle().fill(Color.secondary).frame(width: 8, height: 8)
        }
    }

    private var modelStatusTitle: String {
        switch viewModel.inferenceState {
        case .loaded(let info):
            return info.name
        case .generating(let info):
            return info.name
        case .loading:
            return "Loading Model..."
        case .failed:
            return "Engine Error"
        case .unloaded:
            return "No Model Loaded"
        case .unloading:
            return "Unloading..."
        }
    }

    private var modelStatusSubtitle: String {
        switch viewModel.inferenceState {
        case .loaded(let info):
            let sizeStr = ByteCountFormatter.string(fromByteCount: info.sizeInBytes, countStyle: .file)
            return "\(info.description) • \(sizeStr)"
        case .generating:
            return "Inference active"
        case .loading:
            return "Reading weights..."
        case .failed(let err):
            return err
        case .unloaded:
            return "Local Apple Silicon"
        case .unloading:
            return "Cleaning up"
        }
    }

    @ViewBuilder
    private var modelActionButton: some View {
        switch viewModel.inferenceState {
        case .loaded:
            Button(action: {
                Task {
                    await viewModel.unloadModel()
                }
            }) {
                Image(systemName: "eject")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Unload model from unified memory")

        case .unloaded:
            Button(action: {
                viewModel.showModelLibrary = true
            }) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Open Model Library...")

        default:
            EmptyView()
        }
    }

    private func promptLoadModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [] // Allow selecting GGUF files

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await viewModel.loadModel(path: url.path)
            }
        }
    }
}

// MARK: - Supporting Row View

private struct ConversationRowView: View {
    let conversation: ConversationRecord
    let isSelected: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                Text(conversation.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Conversation", systemImage: "trash")
            }
        }
    }
}

// MARK: - Search Supporting Views

private struct SearchResultRowView: View {
    let result: SearchResultRecord
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: result.role == .user ? "person.circle" : "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)

                    Text(result.conversationTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(result.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                HighlightedSnippetView(snippet: result.snippet)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HighlightedSnippetView: View {
    let snippet: String

    var body: some View {
        renderSnippet(snippet)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func renderSnippet(_ raw: String) -> Text {
        var text = Text("")
        let markStart = "[[MARK]]"
        let markEnd = "[[/MARK]]"

        var remaining = raw[...]
        while let startRange = remaining.range(of: markStart) {
            let before = remaining[..<startRange.lowerBound]
            if !before.isEmpty {
                text = text + Text(String(before))
            }

            let afterStart = remaining[startRange.upperBound...]
            if let endRange = afterStart.range(of: markEnd) {
                let match = afterStart[..<endRange.lowerBound]
                text = text + Text(String(match))
                    .bold()
                    .foregroundColor(.accentColor)
                remaining = afterStart[endRange.upperBound...]
            } else {
                text = text + Text(String(afterStart))
                remaining = remaining[remaining.endIndex...]
                break
            }
        }
        if !remaining.isEmpty {
            text = text + Text(String(remaining))
        }
        return text
    }
}
