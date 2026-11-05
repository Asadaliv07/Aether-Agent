import SwiftUI

/// Main native application shell view implementing the Phase 3.5 chat interface.
///
/// Features a two-column `NavigationSplitView` with conversations and model readiness
/// in the sidebar, interactive message stream and composer in the detail area,
/// and an inspectable sheet for system foundation telemetry.
public struct ContentView: View {
    @Bindable var state: AppState
    @State private var showSystemTelemetry: Bool = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        NavigationSplitView {
            ConversationSidebarView(
                viewModel: state.chatViewModel,
                showSystemTelemetry: $showSystemTelemetry
            )
        } detail: {
            ChatView(viewModel: state.chatViewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await state.chatViewModel.initialize()
        }
        .sheet(isPresented: $showSystemTelemetry) {
            SystemTelemetrySheet(state: state, isPresented: $showSystemTelemetry)
        }
    }
}

// MARK: - Foundation & Telemetry Sheet

public struct SystemTelemetrySheet: View {
    let state: AppState
    @Binding var isPresented: Bool

    public var body: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("Aether System Telemetry")
                        .font(.headline)
                }

                Spacer()

                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Host Hardware & Sandbox Telemetry")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        FoundationBadge(
                            title: "Hardware Architecture",
                            value: state.architecture,
                            systemImage: "cpu",
                            statusColor: .blue
                        )

                        FoundationBadge(
                            title: "Operating System",
                            value: state.operatingSystemVersion,
                            systemImage: "apple.logo",
                            statusColor: .purple
                        )

                        FoundationBadge(
                            title: "App Sandbox Policy",
                            value: state.sandboxPolicy,
                            systemImage: "lock.shield",
                            statusColor: .green
                        )

                        FoundationBadge(
                            title: "Target Deployment Baseline",
                            value: "macOS 14.0 (Sonoma)+",
                            systemImage: "macwindow",
                            statusColor: .teal
                        )
                    }

                    Text(state.sandboxPolicyDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("Phase 3.5 Integration Status")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(spacing: 8) {
                        MilestoneRow(
                            code: "M3.1",
                            name: "Minimal Project Foundation",
                            description: "SwiftUI native target, Swift 6 mode, App Sandbox",
                            isComplete: true
                        )

                        MilestoneRow(
                            code: "M3.4",
                            name: "Inference Engine & Metal 3",
                            description: "Pinned llama.cpp, actor-isolated worker, token streaming, cancellation",
                            isComplete: true
                        )

                        MilestoneRow(
                            code: "M3.5",
                            name: "Native Chat Interface & SQLite Persistence",
                            description: "NavigationSplitView, WAL SQLite database, interrupted recovery",
                            isComplete: true
                        )
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}

// MARK: - Milestone Row Helper

private struct MilestoneRow: View {
    let code: String
    let name: String
    let description: String
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(code)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isComplete ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                .foregroundStyle(isComplete ? Color.green : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
