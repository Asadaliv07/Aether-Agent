import AppKit
import Foundation

/// Application delegate managing native macOS lifecycle events, clean termination,
/// and deterministic resource release before process exit.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillTerminate(_ notification: Notification) {
        // Deterministically shut down all native llama.cpp workers and contexts.
        // This frees all Metal command buffers and residency sets before static C++ destructors run,
        // preventing GGML_ASSERT([rsets->data count] == 0) and SIGABRT crashes.
        LlamaInferenceWorker.shutdownAll()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

