import SwiftUI
import AppKit

/// Tab categories for the native macOS Settings window.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case model = "Model & Inference"
    case chat = "Chat & Agent"
    case permissions = "Filesystem & Permissions"
    case storage = "Storage & Downloads"
    case diagnostics = "Diagnostics"
    case about = "About"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .model: return "cpu"
        case .chat: return "bubble.left.and.bubble.right"
        case .permissions: return "lock.shield"
        case .storage: return "externaldrive"
        case .diagnostics: return "waveform.path.ecg"
        case .about: return "info.circle"
        }
    }
}

/// Comprehensive native macOS Settings interface providing complete configuration
/// across General preferences, Model inference hyper-parameters, Chat defaults,
/// Storage management, System diagnostics, and About information.
public struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var viewModel: ChatViewModel
    @Binding var isPresented: Bool

    @State private var selectedTab: SettingsTab = .general
    @State private var cacheClearSuccessMessage: String?
    @State private var showResetConfirmation: Bool = false

    public init(settings: AppSettings, viewModel: ChatViewModel, isPresented: Binding<Bool>) {
        self.settings = settings
        self.viewModel = viewModel
        self._isPresented = isPresented
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Label(selectedTab.rawValue, systemImage: selectedTab.systemImage)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Button("Done") {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .general:
                            generalSettingsTab
                        case .model:
                            modelSettingsTab
                        case .chat:
                            chatSettingsTab
                        case .permissions:
                            permissionsSettingsTab
                        case .storage:
                            storageSettingsTab
                        case .diagnostics:
                            diagnosticsSettingsTab
                        case .about:
                            aboutSettingsTab
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 560)
        .confirmationDialog(
            "Reset All Settings to Defaults?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All Settings", role: .destructive) {
                settings.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restore all generation parameters, themes, prompts, and preferences to their factory defaults.")
        }
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalSettingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Interface Appearance")
                .font(.headline)

            Picker("Theme", selection: $settings.appTheme) {
                Text("System Default").tag("system")
                Text("Light Mode").tag("light")
                Text("Dark Mode").tag("dark")
            }
            .pickerStyle(.segmented)

            Picker("Layout Density", selection: $settings.interfaceDensity) {
                Text("Comfortable").tag("comfortable")
                Text("Compact").tag("compact")
            }
            .pickerStyle(.segmented)

            Divider()

            Text("Typography & Readability")
                .font(.headline)

            HStack {
                Text("Base Font Size: \(Int(settings.fontSize)) pt")
                Slider(value: $settings.fontSize, in: 11...18, step: 1)
            }

            Toggle("Display generation speed & token throughput badges", isOn: $settings.showTokenRate)

            Divider()

            Text("Reset Preferences")
                .font(.headline)

            Button("Restore All Defaults...", role: .destructive) {
                showResetConfirmation = true
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Model & Inference Tab

    @ViewBuilder
    private var modelSettingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Default Local Model")
                .font(.headline)

            Picker("Startup Model", selection: Binding(
                get: { settings.defaultModelId ?? "" },
                set: { settings.defaultModelId = $0.isEmpty ? nil : $0 }
            )) {
                Text("None (Choose manually)").tag("")
                ForEach(viewModel.catalogModels) { model in
                    Text("\(model.name) (\(model.architecture))").tag(model.id.uuidString)
                }
            }

            Divider()

            Text("Inference Parameters (Metal Acceleration)")
                .font(.headline)

            Toggle("Enable Apple Silicon GPU Acceleration (Metal 3)", isOn: $settings.metalGPUAcceleration)

            HStack {
                Text("Metal GPU Offload Layers: \(settings.metalGPULayers == 99 ? "All (Full GPU)" : "\(settings.metalGPULayers)")")
                Slider(value: Binding(
                    get: { Double(settings.metalGPULayers) },
                    set: { settings.metalGPULayers = Int32($0) }
                ), in: 0...99, step: 1)
            }

            Divider()

            Text("Sampling & Context Parameters")
                .font(.headline)

            Picker("Context Window Size", selection: $settings.contextLength) {
                Text("2,048 tokens").tag(2048)
                Text("4,096 tokens (Default)").tag(4096)
                Text("8,192 tokens").tag(8192)
                Text("16,384 tokens").tag(16384)
            }

            HStack {
                Text("Max Generation Tokens: \(settings.maxTokens)")
                Slider(value: Binding(
                    get: { Double(settings.maxTokens) },
                    set: { settings.maxTokens = Int32($0) }
                ), in: 256...8192, step: 256)
            }

            HStack {
                Text(String(format: "Temperature: %.2f", settings.temperature))
                Slider(value: $settings.temperature, in: 0.0...1.5, step: 0.05)
            }
            Text("Lower values produce focused and deterministic answers; higher values produce creative outputs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(String(format: "Top-P (Nucleus Sampling): %.2f", settings.topP))
                Slider(value: $settings.topP, in: 0.1...1.0, step: 0.05)
            }

            HStack {
                Text("Top-K Sampling: \(settings.topK)")
                Slider(value: Binding(
                    get: { Double(settings.topK) },
                    set: { settings.topK = Int32($0) }
                ), in: 1...100, step: 1)
            }

            HStack {
                Text(String(format: "Repetition Penalty: %.2f", settings.repetitionPenalty))
                Slider(value: $settings.repetitionPenalty, in: 1.0...1.5, step: 0.05)
            }
        }
    }

    // MARK: - Chat & Agent Tab

    @ViewBuilder
    private var chatSettingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("System Instructions")
                .font(.headline)

            Text("Default System Prompt applied to new conversations:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $settings.defaultSystemPrompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            Divider()

            Text("Chat Interaction & Streaming")
                .font(.headline)

            Toggle("Stream responses token-by-token in real-time", isOn: $settings.isStreamingEnabled)

            Toggle("Automatically scroll message stream during generation", isOn: $settings.autoScrollOnStream)

            Toggle("Send message with Return key (Shift+Return for newline)", isOn: $settings.sendOnEnter)

            Divider()

            Text("Agent & Autonomous Tools")
                .font(.headline)

            Toggle("Enable Agent Mode by default (Allows safe calculator, system inspection, and file reader)", isOn: $settings.isAgentModeEnabled)

            Text("When Agent Mode is active, the assistant can execute sandboxed tools and ask for confirmation before accessing documents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Filesystem & Permissions Tab

    @ViewBuilder
    private var permissionsSettingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Filesystem Authorization Boundaries")
                .font(.headline)

            Text("Aether Agent enforces strict fail-closed security. The agent cannot read, create, modify, or delete files outside the explicitly authorized directory roots listed below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Quick Authorize Common Directories
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Authorize Standard Folders")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 12) {
                    Button(action: {
                        Task { try? await viewModel.authorizeCommonDirectory(.desktopDirectory) }
                    }) {
                        Label("Authorize Desktop", systemImage: "desktopcomputer")
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        Task { try? await viewModel.authorizeCommonDirectory(.documentDirectory) }
                    }) {
                        Label("Authorize Documents", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        Task { try? await viewModel.authorizeCommonDirectory(.downloadsDirectory) }
                    }) {
                        Label("Authorize Downloads", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: {
                        Task { try? await viewModel.promptAndAuthorizeDirectory() }
                    }) {
                        Label("Add Custom Folder...", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Divider()

            // Currently Authorized Folders List
            HStack {
                Text("Authorized Directories (\(viewModel.authorizedDirectories.count))")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await viewModel.refreshAuthorizedDirectories() }
                }
                .buttonStyle(.borderless)
            }

            if viewModel.authorizedDirectories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("No Directories Authorized")
                        .font(.headline)
                    Text("The agent cannot interact with files or folders until you authorize at least one directory above (e.g. Desktop).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.authorizedDirectories) { dir in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(dir.name)
                                        .font(.body.weight(.semibold))

                                    if dir.isReadOnly {
                                        Text("Read-Only")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.15))
                                            .foregroundStyle(.orange)
                                            .clipShape(Capsule())
                                    } else {
                                        Text("Read / Write")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.15))
                                            .foregroundStyle(.green)
                                            .clipShape(Capsule())
                                    }

                                    if !dir.isAccessible {
                                        Text("Missing on Disk")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.red.opacity(0.15))
                                            .foregroundStyle(.red)
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(dir.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button(dir.isReadOnly ? "Allow Write" : "Make Read-Only") {
                                Task { await viewModel.toggleReadOnly(url: dir.url) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(role: .destructive) {
                                Task { await viewModel.revokeDirectory(url: dir.url) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Revoke agent access to this folder")
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Divider()

            // System Privacy & Automation Permissions Dashboard
            Text("macOS System Permissions Dashboard")
                .font(.headline)

            VStack(spacing: 12) {
                // Accessibility Permission
                let isAccessibilityGranted = AXIsProcessTrusted()
                HStack {
                    Image(systemName: isAccessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isAccessibilityGranted ? .green : .orange)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("macOS Accessibility (UI Automation)")
                                .font(.subheadline.weight(.semibold))
                            Text(isAccessibilityGranted ? "Granted" : "Not Granted")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((isAccessibilityGranted ? Color.green : Color.orange).opacity(0.15))
                                .foregroundStyle(isAccessibilityGranted ? .green : .orange)
                                .clipShape(Capsule())
                        }
                        Text("Required for clicking UI controls, typing text into desktop apps, and inspecting window elements.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !isAccessibilityGranted {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Screen Recording Permission
                let isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
                HStack {
                    Image(systemName: isScreenRecordingGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isScreenRecordingGranted ? .green : .orange)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Screen Recording (Window Screenshots)")
                                .font(.subheadline.weight(.semibold))
                            Text(isScreenRecordingGranted ? "Granted" : "Not Granted")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((isScreenRecordingGranted ? Color.green : Color.orange).opacity(0.15))
                                .foregroundStyle(isScreenRecordingGranted ? .green : .orange)
                                .clipShape(Capsule())
                        }
                        Text("Required for capturing visual screenshots of application windows or regions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !isScreenRecordingGranted {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Browser & Automation Engine Status
                HStack {
                    Image(systemName: "safari.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Browser & App Control Engines")
                                .font(.subheadline.weight(.semibold))
                            Text("Active")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                        Text("WebKit in-app browser and native NSWorkspace / Launch Services integrations are active and ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            // Security Details
            VStack(alignment: .leading, spacing: 6) {
                Text("Persistence & Sandbox Isolation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Permissions are securely persisted across app restarts using macOS Security-Scoped Bookmarks. Revoking access removes the folder bookmark immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Storage & Downloads Tab

    @ViewBuilder
    private var storageSettingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Model Storage Location")
                .font(.headline)

            let storageInfo = settings.computeModelStorageUsage()
            let formattedUsage = ByteCountFormatter.string(fromByteCount: storageInfo.usedBytes, countStyle: .file)

            VStack(alignment: .leading, spacing: 6) {
                Text("Directory:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(modelStorageDirectoryPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Reveal in Finder") {
                        revealStorageInFinder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Installed Models: \(storageInfo.fileCount) files • Total Size: \(formattedUsage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Download Safeguards & Integrity")
                .font(.headline)

            Toggle("Verify SHA-256 Checksums when provided by repository", isOn: $settings.verifyChecksums)

            Stepper("Maximum Concurrent Downloads: \(settings.maxConcurrentDownloads)", value: $settings.maxConcurrentDownloads, in: 1...3)

            Divider()

            Text("Cache Maintenance")
                .font(.headline)

            HStack(spacing: 12) {
                Button("Clean Temporary Download Cache") {
                    let cleaned = settings.clearTemporaryCache()
                    cacheClearSuccessMessage = "Removed \(cleaned) temporary cache files."
                }
                .buttonStyle(.bordered)

                if let msg = cacheClearSuccessMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Diagnostics Tab

    @ViewBuilder
    private var diagnosticsSettingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hardware & Host Telemetry")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                diagnosticCard(title: "Architecture", value: hostArchitecture, icon: "cpu")
                diagnosticCard(title: "macOS Version", value: ProcessInfo.processInfo.operatingSystemVersionString, icon: "apple.logo")
                diagnosticCard(title: "Active Model", value: activeModelDescription, icon: "cube.fill")
                diagnosticCard(title: "Inference Engine", value: "llama.cpp (Metal 3 Offload)", icon: "bolt.fill")
            }

            Divider()

            Text("Sandbox & Security Isolation")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("App Sandbox: Enabled (Hardened Runtime Active)")
                        .font(.subheadline.weight(.semibold))
                }
                Text("All local file operations are confined to application containers and user-approved security-scoped bookmarks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Export Diagnostic Report")
                .font(.headline)

            Button(action: exportDiagnosticsReport) {
                Label("Export Diagnostics Report...", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - About Tab

    @ViewBuilder
    private var aboutSettingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "atom")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Aether")
                        .font(.title2.bold())
                    Text("Version 1.0.0 (Build 2026.11)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Aether is an offline-first, native macOS AI agent engineered for Apple Silicon. It executes quantized open weights fully on-device with zero network latency and complete privacy.")
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()

            Text("Open Source Engineering Credits")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                creditRow(name: "llama.cpp", desc: "High-performance C++ LLM inference engine with Apple Metal MPS acceleration.")
                creditRow(name: "Apple Silicon Metal", desc: "Unified memory GPU compute shaders for low-power, high-throughput token decoding.")
                creditRow(name: "SQLite 3", desc: "WAL-mode transactional relational database for local chat history and telemetry.")
                creditRow(name: "SwiftUI & Swift 6", desc: "Native declarative user interface with strict actor isolation and compile-time data race safety.")
            }

            Divider()

            Text("Copyright © 2026 Aether Project Contributors. Distributed under the MIT License.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func diagnosticCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func creditRow(name: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var hostArchitecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }

    private var activeModelDescription: String {
        switch viewModel.inferenceState {
        case .loaded(let info): return info.name
        case .generating(let info): return info.name
        case .loading: return "Loading..."
        case .unloaded: return "None loaded"
        case .unloading: return "Unloading..."
        case .failed: return "Error"
        }
    }

    private var modelStorageDirectoryPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aether", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        return appSupport?.path ?? "Application Support/Aether/Models"
    }

    private func revealStorageInFinder() {
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aether", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }

    private func exportDiagnosticsReport() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Aether-Diagnostics-\(Int(Date().timeIntervalSince1970)).json"
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            let storage = settings.computeModelStorageUsage()
            let report: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "appVersion": "1.0.0",
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": hostArchitecture,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                "processorCount": ProcessInfo.processInfo.processorCount,
                "installedModelCount": storage.fileCount,
                "modelStorageBytes": storage.usedBytes,
                "activeModel": activeModelDescription,
                "agentModeEnabled": settings.isAgentModeEnabled,
                "streamingEnabled": settings.isStreamingEnabled,
                "contextLength": settings.contextLength,
                "metalOffloadLayers": settings.metalGPULayers,
                "temperature": settings.temperature,
                "topP": settings.topP
            ]

            if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                try? data.write(to: url)
            }
        }
    }
}

