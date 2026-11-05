import SwiftUI

/// Component view rendering a discovered Hugging Face model repository card,
/// with available GGUF quantizations, compatibility badges, and download controls.
public struct HuggingFaceModelCardView: View {
    public let model: HuggingFaceModel
    public let installedModelPaths: Set<String>
    public let activeDownloads: [UUID: DownloadProgress]
    public let isMetadataLoading: Bool
    public let metadataError: String?
    public let onRefreshMetadata: (() -> Void)?
    public let onDownloadFile: (HuggingFaceGGUFFile) -> Void
    public let onPauseDownload: (UUID) -> Void
    public let onResumeDownload: (UUID) -> Void
    public let onCancelDownload: (UUID) -> Void
    public let onLoadInstalledModel: (String) -> Void
    public let onInspectModel: ((HuggingFaceModel) -> Void)?

    @State private var isExpanded: Bool = false
    @State private var showFullDescription: Bool = false

    public init(
        model: HuggingFaceModel,
        installedModelPaths: Set<String>,
        activeDownloads: [UUID: DownloadProgress],
        isMetadataLoading: Bool = false,
        metadataError: String? = nil,
        onRefreshMetadata: (() -> Void)? = nil,
        onDownloadFile: @escaping (HuggingFaceGGUFFile) -> Void,
        onPauseDownload: @escaping (UUID) -> Void,
        onResumeDownload: @escaping (UUID) -> Void,
        onCancelDownload: @escaping (UUID) -> Void,
        onLoadInstalledModel: @escaping (String) -> Void,
        onInspectModel: ((HuggingFaceModel) -> Void)? = nil
    ) {
        self.model = model
        self.installedModelPaths = installedModelPaths
        self.activeDownloads = activeDownloads
        self.isMetadataLoading = isMetadataLoading
        self.metadataError = metadataError
        self.onRefreshMetadata = onRefreshMetadata
        self.onDownloadFile = onDownloadFile
        self.onPauseDownload = onPauseDownload
        self.onResumeDownload = onResumeDownload
        self.onCancelDownload = onCancelDownload
        self.onLoadInstalledModel = onLoadInstalledModel
        self.onInspectModel = onInspectModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row: Category Icon, Clean Display Name, Publisher/Quantizer Attribution, and Actions
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: model.category.iconName)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)

                        Text(model.cleanDisplayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 5) {
                        Text(model.publisher)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        if model.isCommunityConversion {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Converted by \(model.quantizer ?? model.author)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Community")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        } else {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Official Release")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    Text(model.id)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Actions & Metrics
                HStack(spacing: 8) {
                    if let onInspect = onInspectModel {
                        Button(action: { onInspect(model) }) {
                            HStack(spacing: 3) {
                                Image(systemName: "info.circle")
                                    .font(.caption2)
                                Text("Details")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Inspect comprehensive model metadata, license, and variants")
                    }

                    Link(destination: model.authoritativeCardURL) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                            Text("Model Card")
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open official model card on Hugging Face")

                    // Downloads & Likes badges
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption2)
                            Text(model.formattedDownloads)
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.secondary)

                        HStack(spacing: 3) {
                            Image(systemName: "heart")
                                .font(.caption2)
                            Text(model.formattedLikes)
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())
                }
            }

            // Tags & Badges Row
            HStack(spacing: 6) {
                badge(text: model.category.rawValue, color: .indigo)

                if let scale = model.parameterScale {
                    badge(text: scale, color: .teal)
                }

                if let arch = model.inferredArchitecture {
                    badge(text: arch.uppercased(), color: .blue)
                }

                if let license = model.license {
                    badge(text: license, color: .purple)
                }

                badge(text: "\(model.ggufFiles.count) quant\(model.ggufFiles.count == 1 ? "" : "s")", color: .gray)

                if isMetadataLoading {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading sizes…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if let error = metadataError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 10))
                        Text("Sizes unavailable")
                            .font(.system(size: 10))
                        if let onRefreshMetadata {
                            Button("Retry", action: onRefreshMetadata)
                                .font(.system(size: 10, weight: .semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(error)
                } else if model.ggufFiles.contains(where: { $0.size <= 0 }) {
                    if let onRefreshMetadata {
                        Button(action: onRefreshMetadata) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9))
                                Text("Fetch sizes")
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Fetch accurate file sizes from Hugging Face repository tree")
                    }
                }

                if model.isGated {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text("Gated")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()
            }

            // Description preview
            let cleanDesc = model.cleanDescription
            if !cleanDesc.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cleanDesc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(showFullDescription ? nil : 2)

                    if cleanDesc.count > 120 {
                        Button(action: { showFullDescription.toggle() }) {
                            Text(showFullDescription ? "Show less" : "Show more")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Available GGUF Quantizations Table
            VStack(alignment: .leading, spacing: 8) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    HStack {
                        Text("Available GGUF Files (\(model.ggufFiles.count))")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 8) {
                        ForEach(model.ggufFiles) { file in
                            fileRow(file: file)
                        }
                    }
                    .padding(.top, 4)
                } else if let recommended = model.ggufFiles.first(where: { $0.quantization.contains("Q4_K") || $0.quantization == "Q4_0" }) ?? model.ggufFiles.first {
                    // Show recommended quant preview when collapsed
                    HStack {
                        Text("Recommended:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        fileRow(file: recommended)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Subviews & Helpers

    @ViewBuilder
    private func fileRow(file: HuggingFaceGGUFFile) -> some View {
        let isInstalled = installedModelPaths.contains(where: { $0.hasSuffix(file.filename) })
        let activeDownload = activeDownloads.values.first(where: { $0.repoId == file.repoId && $0.filename == file.filename })

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.quantization)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

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
                    .truncationMode(.middle)
            }

            Spacer()

            // File size
            if file.size > 0 {
                Text(file.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isMetadataLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Fetching size…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Text("Unknown size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let onRefreshMetadata {
                        Button(action: onRefreshMetadata) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Retry fetching size metadata")
                    }
                }
            }

            // Compatibility Pill
            compatibilityBadge(file.compatibility)

            // Action / Download Controls
            if isInstalled {
                HStack(spacing: 6) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)

                    Button("Load") {
                        if let path = installedModelPaths.first(where: { $0.hasSuffix(file.filename) }) {
                            onLoadInstalledModel(path)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else if let download = activeDownload {
                downloadControls(download: download)
            } else {
                Button(action: { onDownloadFile(file) }) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func downloadControls(download: DownloadProgress) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: download.fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(width: 80)

                Text("\(Int(download.fractionCompleted * 100))%")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            if download.status == .downloading {
                Button(action: { onPauseDownload(download.id) }) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if download.status == .paused {
                Button(action: { onResumeDownload(download.id) }) {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            Button(action: { onCancelDownload(download.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func compatibilityBadge(_ compat: ModelCompatibility) -> some View {
        switch compat {
        case .compatible:
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("Ready")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.12))
            .foregroundStyle(.green)
            .clipShape(Capsule())

        case .memoryWarning(let warning):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("RAM Warning")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.yellow.opacity(0.15))
            .foregroundStyle(.yellow)
            .clipShape(Capsule())
            .help(warning)

        case .unsupportedArchitecture(let arch):
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                Text("Unsupported")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12))
            .foregroundStyle(.red)
            .clipShape(Capsule())
            .help("Architecture '\(arch)' is not supported by the pinned llama.cpp backend.")

        case .unknown(let reason):
            HStack(spacing: 3) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9))
                Text("Unknown")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
            .help(reason)

        case .corruptHeader(let err):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 9))
                Text("Corrupt")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12))
            .foregroundStyle(.red)
            .clipShape(Capsule())
            .help(err)
        }
    }

    @ViewBuilder
    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
