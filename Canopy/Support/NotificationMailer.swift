import Foundation

/// Sends notification email as canopy@send.rosesashumans.com through the church
/// site (POST /api/notify), with the campus key this Mac is connected with. The
/// site limits how much one campus can send. No mail credentials are stored on this Mac.
enum NotificationMailer {

    enum SendError: Error {
        case notConnected
        case requestFailed(String)
    }

    static let fromAddress = "canopy@send.rosesashumans.com"

    @MainActor static var isAvailable: Bool { CampusConnection.shared.isConnected }

    @MainActor
    static func send(to recipients: [String], subject: String, body: String, isHTML: Bool = false) async throws {
        guard CampusConnection.shared.isConnected else { throw SendError.notConnected }
        let payload: [String: Any] = ["to": recipients, "subject": subject, "body": body, "isHTML": isHTML]
        do {
            _ = try await CampusConnection.shared.post("api/notify", payload, timeout: 30)
        } catch let error as CampusConnection.APIError {
            throw SendError.requestFailed(error.message)
        }
    }

    /// Sends one email per recipient, returning the recipient/reason pairs that failed.
    @MainActor
    static func sendIndividually(to recipients: [String], subject: String, body: String, isHTML: Bool = false) async -> [(recipient: String, reason: String)] {
        var failed: [(recipient: String, reason: String)] = []
        for recipient in recipients {
            do {
                try await send(to: [recipient], subject: subject, body: body, isHTML: isHTML)
            } catch {
                failed.append((recipient, describe(error)))
            }
        }
        return failed
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SendError.notConnected: return "Not connected to a campus"
        case SendError.requestFailed(let message): return message
        default: return error.localizedDescription
        }
    }
}
