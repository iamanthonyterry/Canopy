import Foundation

/// A minimal FIFO handoff queue between one producer and several concurrent
/// consumers — used to let a device's Sync step hand each file to its
/// Convert step the moment it's downloaded, instead of waiting for every
/// file to finish downloading first. Same lightweight-actor style as
/// `ConversionSlotLimiter`, used instead of `AsyncStream` since this
/// codebase doesn't rely on `AsyncStream` anywhere else and a small
/// purpose-built actor is easier to reason about here than depending on
/// `AsyncStream`'s multi-consumer behavior.
actor PipelineQueue<Element: Sendable> {
    private var buffer: [Element] = []
    private var waiters: [CheckedContinuation<Element?, Never>] = []
    private var isFinished = false

    /// Adds an item, handing it straight to a waiting consumer if one
    /// exists rather than buffering it.
    func push(_ element: Element) {
        guard !waiters.isEmpty else {
            buffer.append(element)
            return
        }
        waiters.removeFirst().resume(returning: element)
    }

    /// Signals no more items are coming — every consumer's in-flight or
    /// future `next()` call returns nil once the buffer is drained.
    func finish() {
        isFinished = true
        guard !waiters.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }

    /// Returns the next item, waiting for one to be pushed if the buffer is
    /// empty, or nil once the queue is finished and drained. Safe to call
    /// from multiple concurrent consumers — each call claims one item.
    func next() async -> Element? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if isFinished { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
