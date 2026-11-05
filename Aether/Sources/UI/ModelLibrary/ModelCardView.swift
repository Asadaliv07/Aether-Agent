import SwiftUI

/// Component view rendering a single cataloged model card with metadata badges,
/// readiness indicators, and user actions.
public struct ModelCardView: View {
    public let model: ModelRecord
    public let isLoaded: Bool
    public let isLoading: Bool
    public let onSelect: () -> Void
    public let onRemove: () -> Void
    public let onInspect: () -> Void
    public let onRelink: (() -> Void)?

    public init(
        model: ModelRecord,
        isLoaded: Bool,
        isLoading: Bool,
        onSelect: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onInspect: @escaping () -> Void,
        onRelink: (() -> Void)? = nil
    ) {
        self.model = model
        self.isLoaded = isLoaded
        self.isLoading = isLoading
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onInspect = onInspect
        self.onRelink = onRelink
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: Name & Status
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: model.category.iconName)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)

                        Text(model.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Text((model.filePath as NSString).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                statusBadge
            }

            // Metadata Badges Row
            HStack(spacing: 6) {
                badge(text: model.category.rawValue, color: .indigo)
                badge(text: model.architecture.uppercased(), color: .blue)
                badge(text: model.quantization, color: .purple)
                badge(text: model.formattedFileSize, color: .secondary)

                if let params = model.parameterScale {
                    badge(text: params, color: .teal)
                }

                badge(text: "\(model.contextLength / 1024)k ctx", color: .gray)

                Spacer()
            }

            // Warning Banner if applicable
            if model.isMissing {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("File not found on disk at registered path.")
                        .font(.caption2)
                        .foregroundStyle(.orange)

                    Spacer()

                    if let onRelink {
                        Button("Relink / Re-authorize", action: onRelink)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                .padding(.vertical, 2)
            } else if case .memoryWarning(let warning) = model.compatibilityStatus {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }

            Divider()

            // Actions Row
            HStack {
                Button(action: onInspect) {
                    Label("Inspect", systemImage: "info.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()

                if isLoaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Active Model")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .fontWeight(.medium)
                    }
                } else if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(action: onSelect) {
                        Text("Load & Select")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isMissing || !model.compatibilityStatus.isUsable)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLoaded ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isLoaded ? 1.5 : 1)
        )
        .contextMenu {
            Button(action: onInspect) {
                Label("Inspect Metadata", systemImage: "info.circle")
            }

            if model.isMissing, let onRelink {
                Button(action: onRelink) {
                    Label("Relink Model File...", systemImage: "link")
                }
            }

            if !isLoaded && !model.isMissing {
                Button(action: onSelect) {
                    Label("Select Model", systemImage: "arrow.right.circle")
                }
            }

            Divider()

            Button(role: .destructive, action: onRemove) {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if model.isMissing {
            statusPill(text: "Missing", color: .red)
        } else if isLoaded {
            statusPill(text: "Loaded", color: .green)
        } else if isLoading {
            statusPill(text: "Loading", color: .blue)
        } else {
            statusPill(text: "Ready", color: .secondary)
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
