import Foundation
import Network
import Combine

@MainActor
class DeviceDiscovery: ObservableObject {
    @Published var discoveredDecks: [HyperDeck] = []
    @Published var discoveredSwitchers: [BlackmagicSwitcher] = []
    @Published var discoveredCloudStores: [CloudStore] = []
    @Published var isScanning = false

    private var browsers: [NWBrowser] = []
    private let browserQueue = DispatchQueue(label: "com.churchsync.discovery", qos: .background)

    // MARK: - Public API

    func startScanning() {
        stopScanning()
        discoveredDecks.removeAll()
        discoveredSwitchers.removeAll()
        discoveredCloudStores.removeAll()
        isScanning = true

        startBrowser(type: "_ftp._tcp",        handler: handleFTPResult)
        startBrowser(type: "_blackmagic._tcp",  handler: handleBlackmagicResult)
        startBrowser(type: "_smb._tcp",         handler: handleSMBResult)
    }

    func stopScanning() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        isScanning = false
    }

    // MARK: - Browser Setup

    private func startBrowser(
        type: String,
        handler: @escaping @Sendable (NWBrowser.Result) async -> Void
    ) {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: type, domain: "local."),
            using: params
        )

        // Use the `changes` diff instead of the full result set so we only
        // process genuinely new endpoints — avoids duplicate resolution tasks.
        browser.browseResultsChangedHandler = { _, changes in
            for change in changes {
                if case let .added(result) = change {
                    Task { await handler(result) }
                }
            }
        }
        browser.start(queue: browserQueue)
        browsers.append(browser)
    }

    // MARK: - Result Handlers

    private func handleFTPResult(_ result: NWBrowser.Result) async {
        let name = result.endpoint.serviceName ?? "HyperDeck"
        let lower = name.lowercased()
        guard lower.contains("hyperdeck") || lower.contains("iso") || lower.contains("extreme") else { return }

        guard let ip = await resolveIP(for: result.endpoint), !ip.isEmpty else { return }
        guard !discoveredDecks.contains(where: { $0.ipAddress == ip }) else { return }

        discoveredDecks.append(HyperDeck(name: name, ipAddress: ip, remotePath: "usb/Extreme Pro"))
    }

    private func handleBlackmagicResult(_ result: NWBrowser.Result) async {
        let name = result.endpoint.serviceName ?? "ATEM Switcher"

        guard let ip = await resolveIP(for: result.endpoint), !ip.isEmpty else { return }
        guard !discoveredSwitchers.contains(where: { $0.ipAddress == ip }) else { return }

        let model = name.contains("ATEM") ? name : "ATEM Switcher"
        discoveredSwitchers.append(BlackmagicSwitcher(name: name, ipAddress: ip, model: model))
    }

    private func handleSMBResult(_ result: NWBrowser.Result) async {
        let name = result.endpoint.serviceName ?? ""
        let lower = name.lowercased()
        guard lower.contains("cloud") || lower.contains("blackmagic") else { return }

        guard let ip = await resolveIP(for: result.endpoint), !ip.isEmpty else { return }
        guard !discoveredCloudStores.contains(where: { $0.ipAddress == ip }) else { return }

        discoveredCloudStores.append(CloudStore(name: name, ipAddress: ip, volumeName: name))
    }

    // MARK: - IP Resolution

    private func resolveIP(for endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            final class ResolveState: @unchecked Sendable { var resolved = false }
            let state = ResolveState()
            let conn = NWConnection(to: endpoint, using: .tcp)

            conn.stateUpdateHandler = { connectionState in
                guard !state.resolved else { return }
                switch connectionState {
                case .ready:
                    state.resolved = true
                    let ip: String?
                    if let remote = conn.currentPath?.remoteEndpoint,
                       case let .hostPort(host, _) = remote {
                        let raw = "\(host)"
                        ip = raw.components(separatedBy: "%").first
                    } else {
                        ip = nil
                    }
                    conn.cancel()
                    continuation.resume(returning: ip)
                case .failed:
                    state.resolved = true
                    conn.cancel()
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }

            conn.start(queue: browserQueue)

            browserQueue.asyncAfter(deadline: .now() + 5) {
                guard !state.resolved else { return }
                state.resolved = true
                conn.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

// MARK: - NWEndpoint helper

private extension NWEndpoint {
    var serviceName: String? {
        if case let .service(name, _, _, _) = self { return name }
        let desc = debugDescription
        guard let dot = desc.firstIndex(of: ".") else { return nil }
        return String(desc[..<dot])
    }
}
