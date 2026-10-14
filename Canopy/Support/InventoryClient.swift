import Foundation
import Combine

// MARK: - Inventory (church site)
// The campus's equipment as the church website keeps it. Canopy lists it,
// links it to local devices, adds new devices, and applies config files.

struct InventoryItem: Codable, Identifiable, Hashable {
    struct Driver: Codable, Hashable {
        var id: String          // "videohub" | "ah-scene"
        var label: String
        var needs: String       // "file" | "scene"
        var port: Int
    }
    struct File: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var size: Int
    }
    var id: String
    var name: String
    var category: String
    var makeModel: String
    var serial: String
    var location: String
    var status: String
    var host: String            // bare IP/host, "" when none is saved
    var driver: Driver?
    var files: [File]
}

struct InventoryFilePayload: Decodable {
    var name: String
    var driver: String
    var host: String
    var port: Int
    var body: String
}

struct InventoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum InventoryClient {
    private static func request(_ path: String, method: String = "GET", body: [String: String]? = nil) throws -> URLRequest {
        let account = SiteAccount.shared
        guard let origin = account.origin, let key = account.key else {
            throw InventoryError(message: "Sign in to the church site first.")
        }
        var req = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private static func send(_ req: URLRequest) async throws -> Data {
        let data: Data, res: URLResponse
        do { (data, res) = try await URLSession.shared.data(for: req) }
        catch { throw InventoryError(message: "Couldn't reach the church site. \(error.localizedDescription)") }
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 {
                throw InventoryError(message: "The church site doesn't recognize this sign-in any more. Sign in again.")
            }
            struct Reply: Decodable { var error: String? }
            let message = (try? JSONDecoder().decode(Reply.self, from: data))?.error
            throw InventoryError(message: message ?? "The church site returned an error (\(status)).")
        }
        return data
    }

    static func list() async throws -> [InventoryItem] {
        struct Reply: Decodable { var equipment: [InventoryItem] }
        let data = try await send(try request("api/canopy/equipment"))
        return try JSONDecoder().decode(Reply.self, from: data).equipment
    }

    /// Adds a device and returns its new id.
    static func create(name: String, makeModel: String, category: String, address: String) async throws -> String {
        struct Reply: Decodable { var id: String }
        let body = ["name": name, "makeModel": makeModel, "category": category, "address": address]
        let data = try await send(try request("api/canopy/equipment", method: "POST", body: body))
        return try JSONDecoder().decode(Reply.self, from: data).id
    }

    static func setAddress(id: String, address: String) async throws {
        _ = try await send(try request("api/canopy/equipment/\(id)", method: "PATCH", body: ["address": address]))
    }

    static func file(equipmentID: String, fileID: String) async throws -> InventoryFilePayload {
        let data = try await send(try request("api/canopy/equipment/\(equipmentID)/files/\(fileID)"))
        return try JSONDecoder().decode(InventoryFilePayload.self, from: data)
    }
}

// MARK: - Store

@MainActor
final class InventoryStore: ObservableObject {
    static let shared = InventoryStore()

    @Published private(set) var items: [InventoryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedOnce = false

    func refresh() async {
        guard SiteAccount.shared.isConnected else { items = []; loadedOnce = false; return }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await InventoryClient.list()
            error = nil
            loadedOnce = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clear() { items = []; error = nil; loadedOnce = false }
}
