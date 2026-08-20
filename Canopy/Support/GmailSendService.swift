import Foundation

/// Sends email via the Gmail API using the signed-in user's access token.
enum GmailSendService {

    enum SendError: Error {
        case notConnected
        case requestFailed(String)
    }

    static func send(to recipients: [String], subject: String, body: String, isHTML: Bool = false) async throws {
        guard let accessToken = await GmailAuthService.shared.validAccessToken() else {
            throw SendError.notConnected
        }

        let raw = buildRawMessage(to: recipients, subject: subject, body: body, isHTML: isHTML)
        let base64URL = raw
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["raw": base64URL])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode

        guard let status, (200...299).contains(status) else {
            throw SendError.requestFailed(Self.errorMessage(from: data, status: status))
        }
    }

    /// Pulls the human-readable message out of Gmail's `{"error": {"message": ...}}`
    /// body, falling back to the raw body (or status code) if it isn't shaped that way.
    private static func errorMessage(from data: Data, status: Int?) -> String {
        struct APIError: Decodable { struct Body: Decodable { let message: String }; let error: Body }
        if let decoded = try? JSONDecoder().decode(APIError.self, from: data) {
            return decoded.error.message
        }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            return raw
        }
        return "HTTP \(status.map(String.init) ?? "error")"
    }

    /// Sends one email per recipient, returning the recipient/reason pairs that failed.
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

    private static func describe(_ error: Error) -> String {
        switch error {
        case SendError.notConnected:
            return "Gmail account not connected"
        case SendError.requestFailed(let message):
            return message
        default:
            return error.localizedDescription
        }
    }

    private static func buildRawMessage(to recipients: [String], subject: String, body: String, isHTML: Bool) -> Data {
        guard isHTML else {
            let message = """
            To: \(recipients.joined(separator: ", "))
            Subject: \(subject)
            Content-Type: text/plain; charset="UTF-8"

            \(body)
            """
            return Data(message.utf8)
        }

        // multipart/alternative so clients that can't render HTML still show
        // something readable, rather than raw markup.
        let boundary = "np_boundary_\(UUID().uuidString)"
        let message = """
        To: \(recipients.joined(separator: ", "))
        Subject: \(subject)
        Content-Type: multipart/alternative; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/plain; charset="UTF-8"

        \(plainTextFallback(from: body))

        --\(boundary)
        Content-Type: text/html; charset="UTF-8"

        \(body)

        --\(boundary)--
        """
        return Data(message.utf8)
    }

    /// Strips tags/entities for the plain-text alternative part of an HTML
    /// email — the HTML part is what recipients actually see.
    private static func plainTextFallback(from html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
