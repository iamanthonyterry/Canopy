import Foundation

/// Lets Stop reach work already in flight. The engine only checks
/// `isCancelled` between files and steps, so a running curl download or
/// encode would otherwise carry on to the end of its file. Those operations
/// register a handler here and Stop calls them all.
nonisolated final class RunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }

    /// Runs `handler` on cancel (immediately if already cancelled). Call the
    /// returned closure once the operation finishes to unregister it.
    func onCancel(_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return {} }
        let id = UUID()
        handlers[id] = handler
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.handlers[id] = nil
            self?.lock.unlock()
        }
    }
}
