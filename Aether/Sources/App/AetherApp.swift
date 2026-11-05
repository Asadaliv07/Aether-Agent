import SwiftUI

/// Main application entry point for Aether.
///
/// Configured for macOS 14.0+ using modern Swift 6 SwiftUI app lifecycle.
@main
struct AetherApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 580)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Aether") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.applicationName: "Aether",
                            NSApplication.AboutPanelOptionKey.version: "0.1.0",
                            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 Aether Authors"
                        ]
                    )
                }
            }
        }
    }
}
