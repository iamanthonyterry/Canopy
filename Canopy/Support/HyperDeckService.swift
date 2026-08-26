import Foundation
import Network
import Combine

// MARK: - HyperDeck Transport State

enum HyperDeckTransport: String {
    case recording  = "record"
    case stopped    = "stopped"
    case playing    = "play"
    case unknown    = "unknown"
}

// MARK: - HyperDeck Service
// Communicates with a HyperDeck over its Ethernet protocol (TCP port 9993).
// Commands follow the plain-text HyperDeck Ethernet Protocol spec.

@MainActor
final class HyperDeckService: ObservableObject {
    @Published var transport: HyperDeckTransport = .unknown
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var lastError: String? = nil

    private let host: String
    private let port: UInt16 = 9993
    private var pollTask: Task<Void, Never>?

    /// How long a single attempt is allowed to sit waiting for a connection
    /// before we give up on it. Without this, a dropped/unreachable deck can
    /// leave the NWConnection parked in `.waiting` indefinitely (it doesn't
    /// always transition to `.failed` on its own) — which left `isBusy`
    /// stuck `true` forever and made the Record/Stop/Format buttons look
    /// frozen.
    private static let commandTimeout: Duration = .seconds(4)

    /// A single dropped packet or momentary Wi-Fi blip shouldn't surface as
    /// a hard failure to the person clicking the button — retry a couple
    /// times with a short pause before actually reporting an error.
    private static let maxAttempts = 3
    private static let retryDelay: Duration = .seconds(1)

    /// `format: confirm:` returning "200 ok" only means the deck accepted
    /// the request — the physical erase runs in the background afterward
    /// and can take well over a minute on a large SSD. These bound how long
    /// `waitForFormatCompletion` polls `slot info` for the erase to finish
    /// before the format is reported done.
    private static let formatPollInterval: Duration = .seconds(2)
    private static let formatPollTimeout: Duration = .seconds(120)

    init(host: String) {
        self.host = host
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Polling

    /// Starts polling the drive's transport state every 2 seconds so the UI
    /// reacts instantly whether recording is started from the app or manually.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchTransport()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Public Commands

    func record() async {
        await send(command: "record\n")
        await fetchTransport()
    }

    func stop() async {
        await send(command: "stop\n")
        await fetchTransport()
    }

    /// Formats the active slot. This is destructive — caller should confirm first.
    ///
    /// The HyperDeck Ethernet protocol treats `format` as a two-step handshake:
    /// the initial command only returns a `format token`, and nothing on the
    /// deck actually gets erased until that token is echoed back via
    /// `format confirm:`. Sending just the first command (as this used to do)
    /// leaves the deck waiting for a confirmation that never comes, so the
    /// button looked like it did nothing.
    func formatDrive(filesystem: String = "HFS+") async {
        isBusy = true
        defer { isBusy = false }

        // Both handshake steps run through the raw (non-isBusy-toggling)
        // path so the button/spinner stay steady for the whole operation
        // instead of flickering off between the two commands.
        await runFormatHandshake(filesystem: filesystem)
    }

    /// Formats a specific slot rather than whatever's currently active. The
    /// deck's `format` command always targets the active slot, so this
    /// switches to the requested one first (via `slot select`) and only
    /// proceeds with the format handshake if that switch is confirmed —
    /// this is what lets an OSC command name a slot (1, 2, 3, …) directly,
    /// e.g. for decks with multiple SSD bays.
    func formatDrive(slot: Int, filesystem: String = "HFS+") async {
        isBusy = true
        defer { isBusy = false }

        guard await selectSlot(slot) else { return } // lastError already set
        await runFormatHandshake(filesystem: filesystem)
    }

    /// The `format: prepare:` / `format: confirm:` handshake shared by both
    /// entry points above. See the doc comment on `formatDrive(filesystem:)`
    /// for why this can't be a single command.
    ///
    /// Both steps are sent over a single shared connection (see
    /// `attemptFormatHandshake`) rather than through the one-shot-connection
    /// `performWithRetry`/`attemptSendAndReceive` path used elsewhere. A
    /// pending format token is scoped to the TCP session that requested it —
    /// decks cancel it the moment that connection closes — so issuing
    /// `prepare` and `confirm` on two separate connections silently drops
    /// the format: the token comes back looking valid, `confirm` doesn't
    /// error, and nothing actually gets erased.
    ///
    /// Retrying only happens for failures that occur *before* `confirm` is
    /// known to have reached the deck (`canRetry` below) — once `confirm`
    /// has been sent, a retry would mean issuing a fresh `format: prepare:`
    /// while the deck could still be physically erasing the drive from the
    /// first attempt, which can corrupt it badly enough that the HyperDeck
    /// stops recognizing it.
    private func runFormatHandshake(filesystem: String) async {
        for attempt in 1...Self.maxAttempts {
            lastError = nil
            let outcome = await attemptFormatHandshake(filesystem: filesystem)
            if outcome.success {
                isConnected = true
                return
            }
            if !outcome.canRetry {
                isConnected = true
                return
            }
            if attempt < Self.maxAttempts {
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
        isConnected = false
    }

    private struct FormatAttemptOutcome {
        let success: Bool
        /// Whether it's still safe to retry with a brand-new `prepare`. Once
        /// `confirm` has been sent, this is always false — see the doc
        /// comment on `runFormatHandshake`.
        let canRetry: Bool
    }

    /// One full prepare→confirm→wait-for-erase attempt over a single
    /// connection. On failure, `lastError` is already set.
    private func attemptFormatHandshake(filesystem: String) async -> FormatAttemptOutcome {
        guard let portObj = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid port"
            return FormatAttemptOutcome(success: false, canRetry: true)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: portObj, using: .tcp)
        defer { connection.cancel() }

        guard await waitUntilReady(connection) else {
            lastError = "Timed out — device didn't respond"
            return FormatAttemptOutcome(success: false, canRetry: true)
        }

        guard let readyResponse = await sendAndRead(
            connection,
            command: "format: prepare: \(filesystem)\n",
            multilineResponse: true
        ) else {
            lastError = "Timed out — device didn't respond"
            return FormatAttemptOutcome(success: false, canRetry: true)
        }
        guard let token = formatToken(from: readyResponse) else {
            let trimmed = readyResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = trimmed.isEmpty
                ? "Format failed — deck didn't return a confirmation token"
                : "Format failed: \(trimmed)"
            return FormatAttemptOutcome(success: false, canRetry: true)
        }

        guard let confirmResponse = await sendAndRead(
            connection,
            command: "format: confirm: \(token)\n",
            multilineResponse: false
        ) else {
            // No response doesn't mean no effect: the deck may have received
            // and acted on `confirm` right before the connection dropped.
            // Poll for the outcome instead of retrying the handshake.
            lastError = "Timed out waiting for format confirmation"
            let completed = await waitForFormatCompletion()
            if !completed {
                lastError = "Couldn't confirm the format finished — check the deck before using this drive"
            }
            return FormatAttemptOutcome(success: completed, canRetry: false)
        }
        guard confirmResponse.hasPrefix("200") else {
            // The deck explicitly rejected the request before touching the
            // drive (e.g. an unsupported filesystem) — nothing to wait on.
            let trimmed = confirmResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = trimmed.isEmpty
                ? "Deck didn't confirm the format"
                : "Format failed: \(trimmed)"
            return FormatAttemptOutcome(success: false, canRetry: true)
        }

        // The 200 only means the deck accepted the request — the physical
        // erase runs in the background afterward. Wait for it to actually
        // finish before reporting success, so callers (workflow steps,
        // manual record/eject) don't touch the drive while it's still being
        // erased.
        guard await waitForFormatCompletion() else {
            lastError = "Format was confirmed but didn't finish within \(Int(Self.formatPollTimeout.components.seconds))s — check the deck before using this drive"
            return FormatAttemptOutcome(success: false, canRetry: false)
        }
        return FormatAttemptOutcome(success: true, canRetry: false)
    }

    /// Polls `slot info` after a confirmed format until the slot settles out
    /// of "empty"/"error" and holds the same status across two consecutive
    /// polls (a single sighting of e.g. "mounted" could just be a
    /// mid-transition read), or until `formatPollTimeout` elapses.
    private func waitForFormatCompletion() async -> Bool {
        let deadline = ContinuousClock.now + Self.formatPollTimeout
        var lastStableStatus: String?

        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.formatPollInterval)
            let response = await performWithRetry(command: "slot info\n", readResponse: true) ?? ""
            let status = slotStatus(from: response)

            guard let status, status != "empty", status != "error" else {
                lastStableStatus = nil
                continue
            }
            if status == lastStableStatus {
                return true
            }
            lastStableStatus = status
        }
        return false
    }

    /// Pulls the value out of `slot info`'s "status: <value>" line.
    private func slotStatus(from response: String) -> String? {
        for line in response.lowercased().components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("status:") else { continue }
            return trimmed.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Switches the deck's active slot via `slot select: slot id: {n}`.
    /// Returns false (with `lastError` set) if the deck didn't acknowledge
    /// the switch — e.g. the slot doesn't exist on this model, or is empty.
    private func selectSlot(_ slot: Int) async -> Bool {
        let response = await performWithRetry(command: "slot select: slot id: \(slot)\n", readResponse: true) ?? ""
        guard response.hasPrefix("200") else {
            if lastError == nil {
                lastError = response.isEmpty
                    ? "Couldn't reach the device to switch to slot \(slot)"
                    : "Couldn't switch to slot \(slot): \(response.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return false
        }
        return true
    }

    /// Pulls the token out of the deck's "216 format ready" response so it
    /// can be echoed back to confirm.
    ///
    /// This used to look for a `format token: <value>` line, following the
    /// protocol doc's general "parameter: value" response shape. In practice
    /// real decks don't send that — they reply with the bare "216 format
    /// ready" line followed by a second line containing *only* the token,
    /// no label at all. (Confirmed against Blackmagic's own reference
    /// implementation, which special-cases this exact response as "an edge
    /// case" for the same reason.) That mismatch is why prepare always
    /// looked like it got no token back. Still accepts a labeled "format
    /// token:" line too, in case a future firmware version sends the
    /// documented shape.
    private func formatToken(from response: String) -> String? {
        let lines = response
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let readyIndex = lines.firstIndex(where: { $0.hasPrefix("216") }),
              readyIndex + 1 < lines.count else {
            return nil
        }

        let tokenLine = lines[readyIndex + 1]
        if tokenLine.lowercased().hasPrefix("format token:") {
            return tokenLine.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)
        }
        return tokenLine
    }

    /// Convenience: create a one-shot connection, format the active slot, and discard.
    static func formatDrive(deck: HyperDeck, filesystem: String = "HFS+") async throws {
        let service = HyperDeckService(host: deck.ipAddress)
        await service.formatDrive(filesystem: filesystem)
        if let error = service.lastError {
            throw NSError(domain: "HyperDeckService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    /// Convenience: create a one-shot connection, format a specific slot, and discard.
    static func formatDrive(deck: HyperDeck, slot: Int, filesystem: String = "HFS+") async throws {
        let service = HyperDeckService(host: deck.ipAddress)
        await service.formatDrive(slot: slot, filesystem: filesystem)
        if let error = service.lastError {
            throw NSError(domain: "HyperDeckService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    /// Polled every 2 seconds in the background, so this deliberately does
    /// NOT toggle `isBusy` — doing so previously made the Record/Format
    /// buttons and their spinner flicker on and off every poll cycle even
    /// when nobody had pressed anything.
    func fetchTransport() async {
        let response = await performWithRetry(command: "transport info\n", readResponse: true) ?? ""
        isConnected = !response.isEmpty
        transport = parseTransport(from: response)
    }

    /// Checks whether a disk/SSD is actually installed in the deck, using
    /// the "slot info" command. Returns nil if the check itself couldn't be
    /// completed (e.g. connection dropped) — that's different from "no media",
    /// so callers shouldn't treat nil the same as `false`. Status check only,
    /// so it doesn't toggle `isBusy` either.
    func checkMediaPresent() async -> Bool? {
        let response = await performWithRetry(command: "slot info\n", readResponse: true) ?? ""
        guard !response.isEmpty else { return nil }
        return !response.lowercased().contains("status: empty")
    }

    /// One-shot convenience for a caller that just wants a quick check
    /// against an IP without holding onto a service instance.
    static func checkMediaPresent(host: String) async -> Bool? {
        await HyperDeckService(host: host).checkMediaPresent()
    }

    /// One-shot convenience: is this deck recording right now? Used by
    /// ConnectionMonitor's background poll so recording state is tracked
    /// continuously, not only while that deck's detail pane is open.
    static func isRecording(host: String) async -> Bool {
        let service = HyperDeckService(host: host)
        await service.fetchTransport()
        return service.transport == .recording
    }

    // MARK: - Private Networking

    /// Sends a command, retrying a couple of times if a single attempt
    /// times out or the connection drops, before finally reporting failure.
    /// Toggles `isBusy` for the duration — use this for user-initiated
    /// actions (record/stop), not for background status polling.
    private func send(command: String) async {
        isBusy = true
        defer { isBusy = false }
        _ = await performWithRetry(command: command, readResponse: false)
    }

    /// Runs a command with retry logic, without touching `isBusy`. Shared by
    /// the `isBusy`-toggling wrappers above and by callers (background
    /// polling, multi-step handshakes like format) that manage busy/loading
    /// state themselves so it doesn't flicker between steps.
    private func performWithRetry(command: String, readResponse: Bool, multilineResponse: Bool = false) async -> String? {
        for attempt in 1...Self.maxAttempts {
            lastError = nil
            if let response = await attemptSendAndReceive(command: command, readResponse: readResponse, multilineResponse: multilineResponse) {
                isConnected = true
                return response
            }
            if attempt < Self.maxAttempts {
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
        isConnected = false
        return nil
    }

    /// A single connect → send → (optionally) read attempt. Returns nil on
    /// any failure (connection error or timeout) so the caller can decide
    /// whether to retry; returns the response text (empty string if
    /// `readResponse` is false) on success.
    private func attemptSendAndReceive(command: String, readResponse: Bool, multilineResponse: Bool = false) async -> String? {
        guard let portObj = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: portObj,
            using: .tcp
        )

        return await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            let resumeOnce: @Sendable (String?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }

            // Accumulates bytes across possibly-multiple `receive` calls. A
            // single TCP read can return before the deck has finished writing
            // a multi-line response (e.g. "216 format ready" followed by a
            // separate "format token: …" line) — reading only that first
            // partial chunk is what made the format handshake look like the
            // deck never sent a token. Buffer is only touched from within
            // NWConnection's receive callbacks, which never run concurrently
            // with each other, so this is safe despite not being Sendable.
            nonisolated(unsafe) var buffer = Data()

            @Sendable func receiveMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data { buffer.append(data) }
                    var text = String(data: buffer, encoding: .utf8) ?? ""
                    let done = Self.consumeConnectionPreamble(&text) && (
                        Self.isCompleteResponse(text, multilineResponse: multilineResponse) || isComplete || error != nil
                    )
                    buffer = Data(text.utf8)

                    if done {
                        connection.cancel()
                        resumeOnce(text)
                    } else {
                        receiveMore()
                    }
                }
            }

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let data = Data(command.utf8)
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error {
                            connection.cancel()
                            Task { @MainActor in self.lastError = error.localizedDescription }
                            resumeOnce(nil)
                            return
                        }
                        guard readResponse else {
                            connection.cancel()
                            resumeOnce("")
                            return
                        }
                        receiveMore()
                    })
                case .failed(let error):
                    connection.cancel()
                    Task { @MainActor in self.lastError = error.localizedDescription }
                    resumeOnce(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            Task {
                try? await Task.sleep(for: Self.commandTimeout)
                guard !resumed else { return }
                connection.cancel()
                await MainActor.run { self.lastError = "Timed out — device didn't respond" }
                resumeOnce(nil)
            }
        }
    }

    /// Strips a leading, fully-received "500 connection info:" notification
    /// from `text` in place (see `attemptSendAndReceive` for why). Returns
    /// false if `text` looks like the start of that notification but hasn't
    /// reached its terminating blank line yet — the caller should keep
    /// reading rather than treat what it has as a real response.
    private nonisolated static func consumeConnectionPreamble(_ text: inout String) -> Bool {
        guard text.lowercased().hasPrefix("500 connection info:") else { return true }
        guard let preambleEnd = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") else {
            return false
        }
        text.removeSubrange(text.startIndex..<preambleEnd.upperBound)
        return true
    }

    /// Multi-line responses are terminated by a blank line once every
    /// parameter line has arrived; single-line acks never get one, so only
    /// wait for it when we know to expect it.
    private nonisolated static func isCompleteResponse(_ text: String, multilineResponse: Bool) -> Bool {
        let hasBlankLineTerminator = text.contains("\r\n\r\n") || text.contains("\n\n")
        return (!multilineResponse && !text.isEmpty) || hasBlankLineTerminator
    }

    /// Waits for a fresh, unstarted connection to become ready, returning
    /// false (instead of throwing) on failure or timeout so callers can
    /// decide how to report it.
    private func waitUntilReady(_ connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            let resumeOnce: @Sendable (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(true)
                case .failed:
                    resumeOnce(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            Task {
                try? await Task.sleep(for: Self.commandTimeout)
                resumeOnce(false)
            }
        }
    }

    /// Sends one command on an already-`.ready` connection and reads its
    /// reply, without closing the connection afterward — used by the format
    /// handshake so `prepare` and `confirm` share one TCP session instead of
    /// each opening (and closing) their own. Returns nil on send failure or
    /// timeout.
    private func sendAndRead(_ connection: NWConnection, command: String, multilineResponse: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            let resumeOnce: @Sendable (String?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            nonisolated(unsafe) var buffer = Data()

            @Sendable func receiveMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data { buffer.append(data) }
                    var text = String(data: buffer, encoding: .utf8) ?? ""
                    let done = Self.consumeConnectionPreamble(&text) && (
                        Self.isCompleteResponse(text, multilineResponse: multilineResponse) || isComplete || error != nil
                    )
                    buffer = Data(text.utf8)

                    if done {
                        resumeOnce(text)
                    } else {
                        receiveMore()
                    }
                }
            }

            let data = Data(command.utf8)
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    resumeOnce(nil)
                    return
                }
                receiveMore()
            })

            Task {
                try? await Task.sleep(for: Self.commandTimeout)
                resumeOnce(nil)
            }
        }
    }

    // MARK: - Response Parsing

    private func parseTransport(from response: String) -> HyperDeckTransport {
        print("[HyperDeckService] transport info response:\n\(response)")
        for line in response.lowercased().components(separatedBy: "\n") {
            if line.contains("status:") {
                if line.contains("record")  { return .recording }
                if line.contains("stopped") || line.contains("preview") { return .stopped }
                if line.contains("play")    { return .playing }
            }
        }
        return .unknown
    }
}

