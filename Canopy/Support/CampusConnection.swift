import Foundation
import Combine

/// Which website and campus this Mac is connected to (the address and campus key set in Settings → Transcription → Website),
/// and a way for the rest of the app to call the website's Mac-app endpoints with that key. The key is the only credential the
/// app has: it belongs to a campus, not a person, so it keeps working on a Mac with nobody logged in.
@MainActor
final class CampusConnection: ObservableObject {
    static let shared = CampusConnection()

    @Published private(set) var site: URL?
    @Published private(set) var key = ""
    @Published private(set) var campusName = ""

    var isConnected: Bool { site != nil && !key.isEmpty }

    /// The website's own pages, for links (nil until connected).
    var origin: URL? { isConnected ? site : nil }

    /// Called by the transcriber whenever its website address, campus key or campus name changes.
    func update(siteBase: String, key: String, campusName: String) {
        let url = URL(string: siteBase.trimmingCharacters(in: .whitespacesAndNewlines))
        let valid = url.flatMap { Self.mayCarryKey($0) ? $0 : nil }
        if site != valid { site = valid }
        if self.key != key { self.key = key }
        if self.campusName != campusName { self.campusName = campusName }
    }

    /// The key is only ever sent over https, or to this Mac itself (for testing).
    nonisolated static func mayCarryKey(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if url.scheme == "https" { return true }
        return url.scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    struct APIError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
    }

    /// Calls one of the website's endpoints with the campus key. A reply that isn't a success throws an `APIError` carrying
    /// the site's own explanation (it sends `{ "error": "…" }`).
    func call(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval = 15) async throws -> Data {
        guard isConnected, let site else { throw APIError(status: 0, message: "Not connected to a campus. Connect in Settings → Transcription → Website.") }
        var components = URLComponents(url: site.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError(status: 0, message: "The website address isn't valid.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(status: status, message: status == 401
                ? "The website doesn't accept this campus key. Connect again in Settings → Transcription → Website."
                : message ?? "The website answered \(status).")
        }
        return data
    }

    /// `call` with a JSON body built from `object`.
    func post(_ path: String, _ object: Any, timeout: TimeInterval = 15) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await call(path, method: "POST", body: body, timeout: timeout)
    }
}
