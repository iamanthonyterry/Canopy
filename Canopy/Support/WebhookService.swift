import Foundation

/// Details of a workflow run that a webhook reports.
nonisolated struct WebhookReport {
    struct File {
        var name: String
        var sizeBytes: Int64
        var clips: [Clip]
    }
    struct Clip {
        var title: String
        var start: TimeInterval
        var end: TimeInterval
        var score: Int
        var caption: String?
        var hashtags: [String]
    }

    var workflow: String
    var device: String
    var errors: Int
    var files: [File]
    var sentAt: Date = Date()
}

nonisolated enum WebhookError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:        return "The webhook URL isn't a valid http or https address"
        case .badStatus(let c):  return "The server answered with status \(c)"
        case .network(let why):  return why
        }
    }
}

nonisolated enum WebhookService {
    // MARK: Payloads

    static func summary(for report: WebhookReport) -> String {
        let clipCount = report.files.reduce(0) { $0 + $1.clips.count }
        var parts = ["\(report.files.count) file\(report.files.count == 1 ? "" : "s")"]
        if clipCount > 0 { parts.append("\(clipCount) clip suggestion\(clipCount == 1 ? "" : "s")") }
        let status = report.errors == 0 ? "finished" : "finished with \(report.errors) error\(report.errors == 1 ? "" : "s")"
        return "Canopy · \(report.workflow) \(status) on \(report.device): " + parts.joined(separator: ", ")
    }

    static func body(for report: WebhookReport, format: WebhookFormat) throws -> Data {
        switch format {
        case .slack:
            return try JSONSerialization.data(withJSONObject: ["text": summary(for: report)])
        case .discord:
            return try JSONSerialization.data(withJSONObject: ["content": summary(for: report)])
        case .json:
            let formatter = ISO8601DateFormatter()
            let object: [String: Any] = [
                "event": "workflow.step",
                "workflow": report.workflow,
                "device": report.device,
                "errors": report.errors,
                "sentAt": formatter.string(from: report.sentAt),
                "summary": summary(for: report),
                "files": report.files.map { file -> [String: Any] in
                    [
                        "name": file.name,
                        "sizeBytes": file.sizeBytes,
                        "clips": file.clips.map { clip -> [String: Any] in
                            var c: [String: Any] = [
                                "title": clip.title, "start": clip.start, "end": clip.end, "score": clip.score,
                                "hashtags": clip.hashtags,
                            ]
                            if let caption = clip.caption { c["caption"] = caption }
                            return c
                        },
                    ]
                },
            ]
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    // MARK: Sending

    static func validate(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { throw WebhookError.invalidURL }
        return url
    }

    /// POSTs the report. Retries once on a network error or a 5xx answer.
    static func send(
        _ report: WebhookReport, to urlString: String, format: WebhookFormat,
        session: URLSession = .shared
    ) async throws {
        let url = try validate(urlString)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Canopy", forHTTPHeaderField: "User-Agent")
        request.httpBody = try body(for: report, format: format)

        var lastError: WebhookError = .network("The request didn't complete")
        for attempt in 0..<2 {
            do {
                let (_, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return }
                lastError = .badStatus(code)
                if code < 500 { throw lastError }          // a 4xx won't improve on retry
            } catch let error as WebhookError {
                throw error
            } catch {
                lastError = .network(error.localizedDescription)
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
        }
        throw lastError
    }
}
