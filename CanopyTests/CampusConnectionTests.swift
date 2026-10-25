import Foundation
import Testing
@testable import Canopy

@MainActor
struct CampusConnectionTests {
    @Test func theKeyOnlyTravelsOverHttpsOrToThisMac() {
        #expect(CampusConnection.mayCarryKey(URL(string: "https://churchlandingpage.rosesashumans.com")!))
        #expect(CampusConnection.mayCarryKey(URL(string: "http://127.0.0.1:3000")!))
        #expect(CampusConnection.mayCarryKey(URL(string: "http://localhost:3000")!))
        #expect(!CampusConnection.mayCarryKey(URL(string: "http://churchlandingpage.rosesashumans.com")!), "plain http to a real site would expose the key")
        #expect(!CampusConnection.mayCarryKey(URL(string: "http://192.168.1.20")!))
        #expect(!CampusConnection.mayCarryKey(URL(string: "ftp://example.com")!))
    }

    @Test func connectedMeansAnAddressItMayUseAndAKey() {
        let connection = CampusConnection.shared
        defer { connection.update(siteBase: "", key: "", campusName: "") }
        connection.update(siteBase: "https://example.com", key: "", campusName: "")
        #expect(!connection.isConnected, "an address with no key")
        connection.update(siteBase: "https://example.com", key: String(repeating: "a", count: 48), campusName: "Lewis Center")
        #expect(connection.isConnected && connection.campusName == "Lewis Center" && connection.origin?.host == "example.com")
        connection.update(siteBase: "http://example.com", key: String(repeating: "a", count: 48), campusName: "Lewis Center")
        #expect(!connection.isConnected && connection.origin == nil, "an unsafe address disconnects rather than sending the key")
        connection.update(siteBase: "not a url", key: String(repeating: "a", count: 48), campusName: "")
        #expect(!connection.isConnected)
    }

    @Test func callingWhileNotConnectedSaysHowToConnect() async {
        let connection = CampusConnection.shared
        connection.update(siteBase: "", key: "", campusName: "")
        await #expect(throws: CampusConnection.APIError.self) { _ = try await connection.call("api/workflow-sync") }
        do { _ = try await connection.call("api/workflow-sync") } catch { #expect(error.localizedDescription.contains("Connect in Settings")) }
    }
}
