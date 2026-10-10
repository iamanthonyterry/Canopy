import Foundation
import Testing
@testable import Canopy

/// Answers every request with a scripted status and records what it saw.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            Self.bodies.append(data)
        } else if let body = request.httpBody {
            Self.bodies.append(body)
        }
        let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct WebhookTests {
    private let report = WebhookReport(
        workflow: "Nightly", device: "Deck A", errors: 0,
        files: [WebhookReport.File(name: "A001.mov", sizeBytes: 1000, clips: [
            WebhookReport.Clip(title: "Big idea", start: 10, end: 40, score: 88, caption: "Cap", hashtags: ["x"])
        ])]
    )

    private func session() -> URLSession {
        StubURLProtocol.statuses = []; StubURLProtocol.requests = []; StubURLProtocol.bodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func jsonBodyCarriesRunDetails() throws {
        let body = try WebhookService.body(for: report, format: .json)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["workflow"] as? String == "Nightly")
        let files = try #require(object["files"] as? [[String: Any]])
        let clips = try #require(files[0]["clips"] as? [[String: Any]])
        #expect(clips[0]["title"] as? String == "Big idea")
        #expect(clips[0]["caption"] as? String == "Cap")
    }

    @Test func slackAndDiscordGetTheirOwnShape() throws {
        let slack = try #require(JSONSerialization.jsonObject(with: WebhookService.body(for: report, format: .slack)) as? [String: String])
        let discord = try #require(JSONSerialization.jsonObject(with: WebhookService.body(for: report, format: .discord)) as? [String: String])
        #expect(slack["text"]?.contains("Nightly") == true)
        #expect(discord["content"]?.contains("1 clip suggestion") == true)
    }

    @Test func onlyHttpAddressesAreAccepted() {
        #expect((try? WebhookService.validate("https://hooks.example.com/abc")) != nil)
        #expect((try? WebhookService.validate("  http://10.0.0.5:8080/x ")) != nil)
        #expect((try? WebhookService.validate("file:///etc/passwd")) == nil)
        #expect((try? WebhookService.validate("not a url")) == nil)
        #expect((try? WebhookService.validate("")) == nil)
    }

    @Test func successfulPostSendsOnceWithJSONContentType() async throws {
        let s = session()
        try await WebhookService.send(report, to: "https://example.com/hook", format: .json, session: s)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(StubURLProtocol.requests[0].httpMethod == "POST")
        #expect(StubURLProtocol.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func clientErrorsAreNotRetried() async {
        let s = session()
        StubURLProtocol.statuses = [404]
        await #expect(throws: WebhookError.self) {
            try await WebhookService.send(report, to: "https://example.com/hook", format: .json, session: s)
        }
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test func serverErrorsAreRetriedOnce() async throws {
        let s = session()
        StubURLProtocol.statuses = [503, 200]
        try await WebhookService.send(report, to: "https://example.com/hook", format: .json, session: s)
        #expect(StubURLProtocol.requests.count == 2)
    }

    @Test func webhookStepRoundTrips() throws {
        let action = StepAction.webhook(url: "https://example.com/h", format: .slack)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
    }
}
