import SwiftUI

/// Reusable status badge component adhering to macOS Human Interface Guidelines.
public struct FoundationBadge: View {
    public let title: String
    public let value: String
    public let systemImage: String
    public let statusColor: Color

    public init(
        title: String,
        value: String,
        systemImage: String,
        statusColor: Color = .green
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.statusColor = statusColor
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }
}
