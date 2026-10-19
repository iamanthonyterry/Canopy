import ChurchKitAuth
import Foundation

// MARK: - Supabase
// A small client for the church's Supabase project: PostgREST for the tables,
// Storage for config files, and Auth for keeping the session fresh. Requests
// carry the signed-in person's access token, so Row Level Security in the
// database decides what they can read and change, exactly as it did on the
// website. The project URL and publishable key are public by design.

nonisolated struct SupabaseError: LocalizedError, Sendable {
    var message: String
    var code: String = ""
    var status: Int = 0
    var errorDescription: String? { message }
    var isUnique: Bool { code == "23505" }
    var isForeignKey: Bool { code == "23503" }
}

/// One PostgREST filter or modifier, as a query item: `.eq("id", x)` is `id=eq.x`.
nonisolated struct Filter: Sendable {
    let name: String
    let value: String
    static func eq(_ c: String, _ v: String) -> Filter { .init(name: c, value: "eq.\(v)") }
    static func neq(_ c: String, _ v: String) -> Filter { .init(name: c, value: "neq.\(v)") }
    static func gt(_ c: String, _ v: Int) -> Filter { .init(name: c, value: "gt.\(v)") }
    static func lt(_ c: String, _ v: String) -> Filter { .init(name: c, value: "lt.\(v)") }
    static func isNull(_ c: String) -> Filter { .init(name: c, value: "is.null") }
    static func notNull(_ c: String) -> Filter { .init(name: c, value: "not.is.null") }
    static func `in`(_ c: String, _ v: [String]) -> Filter { .init(name: c, value: "in.(\(v.joined(separator: ",")))") }
    static func notIn(_ c: String, _ v: [String]) -> Filter { .init(name: c, value: "not.in.(\(v.joined(separator: ",")))") }
    static func order(_ v: String) -> Filter { .init(name: "order", value: v) }
}

@MainActor
final class SupabaseClient {
    let baseURL: URL
    let apiKey: String
    private(set) var session: SupabaseSession
    /// Called whenever the session is refreshed, so it can be saved.
    var onSessionChange: ((SupabaseSession) -> Void)?
    private var refreshing: Task<Void, Error>?

    init(baseURL: URL, apiKey: String, session: SupabaseSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: Auth

    /// Trades a one-time sign-in token (from the church site's connect page) for a session of Canopy's own.
    static func verify(baseURL: URL, apiKey: String, tokenHash: String) async throws -> SupabaseSession {
        do { return try await SupabaseAuth.verify(project: baseURL, apiKey: apiKey, tokenHash: tokenHash) }
        catch let e as AuthError { throw SupabaseError(message: e.message, status: e.status) }
    }

    private func refreshIfNeeded() async throws {
        guard session.expiresAt.timeIntervalSinceNow < 60 else { return }
        if let refreshing { return try await refreshing.value }
        let task = Task { @MainActor in
            defer { self.refreshing = nil }
            do { session = try await SupabaseAuth.refresh(project: baseURL, apiKey: apiKey, session: session) }
            catch let e as AuthError { throw SupabaseError(message: e.message, status: e.status) }
            onSessionChange?(session)
        }
        refreshing = task
        try await task.value
    }

    // MARK: Requests

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      contentType: String = "application/json", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try await refreshIfNeeded()
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        // PostgREST reads "+" in a query as a space, so encode it.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: c.url!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data, res: URLResponse
        do { (data, res) = try await URLSession.shared.data(for: req) }
        catch { throw SupabaseError(message: "Couldn't reach your church's database. \(error.localizedDescription)") }
        let http = res as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            nonisolated struct Reply: Decodable { var message: String?; var code: String?; var error: String? }
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
            if http.statusCode == 401 {
                throw SupabaseError(message: "Your sign-in has expired. Sign in again.", code: reply?.code ?? "", status: 401)
            }
            throw SupabaseError(message: reply?.message ?? reply?.error ?? "The database returned an error (\(http.statusCode)).",
                                code: reply?.code ?? "", status: http.statusCode)
        }
        return (data, http)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()

    private func items(_ select: String, _ filters: [Filter]) -> [URLQueryItem] {
        [URLQueryItem(name: "select", value: select)] + filters.map { URLQueryItem(name: $0.name, value: $0.value) }
    }

    /// Every matching row, a page at a time (Supabase returns at most 1,000 per request).
    func select<T: Decodable>(_ table: String, _ select: String = "*", _ filters: [Filter] = [], as: T.Type = T.self) async throws -> [T] {
        let page = 1000
        var all: [T] = []
        var from = 0
        while true {
            let (data, _) = try await send("GET", "rest/v1/\(table)", query: items(select, filters),
                                           headers: ["Range-Unit": "items", "Range": "\(from)-\(from + page - 1)"])
            let rows = try Self.decoder.decode([T].self, from: data)
            all += rows
            if rows.count < page { return all }
            from += page
        }
    }

    func insert(_ table: String, _ rows: [[String: Any?]], returning select: String? = nil) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: rows.map(Self.clean))
        var headers = ["Prefer": select == nil ? "return=minimal" : "return=representation"]
        if rows.count > 1 { headers["Prefer"]! += ",missing=default" }
        let query = select.map { [URLQueryItem(name: "select", value: $0)] } ?? []
        return try await send("POST", "rest/v1/\(table)", query: query, body: body, headers: headers).0
    }

    /// Inserts rows and returns the ids the database gave them, in order.
    func insertIDs(_ table: String, _ rows: [[String: Any?]]) async throws -> [String] {
        guard !rows.isEmpty else { return [] }
        nonisolated struct Row: Decodable { var id: String }
        let data = try await insert(table, rows, returning: "id")
        let ids = try Self.decoder.decode([Row].self, from: data).map(\.id)
        guard ids.count == rows.count else { throw SupabaseError(message: "Couldn't save all of those.") }
        return ids
    }

    func upsert(_ table: String, _ row: [String: Any?], onConflict: String, returning select: String? = nil) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: [Self.clean(row)])
        let ret = select == nil ? "return=minimal" : "return=representation"
        var query = [URLQueryItem(name: "on_conflict", value: onConflict)]
        if let select { query.append(URLQueryItem(name: "select", value: select)) }
        return try await send("POST", "rest/v1/\(table)", query: query, body: body,
                              headers: ["Prefer": "resolution=merge-duplicates,\(ret)"]).0
    }

    func update(_ table: String, _ values: [String: Any?], _ filters: [Filter]) async throws {
        precondition(!filters.isEmpty, "an update needs a filter")
        let body = try JSONSerialization.data(withJSONObject: Self.clean(values))
        _ = try await send("PATCH", "rest/v1/\(table)", query: filters.map { URLQueryItem(name: $0.name, value: $0.value) },
                           body: body, headers: ["Prefer": "return=minimal"])
    }

    /// Updates matching rows and returns the ids of the ones that changed, so a caller racing others can tell if it won.
    func updateReturningIDs(_ table: String, _ values: [String: Any?], _ filters: [Filter]) async throws -> [String] {
        precondition(!filters.isEmpty, "an update needs a filter")
        let body = try JSONSerialization.data(withJSONObject: Self.clean(values))
        nonisolated struct Row: Decodable { var id: String }
        let query = filters.map { URLQueryItem(name: $0.name, value: $0.value) } + [URLQueryItem(name: "select", value: "id")]
        let data = try await send("PATCH", "rest/v1/\(table)", query: query, body: body, headers: ["Prefer": "return=representation"]).0
        return try Self.decoder.decode([Row].self, from: data).map(\.id)
    }

    func delete(_ table: String, _ filters: [Filter]) async throws {
        precondition(!filters.isEmpty, "a delete needs a filter")
        _ = try await send("DELETE", "rest/v1/\(table)", query: filters.map { URLQueryItem(name: $0.name, value: $0.value) },
                           headers: ["Prefer": "return=minimal"])
    }

    /// nil becomes JSON null.
    private static func clean(_ row: [String: Any?]) -> [String: Any] {
        row.mapValues { $0 ?? NSNull() }
    }

    // MARK: Functions

    /// Calls one of the project's edge functions with the signed-in person's session.
    func invoke(_ function: String, _ payload: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await send("POST", "functions/v1/\(function)", body: body).0
    }

    // MARK: Storage

    private func objectPath(_ bucket: String, _ path: String) -> String { "storage/v1/object/\(bucket)/\(path)" }

    func upload(bucket: String, path: String, data: Data, contentType: String) async throws {
        _ = try await send("POST", objectPath(bucket, path), body: data, contentType: contentType.isEmpty ? "application/octet-stream" : contentType,
                           headers: ["x-upsert": "false"])
    }

    func download(bucket: String, path: String) async throws -> Data {
        try await send("GET", "storage/v1/object/authenticated/\(bucket)/\(path)").0
    }

    func remove(bucket: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: ["prefixes": paths])
        _ = try await send("DELETE", "storage/v1/object/\(bucket)", body: body)
    }
}
