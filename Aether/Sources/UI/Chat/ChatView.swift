import SwiftUI

/// Main chat interface view featuring autoscrolling messages, multiline composer,
/// streaming feedback, and native cancellation controls.
public struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isComposerFocused: Bool
    private let bottomAnchorID = "CHAT_BOTTOM_ANCHOR"

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            Divider()

            // Optional Error Banner
            if let error = viewModel.errorMessage {
                errorBanner(message: error)
            }

            // Message Stream
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 12) {
                        if viewModel.messages.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    isHighlighted: viewModel.targetScrollMessageId == message.id
                                )
                                .id(message.id)
                            }
                        }

                        // Bottom anchor for autoscrolling
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: viewModel.messages.count) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.messages.last?.content) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.targetScrollMessageId) {
                    if let targetId = viewModel.targetScrollMessageId {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Composer Area
            composerBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            isComposerFocused = true
        }
        .sheet(isPresented: $viewModel.showModelLibrary) {
            ModelLibraryView(viewModel: viewModel, isPresented: $viewModel.showModelLibrary)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var chatHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentConversationTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isGenerating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Streaming...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Capsule())
            }

            if let tps = viewModel.lastTokensPerSecond, let duration = viewModel.lastGenerationDurationSeconds {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f tok/s (%.2fs)", tps, duration))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
            }

            Button(action: {
                viewModel.showGenerationSettings.toggle()
            }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $viewModel.showGenerationSettings) {
                GenerationSettingsPopover(viewModel: viewModel)
            }
            .help("Generation Parameters & System Instructions")

            modelHeaderSelector
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private var modelHeaderSelector: some View {
        Menu {
            if !viewModel.catalogModels.isEmpty {
                Section("Cataloged Models") {
                    ForEach(viewModel.catalogModels) { model in
                        Button(action: {
                            Task {
                                await viewModel.selectAndLoadModel(model: model)
                            }
                        }) {
                            HStack {
                                Text("\(model.displayName) (\(model.quantization))")
                                if isModelActive(model) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(model.isMissing || !model.compatibilityStatus.isUsable)
                    }
                }
            }

            Section {
                Button(action: {
                    viewModel.showModelLibrary = true
                }) {
                    Label("Manage Model Library...", systemImage: "cpu")
                }

                if case .loaded = viewModel.inferenceState {
                    Button(role: .destructive, action: {
                        Task {
                            await viewModel.unloadModel()
                        }
                    }) {
                        Label("Unload Current Model", systemImage: "eject")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)

                Text(headerModelTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .help("Select model or open Model Library")
    }

    private func isModelActive(_ model: ModelRecord) -> Bool {
        if case .loaded(let info) = viewModel.inferenceState {
            return info.path == model.filePath
        }
        if case .generating(let info) = viewModel.inferenceState {
            return info.path == model.filePath
        }
        return false
    }

    private func displayNameForLoadedInfo(_ info: ModelInfo) -> String {
        if let matched = viewModel.catalogModels.first(where: { $0.filePath == info.path }) {
            return matched.displayName
        }
        return ModelCatalogNormalizer.normalize(installedName: info.name, filePath: info.path, architecture: "")
    }

    private var headerModelTitle: String {
        switch viewModel.inferenceState {
        case .loaded(let info):
            return displayNameForLoadedInfo(info)
        case .generating(let info):
            return displayNameForLoadedInfo(info)
        case .loading:
            return "Loading..."
        case .unloaded, .unloading, .failed:
            return "Select Model"
        }
    }

    private var currentConversationTitle: String {
        if let id = viewModel.selectedConversationId,
           let conv = viewModel.conversations.first(where: { $0.id == id }) {
            return conv.title
        }
        return "Chat"
    }

    private var headerSubtitle: String {
        switch viewModel.inferenceState {
        case .loaded(let info):
            return "Active model: \(displayNameForLoadedInfo(info))"
        case .generating(let info):
            return "Generating with \(displayNameForLoadedInfo(info))"
        case .loading:
            return "Loading model into memory..."
        case .unloaded:
            return "No model loaded (load a GGUF model from the sidebar)"
        case .unloading:
            return "Unloading model..."
        case .failed:
            return "Inference engine in error state"
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 60)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("Aether Local Intelligence")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Private, high-performance on-device AI for Apple Silicon.\nType a message below to start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if case .unloaded = viewModel.inferenceState {
                Text("⚠️ Please load a GGUF model in the sidebar before generating.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer(minLength: 80)
        }
        .padding(24)
    }

    // MARK: - Error Banner

    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()

            Button(action: {
                // Clear error
            }) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }

    // MARK: - Composer Bar

    @ViewBuilder
    private var composerBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                // Multiline Input Field
                TextField("Message Aether... (Shift+Return for newline)", text: $viewModel.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .font(.body)
                    .focused($isComposerFocused)
                    .onSubmit {
                        // Enter sends if not empty and not generating
                        if !NSEvent.modifierFlags.contains(.shift) {
                            send()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    )

                // Action Controls: Send or Cancel
                if viewModel.isGenerating {
                    Button(action: cancel) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel generation (Esc)")
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send message (Return)")
                }
            }

            // Keyboard shortcut hint
            HStack {
                Text("Return to send • Shift+Return for newline")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let modelInfo = loadedModelInfo {
                    Text("\(modelInfo.name)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var loadedModelInfo: ModelInfo? {
        if case .loaded(let info) = viewModel.inferenceState {
            return info
        } else if case .generating(let info) = viewModel.inferenceState {
            return info
        }
        return nil
    }

    private var canSend: Bool {
        !viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isGenerating
            && isModelLoaded
    }

    private var isModelLoaded: Bool {
        if case .loaded = viewModel.inferenceState {
            return true
        }
        return false
    }

    private func send() {
        guard canSend else { return }
        Task {
            await viewModel.sendMessage()
        }
    }

    private func cancel() {
        Task {
            await viewModel.cancelGeneration()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

/// Popover sheet presenting user-configurable generation controls and system prompt instructions.
public struct GenerationSettingsPopover: View {
    @Bindable var viewModel: ChatViewModel
    @State private var tempPrompt: String = ""
    @State private var tempTemperature: Float = 0.7
    @State private var tempMaxTokens: Int32 = 2048
    @State private var tempStopSequences: [String] = []
    @State private var newStopSequence: String = ""
    @State private var validationError: String? = nil

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Generation Parameters")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    let promptVal = tempPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : tempPrompt
                    Task {
                        await viewModel.updateCurrentConversationSettings(
                            systemPrompt: promptVal,
                            temperature: tempTemperature,
                            maxTokens: tempMaxTokens,
                            stopSequences: tempStopSequences
                        )
                        viewModel.showGenerationSettings = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("System Instructions")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                TextEditor(text: $tempPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 70)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", tempTemperature))
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(value: $tempTemperature, in: 0.0...2.0, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Maximum Response Tokens")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tempMaxTokens)")
                        .font(.caption)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(tempMaxTokens) },
                    set: { tempMaxTokens = Int32($0) }
                ), in: 64...4096, step: 64)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stop Sequences")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tempStopSequences.count)/8")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if tempStopSequences.isEmpty {
                    Text("No stop sequences configured")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(tempStopSequences.enumerated()), id: \.offset) { index, seq in
                                HStack(spacing: 4) {
                                    Text(seq)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    Button {
                                        removeStopSequence(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove stop sequence \(seq)")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 6) {
                    TextField("Add stop sequence (e.g. </s>)...", text: $newStopSequence)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit {
                            addStopSequence()
                        }

                    Button(action: addStopSequence) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newStopSequence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tempStopSequences.count >= 8)
                    .accessibilityLabel("Add stop sequence")
                }

                if let validationError {
                    Text(validationError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            tempPrompt = viewModel.currentSystemPrompt
            tempTemperature = viewModel.currentTemperature
            tempMaxTokens = viewModel.currentMaxTokens
            tempStopSequences = viewModel.currentStopSequences
            newStopSequence = ""
            validationError = nil
        }
    }

    private func addStopSequence() {
        let trimmed = newStopSequence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationError = "Stop sequence cannot be empty."
            return
        }
        guard trimmed.count <= 64 else {
            validationError = "Stop sequence cannot exceed 64 characters."
            return
        }
        guard tempStopSequences.count < 8 else {
            validationError = "Maximum 8 stop sequences allowed."
            return
        }
        guard !tempStopSequences.contains(trimmed) else {
            validationError = "Stop sequence '\(trimmed)' is already added."
            return
        }
        tempStopSequences.append(trimmed)
        newStopSequence = ""
        validationError = nil
    }

    private func removeStopSequence(at index: Int) {
        guard index >= 0 && index < tempStopSequences.count else { return }
        tempStopSequences.remove(at: index)
        validationError = nil
    }
}

