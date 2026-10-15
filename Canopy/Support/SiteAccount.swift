import Foundation
import AppKit
import Network
import Combine

// MARK: - Church site account
// Connects Canopy to the church's Supabase project, signed in as the person at
// the keyboard. Sign-in happens in the browser: Canopy listens on this Mac's
// loopback address, opens the church site's /auth/canopy page, and once they've
// signed in and confirmed, the site redirects back with a one-time sign-in
// token. Canopy trades it with Supabase for a session of its own (kept in the
// Keychain and refreshed as it runs). From then on Canopy reads and writes the
// inventory directly, and Row Level Security applies their inventory level.

@MainActor
final class SiteAccount: ObservableObject {
    static let shared = SiteAccount()

    static let defaultBaseURL = "https://churchlandingpage.rosesashumans.com"

    @Published private(set) var email: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: String?
    @Published private(set) var client: SupabaseClient?
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.baseURLKey) }
    }

    private static let baseURLKey = "siteAccount.baseURL"
    private static let projectKey = "siteAccount.supabaseURL"
    private static let apiKeyKey  = "siteAccount.supabaseKey"
    private static let sessionKey = "siteAccount.supabaseSession"
    // From before Canopy signed in as a person: a per-campus key that only reached the site's API.
    private static let legacyKeys = ["siteAccount.canopyKey"]
    private static let legacyDefaults = ["siteAccount.campusName"]

    private var listener: NWListener?
    private var pendingState: String?
    private var timeout: Task<Void, Never>?

    private init() {
        baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        for k in Self.legacyKeys { KeychainStore.delete(key: k) }
        for k in Self.legacyDefaults { UserDefaults.standard.removeObject(forKey: k) }
        restore()
    }

    var isConnected: Bool { client != nil }

    /// The site's origin, only if it's https (or this Mac, for local development).
    var origin: URL? {
        guard var c = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces)),
              c.scheme == "https" || c.host == "localhost" || c.host == "127.0.0.1" else { return nil }
        c.path = ""; c.query = nil; c.fragment = nil
        return c.url
    }

    private func restore() {
        guard let raw = KeychainStore.get(key: Self.sessionKey),
              let session = try? JSONDecoder().decode(SupabaseSession.self, from: Data(raw.utf8)),
              let project = UserDefaults.standard.string(forKey: Self.projectKey).flatMap(URL.init(string:)),
              let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyKey) else { return }
        connect(project: project, apiKey: apiKey, session: session)
    }

    private func connect(project: URL, apiKey: String, session: SupabaseSession) {
        let client = SupabaseClient(baseURL: project, apiKey: apiKey, session: session)
        client.onSessionChange = { Self.save($0) }
        self.client = client
        email = session.email
    }

    private static func save(_ session: SupabaseSession) {
        if let data = try? JSONEncoder().encode(session) {
            KeychainStore.set(String(decoding: data, as: UTF8.self), key: sessionKey)
        }
    }

    /// Called when the database says the session is no longer good.
    func sessionExpired() {
        signOut()
        lastError = "Your sign-in has expired. Sign in again."
    }

    // MARK: Sign in

    func signIn() {
        guard !isConnecting else { return }
        guard let origin else {
            lastError = "The site address must start with https://."
            return
        }
        lastError = nil
        isConnecting = true

        let state = Self.randomState()
        pendingState = state

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: .any)
        } catch {
            fail("Couldn't start the sign-in listener: \(error.localizedDescription)")
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    self.openBrowser(origin: origin, port: port)
                case .failed(let error):
                    self.fail("Sign-in listener failed: \(error.localizedDescription)")
                default: break
                }
            }
        }
        listener.start(queue: .main)

        // Don't leave a listener open forever if the browser step is abandoned.
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.fail("Sign-in timed out. Try again.")
        }
    }

    func signOut() {
        KeychainStore.delete(key: Self.sessionKey)
        client = nil
        email = nil
        lastError = nil
    }

    func cancelSignIn() { finishListening() }

    // MARK: Internals

    private func openBrowser(origin: URL, port: UInt16) {
        guard let state = pendingState,
              var c = URLComponents(url: origin.appendingPathComponent("auth/canopy"), resolvingAgainstBaseURL: false) else { return }
        c.queryItems = [URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "state", value: state)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let ok = self.accept(request: request)
                let body = ok
                    ? "<h2>Canopy is connected.</h2><p>You can close this tab and return to Canopy.</p>"
                    : "<h2>That didn&rsquo;t work.</h2><p>Go back to Canopy and try signing in again.</p>"
                let html = "<!doctype html><meta charset=utf-8><title>Canopy</title><body style=\"font-family:-apple-system,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem\">\(body)"
                let response = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Reads `GET /callback?state=…&token=…&supabase=…&apikey=…` and keeps the token only if the state matches ours.
    private func accept(request: String) -> Bool {
        guard let line = request.components(separatedBy: "\r\n").first,
              line.hasPrefix("GET /callback?"),
              let target = line.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(target)") else { return false }
        func value(_ name: String) -> String? { comps.queryItems?.first { $0.name == name }?.value }
        guard let state = value("state"), state == pendingState,
              let token = value("token"), token.range(of: #"^[0-9a-f]{20,128}$"#, options: .regularExpression) != nil,
              let project = value("supabase").flatMap(URL.init(string:)), project.scheme == "https", project.host?.hasSuffix(".supabase.co") == true,
              let apiKey = value("apikey"), !apiKey.isEmpty else { return false }

        finishListening()
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                let session = try await SupabaseClient.verify(baseURL: project, apiKey: apiKey, tokenHash: token)
                UserDefaults.standard.set(project.absoluteString, forKey: Self.projectKey)
                UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey)
                Self.save(session)
                connect(project: project, apiKey: apiKey, session: session)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        return true
    }

    private func fail(_ message: String) {
        lastError = message
        finishListening()
    }

    private func finishListening() {
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        pendingState = nil
        isConnecting = false
    }

    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
