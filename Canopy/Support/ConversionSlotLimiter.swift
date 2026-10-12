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
///
/// While macOS reports memory pressure the limiter drops to one slot no
/// matter what `setLimit` asked for: encodes already running finish, but
/// new ones start one at a time until the system recovers, then the
/// configured limit comes back on its own.
actor ConversionSlotLimiter {
    static let shared = ConversionSlotLimiter()

    private var limit = 2
    private var underMemoryPressure = false
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let pressureSource: DispatchSourceMemoryPressure

    private var effectiveLimit: Int { underMemoryPressure ? 1 : limit }

    /// How many callers are queued for a slot.
    var waitingCount: Int { waiters.count }

    init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility)
        )
        pressureSource = source
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            Task { await self?.setMemoryPressure(!event.intersection([.warning, .critical]).isEmpty) }
        }
        source.resume()
    }

    deinit { pressureSource.cancel() }

    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        drain()
    }

    func setMemoryPressure(_ pressured: Bool) {
        underMemoryPressure = pressured
        drain()
    }

    func acquire() async {
        if inUse < effectiveLimit {
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
        while inUse < effectiveLimit, !waiters.isEmpty {
            inUse += 1
            waiters.removeFirst().resume()
        }
    }
}
