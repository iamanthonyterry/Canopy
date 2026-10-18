import Testing
import Foundation
@testable import Canopy

struct WirelessProbeTests {
    @Test func sennheiserProductName() {
        let reply = Data(#"{"device":{"identity":{"product":"EW-DX EM 2 "}}}"#.utf8)
        #expect(WirelessProbe.product(in: reply) == "EW-DX EM 2")
        #expect(WirelessProbe.product(in: Data("nope".utf8)) == "")
    }

    @Test func titlesAndInventoryModel() {
        let rx = DiscoveredWireless(ip: "10.0.0.5", brand: .shure, model: "ULXD4D", iem: false)
        #expect(rx.title == "Shure ULXD4D")
        #expect(rx.makeModel == "Shure ULXD4D")
        let iem = DiscoveredWireless(ip: "10.0.0.6", brand: .shure, model: "", iem: true)
        #expect(iem.title == "Shure IEM transmitter")
        #expect(iem.makeModel == "Shure")
    }

    @Test func candidatesStayOnPrivateSubnets() {
        for host in WirelessProbe.candidateHosts() { #expect(isLocalAddress(host)) }
    }
}
