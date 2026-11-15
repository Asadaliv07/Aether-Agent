import SwiftUI

/// Professional information card rendering an AI model from the comprehensive catalogue.
public struct ModelHubCardView: View {
    public let model: ComprehensiveModelMetadata
    public let isInstalled: Bool
    public let activeDownloads: [UUID: DownloadProgress]
    public let onInspect: (ComprehensiveModelMetadata) -> Void
    public let onDownloadVariant: (ModelQuantizationVariant) -> Void
    public let onLoadModel: (() -> Void)?

    public init(
        model: ComprehensiveModelMetadata,
        isInstalled: Bool,
        activeDownloads: [UUID: DownloadProgress],
        onInspect: @escaping (ComprehensiveModelMetadata) -> Void,
        onDownloadVariant: @escaping (ModelQuantizationVariant) -> Void,
        onLoadModel: (() -> Void)? = nil
    ) {
        self.model = model
        self.isInstalled = isInstalled
        self.activeDownloads = activeDownloads
        self.onInspect = onInspect
        self.onDownloadVariant = onDownloadVariant
        self.onLoadModel = onLoadModel
    }

    private var activeDownload: DownloadProgress? {
        activeDownloads.values.first { $0.repoId == model.repositoryId }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row: Category Icon, Title, Publisher, Parameter count
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: model.taskType.iconName)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if model.isPopular {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .help("Popular model")
                        }
                    }

                    HStack(spacing: 4) {
                        Text(model.publisher)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(model.modelFamily)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Parameter Scale badge
                Text(model.parameterCount)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }

            // Description
            Text(model.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Technical Badges Row (Context, Engine, Size, Hardware Suitability)
            let suitability = DeviceCapabilityEngine.evaluateSuitability(model: model)
            HStack(spacing: 6) {
                badge(text: model.formattedContextWindow, icon: "text.word.spacing")
                badge(text: model.defaultQuantization, icon: "number")
                badge(text: model.formattedSize, icon: "arrow.down.circle")

                Spacer()

                // Suitability pill
                suitabilityPill(suitability)
            }

            Divider()

            // Footer Actions & Active Download Bar
            if let download = activeDownload {
                downloadProgressBar(download)
            } else {
                HStack {
                    Button(action: {
                        onInspect(model)
                    }) {
                        Label("Details & Specs", systemImage: "info.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    if isInstalled {
                        Button(action: {
                            onLoadModel?()
                        }) {
                            Label("Load Model", systemImage: "play.fill")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if !model.compatibilityStatus.isExecutableLocally {
                        Text(model.compatibilityStatus.badgeLabel)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    } else if let variant = model.availableQuantizations.first {
                        Button(action: {
                            onDownloadVariant(variant)
                        }) {
                            Label("Download (\(variant.formattedSize))", systemImage: "arrow.down")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isInstalled ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func badge(text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private func suitabilityPill(_ suitability: ModelHardwareSuitability) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(suitability.isSmoothlyPlayable ? Color.green : Color.orange)
                .frame(width: 5, height: 5)
            Text(suitability.badgeText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(suitability.isSmoothlyPlayable ? Color.primary : Color.orange)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((suitability.isSmoothlyPlayable ? Color.green : Color.orange).opacity(0.1))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func downloadProgressBar(_ download: DownloadProgress) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(download.status.rawValue.capitalized)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(Int(download.fractionCompleted * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: download.fractionCompleted)
                .progressViewStyle(.linear)
        }
    }
}

