import SwiftUI
import AppKit

/// Comprehensive model detail sheet presenting full technical specifications, hardware suitability,
/// official links, capabilities, and multi-quantization file selection.
public struct ModelDetailSheet: View {
    public let model: ComprehensiveModelMetadata
    public let isInstalled: Bool
    public let activeDownloads: [UUID: DownloadProgress]
    public let onDownloadVariant: (ModelQuantizationVariant) -> Void
    public let onLoadModel: (() -> Void)?
    @Binding var isPresented: Bool

    @State private var selectedVariantId: String?

    public init(
        model: ComprehensiveModelMetadata,
        isInstalled: Bool,
        activeDownloads: [UUID: DownloadProgress],
        onDownloadVariant: @escaping (ModelQuantizationVariant) -> Void,
        onLoadModel: (() -> Void)? = nil,
        isPresented: Binding<Bool>
    ) {
        self.model = model
        self.isInstalled = isInstalled
        self.activeDownloads = activeDownloads
        self.onDownloadVariant = onDownloadVariant
        self.onLoadModel = onLoadModel
        self._isPresented = isPresented
        self._selectedVariantId = State(initialValue: model.availableQuantizations.first?.id)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header Section
                    headerSection

                    Divider()

                    // Hardware Suitability Assessment Banner
                    hardwareSuitabilityBanner

                    // Description & Capabilities
                    descriptionSection

                    // Technical Specifications Grid
                    specsGridSection

                    // Available Quantizations & Variants
                    if !model.availableQuantizations.isEmpty {
                        variantsSection
                    }

                    // Source and License Info
                    sourceAndLicenseSection
                }
                .padding(24)
            }
            .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 640)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.displayName)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: model.taskType.iconName)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(model.parameterCount)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                HStack(spacing: 6) {
                    Text(model.publisher)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(model.modelFamily)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(model.taskType.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(model.repositoryId)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isInstalled {
                Button(action: {
                    onLoadModel?()
                    isPresented = false
                }) {
                    Label("Load Model", systemImage: "play.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    @ViewBuilder
    private var hardwareSuitabilityBanner: some View {
        let suitability = DeviceCapabilityEngine.evaluateSuitability(model: model)
        let profile = DeviceCapabilityEngine.getProfile()

        HStack(spacing: 12) {
            Image(systemName: suitability.isSmoothlyPlayable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(suitability.isSmoothlyPlayable ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(suitability.badgeText)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(profile.summaryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Minimum \(model.hardwareRequirements.minimumRAMFormatted) Unified Memory required (Recommended: \(model.hardwareRequirements.recommendedRAMFormatted)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About this Model")
                .font(.headline)

            Text(model.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.primaryCapabilities.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.primaryCapabilities, id: \.self) { cap in
                        Text(cap)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var specsGridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Technical Specifications")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                specItem(label: "Architecture", value: model.architecture)
                specItem(label: "Context Window", value: model.formattedContextWindow)
                specItem(label: "Format", value: model.modelFormat.rawValue)
                specItem(label: "Default Quantization", value: model.defaultQuantization)
                specItem(label: "Inference Engine", value: model.supportedInferenceEngines.map { $0.badgeLabel }.joined(separator: ", "))
                specItem(label: "License", value: model.license)
            }
        }
    }

    @ViewBuilder
    private func specItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var variantsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Available Quantizations & Download Options")
                .font(.headline)

            Text("Quantization balances inference speed and memory footprint against mathematical precision. Q4_K_M is the recommended balance for most Apple Silicon Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(model.availableQuantizations) { variant in
                    variantRow(variant)
                }
            }
        }
    }

    @ViewBuilder
    private func variantRow(_ variant: ModelQuantizationVariant) -> some View {
        let isDownloading = activeDownloads.values.contains { $0.filename == variant.filename && $0.repoId == model.repositoryId }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(variant.quantization)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    if let bits = variant.bitDepthLabel {
                        Text(bits)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(variant.formattedSize)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }

                Text(variant.qualityDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloading {
                Text("Downloading...")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if !model.compatibilityStatus.isExecutableLocally {
                Text(model.compatibilityStatus.badgeLabel)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                Button(action: {
                    onDownloadVariant(variant)
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var sourceAndLicenseSection: some View {
        HStack {
            Link(destination: model.officialSourceURL) {
                Label("View on Official Repository", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }

            Spacer()

            Text("Verified: \(model.lastVerificationDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

