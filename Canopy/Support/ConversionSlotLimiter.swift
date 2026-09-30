import Foundation

/// Caps how many hardware video encodes run at once *across the whole
/// app* — not per device, not per workflow step. A workflow's Convert step
/// already fans out across every target device concurrently, and each
/// device's own step can run several conversions in parallel (its
/// `maxParallelJobs` setting), so without this a multi-deck workflow can
/// end up launching far more simultaneous AVAssetExportSession encodes than
/// the Mac's hardware encoder can actually run at once — they just contend
/// with each other instead of adding throughput. Every caller acquires a
/// slot before starting an encode and releases it when done; `setLimit` is
/// how many can hold a slot at a time.
actor ConversionSlotLimiter {
    static let shared = ConversionSlotLimiter()

    private var limit = 2
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        drain()
    }

    func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        inUse -= 1
        drain()
    }

    private func drain() {
        while inUse < limit, !waiters.isEmpty {
            inUse += 1
            waiters.removeFirst().resume()
        }
    }
}
