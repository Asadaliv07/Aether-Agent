import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Native sheet displaying the catalog of local models, Hugging Face model discovery,
/// metadata details, active download progress, and management controls.
public struct ModelLibraryView: View {
    @Bindable var viewModel: ChatViewModel
    @Binding var isPresented: Bool

    @State private var searchText: String = ""
    @State private var modelPendingRemoval: ModelRecord?
    @State private var modelForInspection: ModelRecord?
    @State private var modelForRemoteInspection: HuggingFaceModel?
    @State private var showRemovalConfirmation: Bool = false
    @State private var showInspectionSheet: Bool = false
    @State private var showRemoteInspectionSheet: Bool = false

    private let quickArchitectures = ["All", "Llama", "Qwen", "Gemma", "Mistral", "Phi"]
    private let quickCategories: [(title: String, category: ModelCategory?)] = [
        ("All", nil),
        ("Coding", .coding),
        ("Assistant", .generalAssistant),
        ("Reasoning", .reasoning),
        ("Math", .math)
    ]

    public init(viewModel: ChatViewModel, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Selection Bar
                Picker("Library Mode", selection: $viewModel.selectedLibraryTab) {
                    ForEach(ModelLibraryTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()

                // Active Downloads Banner (Visible across both tabs when downloads exist)
                if !viewModel.activeDownloads.isEmpty {
                    activeDownloadsSection
                    Divider()
                }

                // Tab Content
                switch viewModel.selectedLibraryTab {
                case .installed:
                    installedModelsContent
                case .discover:
                    discoverHuggingFaceContent
                }

                Divider()

                // Footer Bar
                footerBar
            }
            .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Model Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
            .task(id: viewModel.selectedLibraryTab) {
                if viewModel.selectedLibraryTab == .discover && viewModel.huggingFaceModels.isEmpty {
                    await viewModel.searchRemoteCatalog()
                }
            }
            .confirmationDialog(
                "Remove '\(modelPendingRemoval?.name ?? "Model")' from Library?",
                isPresented: $showRemovalConfirmation,
                presenting: modelPendingRemoval
            ) { model in
                Button("Remove from Catalog", role: .destructive) {
                    Task {
                        await viewModel.removeModelFromCatalog(id: model.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes the model entry from Aether's catalog. The model file on disk will NOT be deleted.")
            }
            .sheet(isPresented: $showInspectionSheet) {
                if let model = modelForInspection {
                    ModelInspectionView(model: model, isPresented: $showInspectionSheet)
                }
            }
            .sheet(isPresented: $showRemoteInspectionSheet) {
                if let model = modelForRemoteInspection {
                    RemoteModelInspectionView(
                        model: model,
                        activeDownloads: viewModel.activeDownloads,
                        onDownloadFile: { file in
                            Task {
                                await viewModel.startModelDownload(model: model, file: file)
                            }
                        },
                        isPresented: $showRemoteInspectionSheet
                    )
                }
            }
        }
    }

    // MARK: - Installed Models Tab

    @ViewBuilder
    private var installedModelsContent: some View {
        VStack(spacing: 0) {
            // Local Search Bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search installed models by name, architecture, or quantization...", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            if filteredModels.isEmpty {
                if viewModel.catalogModels.isEmpty {
                    emptyCatalogView
                } else {
                    noSearchResultsView
                }
            } else {
                modelListView
            }
        }
    }

    private var filteredModels: [ModelRecord] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.catalogModels
        }
        let query = searchText.lowercased()
        return viewModel.catalogModels.filter { model in
            model.displayName.lowercased().contains(query) ||
            model.name.lowercased().contains(query) ||
            model.architecture.lowercased().contains(query) ||
            model.quantization.lowercased().contains(query) ||
            model.category.rawValue.lowercased().contains(query) ||
            (model.parameterScale?.lowercased().contains(query) ?? false) ||
            model.filePath.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var modelListView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 12) {
                ForEach(filteredModels) { model in
                    let isLoaded = isModelCurrentlyLoaded(model)
                    let isLoading = viewModel.isModelLoading && viewModel.loadingModelPath == model.filePath

                    ModelCardView(
                        model: model,
                        isLoaded: isLoaded,
                        isLoading: isLoading,
                        onSelect: {
                            Task {
                                await viewModel.selectAndLoadModel(model: model)
                            }
                        },
                        onRemove: {
                            modelPendingRemoval = model
                            showRemovalConfirmation = true
                        },
                        onInspect: {
                            modelForInspection = model
                            showInspectionSheet = true
                        },
                        onRelink: {
                            promptRelink(for: model)
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var emptyCatalogView: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 72, height: 72)
                Image(systemName: "cpu")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("No Local Models Installed")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Discover and download compatible GGUF models directly from Hugging Face,\nor add existing local GGUF models from your drive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: {
                    viewModel.selectedLibraryTab = .discover
                }) {
                    Label("Discover on Hugging Face", systemImage: "sparkle.magnifyingglass")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(action: promptAddLocalModel) {
                    Label("Add Local File...", systemImage: "plus")
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var noSearchResultsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No models matching '\(searchText)'")
                .font(.headline)
            Text("Try searching by architecture (e.g. 'qwen2', 'llama') or quantization ('Q4_K_M').")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Discover Hugging Face Tab

    @ViewBuilder
    private var discoverHuggingFaceContent: some View {
        VStack(spacing: 0) {
            // Search & Filter Bar
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search Hugging Face models by name, author, or keywords...", text: $viewModel.remoteSearchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            Task {
                                await viewModel.searchRemoteCatalog()
                            }
                        }

                    if !viewModel.remoteSearchQuery.isEmpty {
                        Button(action: {
                            viewModel.updateRemoteSearchQuery("")
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .frame(height: 16)

                    // Sort menu
                    Menu {
                        ForEach(HuggingFaceSortOrder.allCases) { order in
                            Button(action: {
                                Task {
                                    await viewModel.updateRemoteSortOrder(order)
                                }
                            }) {
                                HStack {
                                    Text(order.displayName)
                                    if viewModel.selectedRemoteSortOrder == order {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption2)
                            Text(viewModel.selectedRemoteSortOrder.displayName)
                                .font(.caption)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button(action: {
                        Task {
                            await viewModel.searchRemoteCatalog()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh remote catalog")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Category Filter Chips
                HStack(spacing: 6) {
                    Text("Category:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(quickCategories, id: \.title) { item in
                        let isSelected = (item.category == nil && viewModel.selectedRemoteCategory == nil) ||
                                         (viewModel.selectedRemoteCategory == item.category)

                        Button(action: {
                            viewModel.updateRemoteCategory(item.category)
                        }) {
                            HStack(spacing: 4) {
                                if let cat = item.category {
                                    Image(systemName: cat.iconName)
                                        .font(.system(size: 9))
                                }
                                Text(item.title)
                                    .font(.caption2)
                                    .fontWeight(isSelected ? .semibold : .regular)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }

                // Architecture Filter Chips
                HStack(spacing: 6) {
                    Text("Architecture:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(quickArchitectures, id: \.self) { arch in
                        let isSelected = (arch == "All" && viewModel.selectedRemoteArchitecture == nil) ||
                                         (viewModel.selectedRemoteArchitecture?.lowercased() == arch.lowercased())

                        Button(action: {
                            Task {
                                let newArch = arch == "All" ? nil : arch.lowercased()
                                await viewModel.updateRemoteArchitecture(newArch)
                            }
                        }) {
                            Text(arch)
                                .font(.caption2)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            // Discovery State View
            if viewModel.isSearchingRemoteCatalog {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Searching Hugging Face models...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let error = viewModel.remoteCatalogError {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("Failed to Load Models")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button("Retry Search") {
                        Task {
                            await viewModel.searchRemoteCatalog()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Spacer()
                }
            } else if viewModel.huggingFaceModels.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Hugging Face Models Found")
                        .font(.headline)
                    Text("Try adjusting your search terms or architecture filters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                remoteModelListView
            }
        }
    }

    @ViewBuilder
    private var remoteModelListView: some View {
        let installedPaths = Set(viewModel.catalogModels.map(\.filePath))

        ScrollView(.vertical) {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.displayedRemoteModels) { model in
                    HuggingFaceModelCardView(
                        model: model,
                        installedModelPaths: installedPaths,
                        activeDownloads: viewModel.activeDownloads,
                        isMetadataLoading: viewModel.repoMetadataLoading.contains(model.id),
                        metadataError: viewModel.repoMetadataErrors[model.id],
                        onRefreshMetadata: {
                            Task {
                                await viewModel.fetchAccurateSizes(for: model, forceRefresh: true)
                            }
                        },
                        onDownloadFile: { file in
                            Task {
                                await viewModel.startModelDownload(model: model, file: file)
                            }
                        },
                        onPauseDownload: { id in
                            Task {
                                await viewModel.pauseModelDownload(id: id)
                            }
                        },
                        onResumeDownload: { id in
                            Task {
                                await viewModel.resumeModelDownload(id: id)
                            }
                        },
                        onCancelDownload: { id in
                            Task {
                                await viewModel.cancelModelDownload(id: id)
                            }
                        },
                        onLoadInstalledModel: { path in
                            Task {
                                await viewModel.loadModel(path: path)
                            }
                        },
                        onInspectModel: { inspected in
                            modelForRemoteInspection = inspected
                            showRemoteInspectionSheet = true
                        }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Active Downloads Banner

    private var activeDownloadsList: [DownloadProgress] {
        viewModel.activeDownloads.values.sorted { $0.filename < $1.filename }
    }

    @ViewBuilder
    private var activeDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Downloads in Progress (\(viewModel.activeDownloads.count))", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            VStack(spacing: 6) {
                ForEach(activeDownloadsList) { download in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(download.filename)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Text(download.status.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(download.status == .failed ? .red : (download.status == .completed ? .green : .secondary))
                            }

                            ProgressView(value: download.fractionCompleted)
                                .progressViewStyle(.linear)

                            HStack {
                                Text(download.formattedProgress)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                if let err = download.errorMessage {
                                    Text(err)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                }
                            }
                        }

                        // Controls
                        HStack(spacing: 4) {
                            if download.status == .downloading {
                                Button(action: {
                                    Task { await viewModel.pauseModelDownload(id: download.id) }
                                }) {
                                    Image(systemName: "pause.circle")
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(.plain)
                                .help("Pause download")
                            } else if download.status == .paused {
                                Button(action: {
                                    Task { await viewModel.resumeModelDownload(id: download.id) }
                                }) {
                                    Image(systemName: "play.circle")
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(.plain)
                                .help("Resume download")
                            }

                            Button(action: {
                                Task { await viewModel.cancelModelDownload(id: download.id) }
                            }) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel download")
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.04))
    }

    // MARK: - Footer Bar

    @ViewBuilder
    private var footerBar: some View {
        HStack {
            if viewModel.selectedLibraryTab == .installed {
                Button(action: promptAddLocalModel) {
                    Label("Add Local Model...", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Text("\(viewModel.catalogModels.count) model\(viewModel.catalogModels.count == 1 ? "" : "s") registered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.caption2)
                    Text("Hugging Face Hub API")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)

                Spacer()

                Text("\(viewModel.huggingFaceModels.count) repositories discovered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Helpers

    private func isModelCurrentlyLoaded(_ model: ModelRecord) -> Bool {
        if case .loaded(let info) = viewModel.inferenceState {
            return info.path == model.filePath
        }
        if case .generating(let info) = viewModel.inferenceState {
            return info.path == model.filePath
        }
        return false
    }

    private func promptAddLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a compatible GGUF model file for Aether's library"
        panel.prompt = "Add to Library"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await viewModel.registerLocalModel(url: url)
            }
        }
    }

    private func promptRelink(for model: ModelRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Relink or re-authorize '\(model.displayName)'"
        panel.prompt = "Relink Model"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await viewModel.relinkModel(id: model.id, url: url)
            }
        }
    }
}

/// Inspection sheet displaying full technical metadata for a cataloged model.
public struct ModelInspectionView: View {
    public let model: ModelRecord
    @Binding var isPresented: Bool

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: model.category.iconName)
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            Text(model.displayName)
                                .font(.title2)
                                .fontWeight(.bold)
                        }

                        Text("Registered File: \(model.filePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                // Metadata Grid
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow {
                        Text("Category:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(model.category.rawValue)
                            .font(.callout)
                    }

                    if let scale = model.parameterScale {
                        GridRow {
                            Text("Parameter Scale:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(scale)
                                .font(.callout)
                        }
                    }

                    GridRow {
                        Text("Architecture:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(model.architecture)
                            .font(.callout)
                    }

                    GridRow {
                        Text("Quantization:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(model.quantization)
                            .font(.callout)
                    }

                    GridRow {
                        Text("File Size:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("\(model.formattedFileSize) (\(model.fileSize) bytes)")
                            .font(.callout)
                    }

                    GridRow {
                        Text("Trained Context:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("\(model.contextLength) tokens")
                            .font(.callout)
                    }

                    GridRow {
                        Text("Date Added:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(model.createdAt, style: .date)
                            .font(.callout)
                    }

                    if let lastUsed = model.lastUsedAt {
                        GridRow {
                            Text("Last Used:")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(lastUsed, style: .relative)
                                .font(.callout)
                        }
                    }

                    GridRow {
                        Text("File Status:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text(model.isMissing ? "⚠️ Missing on disk" : "✅ Available on disk")
                            .font(.callout)
                            .foregroundStyle(model.isMissing ? .orange : .green)
                    }
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 480, idealWidth: 520, minHeight: 340, idealHeight: 400)
            .navigationTitle("Model Metadata")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

/// Inspection sheet displaying full technical metadata, provenance, and available GGUF quantizations for a remote Hugging Face repository.
public struct RemoteModelInspectionView: View {
    public let model: HuggingFaceModel
    public let activeDownloads: [UUID: DownloadProgress]
    public let onDownloadFile: (HuggingFaceGGUFFile) -> Void
    @Binding var isPresented: Bool

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: model.category.iconName)
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            Text(model.cleanDisplayName)
                                .font(.title2)
                                .fontWeight(.bold)
                        }

                        HStack(spacing: 6) {
                            Text("Published by \(model.publisher)")
                                .font(.callout)
                                .fontWeight(.medium)

                            if model.isCommunityConversion {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Text("Converted to GGUF by \(model.quantizer ?? model.author)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("Community Conversion")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            } else {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Text("Official Publisher Release")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                            }
                        }

                        Text("Repository ID: \(model.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Description Box
                    if !model.cleanDescription.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description & Intended Use")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            Text(model.cleanDescription)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    // Model Metadata Grid
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model Specification")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            GridRow {
                                Text("Capability Category:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.category.rawValue)
                                    .font(.callout)
                            }

                            if let scale = model.parameterScale {
                                GridRow {
                                    Text("Parameter Scale:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(scale)
                                        .font(.callout)
                                }
                            }

                            if let arch = model.inferredArchitecture {
                                GridRow {
                                    Text("Architecture:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(arch.uppercased())
                                        .font(.callout)
                                }
                            }

                            if let lic = model.license {
                                GridRow {
                                    Text("License:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(lic)
                                        .font(.callout)
                                }
                            }

                            GridRow {
                                Text("Community Engagement:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(model.formattedDownloads) downloads • \(model.formattedLikes) likes")
                                    .font(.callout)
                            }

                            GridRow {
                                Text("Authoritative Source:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Link("View on Hugging Face ↗", destination: model.authoritativeCardURL)
                                    .font(.callout)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Available GGUF Quantizations Table
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Available GGUF Files (\(model.ggufFiles.count))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 6) {
                            ForEach(model.ggufFiles) { file in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(file.quantization)
                                                .font(.system(size: 13, weight: .semibold))
                                            if let bit = file.bitDepthLabel {
                                                Text(bit)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if file.isShard {
                                                Text("Split Shard")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        Text(file.filename)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(file.formattedSize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    fileCompatibilityPill(file.compatibility)

                                    Button("Download") {
                                        onDownloadFile(file)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 540, idealWidth: 600, minHeight: 480, idealHeight: 560)
            .navigationTitle("Remote Model Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fileCompatibilityPill(_ compat: ModelCompatibility) -> some View {
        switch compat {
        case .compatible:
            Text("Ready")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .memoryWarning(let w):
            Text("RAM Warning")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.15))
                .foregroundStyle(.yellow)
                .clipShape(Capsule())
                .help(w)
        case .unsupportedArchitecture:
            Text("Unsupported")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        case .unknown(let r):
            Text("Unknown")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
                .help(r)
        case .corruptHeader(let c):
            Text("Corrupt")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12))
                .foregroundStyle(.red)
                .clipShape(Capsule())
                .help(c)
        }
    }
}
