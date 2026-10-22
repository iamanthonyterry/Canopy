import Foundation
import Network

/// Carries out "apply to device" jobs queued on the website. Every few seconds it asks the site (with the
/// campus key, like the transcript feed) for jobs for this campus, sends each one to the device with the
/// device's own protocol, and reports what happened. It only ever opens connections that the site's job
/// names, only to addresses on this network, and re-checks the content before sending it.
nonisolated final class DeviceAgent: @unchecked Sendable {
    /// The current website address and key (read each time, so signing in or out takes effect at once).
    typealias Credentials = @Sendable () async -> (url: String, token: String)

    private let credentials: Credentials
    private let onResult: @Sendable (String) -> Void
    private var task: Task<Void, Never>?

    init(credentials: @escaping Credentials, onResult: @escaping @Sendable (String) -> Void) {
        self.credentials = credentials
        self.onResult = onResult
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: Polling

    struct Job: Decodable {
        var id: String
        var driver: String
        var name: String
        var host: String
        var port: Int
        var body: String?
        var scene: Int?
        var channel: Int?
    }

    private func loop() async {
        while !Task.isCancelled {
            let (url, token) = await credentials()
            if !token.isEmpty, let endpoint = Self.endpoint(from: url) {
                if let jobs = await fetch(endpoint, token: token) {
                    for job in jobs { await run(job, endpoint: endpoint, token: token) }
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The jobs address sits next to the transcript address on the same site.
    static func endpoint(from transcriptURL: String) -> URL? {
        guard var c = URLComponents(string: transcriptURL), c.scheme == "https" || c.host == "127.0.0.1" || c.host == "localhost" else { return nil }
        c.path = "/api/device-jobs"
        c.query = nil
        return c.url
    }

    private func fetch(_ endpoint: URL, token: String) async -> [Job]? {
        var req = URLRequest(url: endpoint, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, res) = try? await URLSession.shared.data(for: req), (res as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Reply: Decodable { var jobs: [Job] }
        return try? JSONDecoder().decode(Reply.self, from: data).jobs
    }

    private func report(_ id: String, ok: Bool, message: String, endpoint: URL, token: String) async {
        var req = URLRequest(url: endpoint, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": ok, "message": message])
        _ = try? await URLSession.shared.data(for: req)
    }

    private func run(_ job: Job, endpoint: URL, token: String) async {
        let outcome: (ok: Bool, message: String)
        do {
            guard Self.isLocalAddress(job.host) else { throw DeviceError("\(job.host) isn't on this network, so it was not contacted.") }
            switch job.driver {
            case "videohub":
                guard job.port == 9990, let body = job.body else { throw DeviceError("That job was incomplete.") }
                outcome = (true, try await DeviceJobVideohub.apply(host: job.host, body: body))
            case "ah-scene":
                guard job.port == 51325, let scene = job.scene, let channel = job.channel else { throw DeviceError("That job was incomplete.") }
                outcome = (true, try await DeviceJobAllenHeath.recallScene(host: job.host, scene: scene, channel: channel))
            default:
                throw DeviceError("This version of the Transcriber doesn't know how to talk to that device. Update the app.")
            }
        } catch let e as DeviceError {
            outcome = (false, e.message)
        } catch {
            outcome = (false, "Couldn't reach \(job.name).")
        }
        await report(job.id, ok: outcome.ok, message: outcome.message, endpoint: endpoint, token: token)
        onResult("\(job.name): \(outcome.message)")
    }

    /// Only devices on this network: private IPv4 ranges, link-local, loopback, or a `.local` name.
    static func isLocalAddress(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || h == "localhost" { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, h.split(separator: ".").count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (p[0], p[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

nonisolated struct DeviceError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Drivers

/// Blackmagic Videohub Ethernet Protocol 2.3: text blocks on TCP 9990. A block we send is answered with ACK or NAK.
nonisolated enum DeviceJobVideohub {
    /// Only these blocks may be sent; locks, serial directions and anything else are refused here too.
    static let allowed: Set<String> = [
        "INPUT LABELS", "OUTPUT LABELS", "MONITORING OUTPUT LABELS", "SERIAL PORT LABELS",
        "VIDEO OUTPUT ROUTING", "VIDEO MONITORING OUTPUT ROUTING", "SERIAL PORT ROUTING",
    ]

    /// Splits a file into blocks, refusing anything outside `allowed`, so the app never trusts the site blindly.
    static func blocks(_ body: String) throws -> [String] {
        var out: [String] = []
        for raw in body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
            let block = raw.trimmingCharacters(in: .newlines)
            if block.isEmpty { continue }
            let lines = block.components(separatedBy: "\n")
            guard let head = lines.first, head.hasSuffix(":"), allowed.contains(String(head.dropLast())) else {
                throw DeviceError("The file contains something a Videohub config may not change.")
            }
            let isLabels = head.contains("LABELS")
            for line in lines.dropFirst() {
                let ok = isLabels
                    ? line.range(of: #"^\d{1,3} \S.{0,59}$"#, options: .regularExpression) != nil
                    : line.range(of: #"^\d{1,3} \d{1,3}$"#, options: .regularExpression) != nil
                guard ok else { throw DeviceError("The file has a line the Videohub protocol doesn't accept.") }
            }
            out.append(block + "\n\n")
        }
        guard !out.isEmpty, out.count <= 7 else { throw DeviceError("The file has nothing to apply.") }
        return out
    }

    static func apply(host: String, port: Int = 9990, body: String) async throws -> String {
        let blocks = try blocks(body)
        let payload = Data(blocks.joined().utf8)
        let reply = try await TCP.exchange(host: host, port: port, send: payload, timeout: 8) { data in
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            return lines.filter { $0 == "ACK" || $0 == "NAK" }.count >= blocks.count
        }
        let text = String(decoding: reply, as: UTF8.self)
        guard text.contains("PROTOCOL PREAMBLE") else { throw DeviceError("\(host) didn't answer like a Videohub.") }
        // The Videohub software answers even with no hardware behind it, and ACKs anything. Don't call that success.
        if text.contains("Device present: false") { throw DeviceError("\(host) has no Videohub attached (the Videohub software is running but sees no unit).") }
        if text.contains("Device present: needs") { throw DeviceError("The Videohub at \(host) needs a firmware update before it can be changed.") }
        let lines = text.components(separatedBy: "\n")
        let acks = lines.filter { $0 == "ACK" }.count
        let naks = lines.filter { $0 == "NAK" }.count
        if naks > 0 { throw DeviceError("The Videohub rejected \(naks) of \(blocks.count) blocks.") }
        guard acks >= blocks.count else { throw DeviceError("The Videohub didn't confirm every block (\(acks) of \(blocks.count)).") }
        return "Applied \(blocks.count) \(blocks.count == 1 ? "block" : "blocks") to the Videohub."
    }
}

/// Allen & Heath dLive and Avantis MIDI over TCP (port 51325, no encryption): a bank select then a program
/// change on the console's base MIDI channel recalls a scene. Scenes 1–128 are bank 0, 129–256 bank 1, and so on.
nonisolated enum DeviceJobAllenHeath {
    static func message(scene: Int, channel: Int) -> Data? {
        guard (1...500).contains(scene), (1...12).contains(channel) else { return nil }
        let index = scene - 1
        let n = UInt8(channel - 1)
        return Data([0xB0 | n, 0x00, UInt8(index / 128), 0xC0 | n, UInt8(index % 128)])
    }

    static func recallScene(host: String, scene: Int, channel: Int) async throws -> String {
        guard let bytes = message(scene: scene, channel: channel) else { throw DeviceError("That scene number isn't valid.") }
        // The console doesn't acknowledge a recall; it just does it. Give it a moment before closing.
        _ = try await TCP.exchange(host: host, port: 51325, send: bytes, timeout: 0.6) { _ in false }
        return "Sent the recall for scene \(scene). Check that the console shows it."
    }
}

// MARK: - TCP

nonisolated enum TCP {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var finished = false
        var continuation: CheckedContinuation<Data, Error>?
        func append(_ d: Data) -> Data { lock.withLock { data.append(d); return data } }
        func finish(_ result: Result<Data, Error>) -> Bool {
            let c: CheckedContinuation<Data, Error>? = lock.withLock {
                if finished { return nil }
                finished = true
                defer { continuation = nil }
                return continuation
            }
            guard let c else { return false }
            switch result {
            case .success(let d): c.resume(returning: d)
            case .failure(let e): c.resume(throwing: e)
            }
            return true
        }
    }

    /// Opens a TCP connection, sends `send`, and collects what comes back until `done` says it has enough, the
    /// device closes, or `timeout` passes (which returns whatever arrived; the caller decides if that's enough).
    /// Fails only when the device can't be reached.
    static func exchange(host: String, port: Int, send: Data, timeout: TimeInterval, done: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw DeviceError("Bad port.") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let box = Box()
            box.continuation = cont
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let queue = DispatchQueue(label: "device.tcp")
            @Sendable func end(_ r: Result<Data, Error>) {
                if box.finish(r) { conn.cancel() }
            }
            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        if done(box.append(data)) { return end(.success(box.lock.withLock { box.data })) }
                    }
                    if isComplete || error != nil { return end(.success(box.lock.withLock { box.data })) }
                    receive()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: send, completion: .contentProcessed { error in
                        if error != nil { end(.failure(DeviceError("Couldn't send to \(host)."))) } else { receive() }
                    })
                case .failed, .waiting:
                    end(.failure(DeviceError("Can't reach \(host) on port \(port). Check its IP address and that this Mac is on the same network.")))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { end(.success(box.lock.withLock { box.data })) }
            conn.start(queue: queue)
        }
    }
}
