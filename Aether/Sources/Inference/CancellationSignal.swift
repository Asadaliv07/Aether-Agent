import Foundation

/// A thread-safe, heap-allocated atomic cancellation signal backed by a C11 atomic boolean flag.
///
/// Designed to provide immediate cross-thread cancellation without waiting for actor mailboxes
/// or queue dispatch. Can be safely passed to `llama.cpp`'s `ggml_abort_callback` via `rawPointer`.
public final class CancellationSignal: @unchecked Sendable {
    /// Opaque pointer to the heap-allocated C11 atomic flag.
    private let flag: OpaquePointer?

    public init() {
        self.flag = aether_atomic_flag_create()
    }

    deinit {
        if let flag {
            aether_atomic_flag_destroy(flag)
        }
    }

    /// Synchronously signals cancellation to the background worker and any native abort callback.
    public func cancel() {
        guard let flag else { return }
        aether_atomic_flag_set(flag, true)
    }

    /// Inspects whether cancellation has been requested.
    public var isCancelled: Bool {
        guard let flag else { return false }
        return aether_atomic_flag_get(flag)
    }

    /// Provides the raw pointer suitable for `llama_set_abort_callback(ctx, aether_abort_callback, rawPointer)`.
    ///
    /// The caller must ensure that the `CancellationSignal` instance outlives all native operations.
    internal var rawPointer: UnsafeMutableRawPointer? {
        guard let flag else { return nil }
        return UnsafeMutableRawPointer(flag)
    }
}
