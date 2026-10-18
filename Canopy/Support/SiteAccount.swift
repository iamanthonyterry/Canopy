import ChurchKitAuth
import Foundation
import AppKit
import Combine

// MARK: - Church site account
// Connects Canopy to the church's Supabase project, signed in as the person at
// the keyboard. Sign-in happens in the browser (ChurchKitAuth's ConnectFlow):
// Canopy listens on this Mac's loopback address, opens the church site's
// connect page, and once they've signed in and confirmed, the site redirects
// back with a one-time sign-in token. Canopy trades it with Supabase for a
// session of its own (kept in the Keychain and refreshed as it runs). From then
// on Canopy reads and writes the inventory directly, and Row Level Security
// applies their inventory level.

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

    private var flow: ConnectFlow?

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
        let flow = ConnectFlow()
        self.flow = flow
        Task {
            defer { isConnecting = false; self.flow = nil }
            do {
                let result = try await flow.run(ConnectRequest(app: .canopy, want: .session, site: origin))
                guard let grant = result.grant else { throw SupabaseError(message: "The website didn't send a sign-in. Try again.") }
                let session = try await SupabaseClient.verify(baseURL: grant.project, apiKey: grant.apiKey, tokenHash: grant.token)
                UserDefaults.standard.set(grant.project.absoluteString, forKey: Self.projectKey)
                UserDefaults.standard.set(grant.apiKey, forKey: Self.apiKeyKey)
                Self.save(session)
                connect(project: grant.project, apiKey: grant.apiKey, session: session)
                lastError = nil
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func signOut() {
        KeychainStore.delete(key: Self.sessionKey)
        client = nil
        email = nil
        lastError = nil
    }

    func cancelSignIn() { flow?.cancel() }
}
