import Foundation
import Testing
@testable import Canopy

@MainActor
struct AutoLinkTests {
    private func record(_ id: String, _ name: String, ip: String) -> Equipment {
        var e = Equipment(id: id, name: name)
        e.ipAddress = ip
        return e
    }
    private func deck(_ name: String, ip: String, linkedTo id: String? = nil) -> LocalDevice {
        var d = HyperDeck(name: name, ipAddress: ip, remotePath: "")
        d.inventoryID = id
        return .deck(d)
    }

    @Test func sameAddressLinks() {
        let pairs = LocalDevice.addressMatches(
            devices: [deck("ISO 1", ip: "192.168.1.21"), deck("ISO 2", ip: "192.168.1.22")],
            equipment: [record("a", "HyperDeck 1", ip: "192.168.1.21"), record("b", "HyperDeck 2", ip: "http://192.168.1.22:80/")])
        #expect(pairs.map { $0.equipment.id } == ["a", "b"])
    }

    @Test func differentAddressDoesNotLink() {
        let pairs = LocalDevice.addressMatches(devices: [deck("ISO 1", ip: "192.168.1.21")],
                                               equipment: [record("a", "Deck", ip: "192.168.1.99")])
        #expect(pairs.isEmpty)
    }

    @Test func twoRecordsAtOneAddressIsNotGuessed() {
        let pairs = LocalDevice.addressMatches(devices: [deck("ISO 1", ip: "10.0.0.5")],
                                               equipment: [record("a", "One", ip: "10.0.0.5"), record("b", "Two", ip: "10.0.0.5")])
        #expect(pairs.isEmpty)
    }

    @Test func twoDevicesAtOneAddressIsNotGuessed() {
        let pairs = LocalDevice.addressMatches(devices: [deck("A", ip: "10.0.0.5"), deck("B", ip: "10.0.0.5")],
                                               equipment: [record("a", "One", ip: "10.0.0.5")])
        #expect(pairs.isEmpty)
    }

    @Test func alreadyLinkedDevicesAndRecordsAreLeftAlone() {
        let linked = LocalDevice.addressMatches(devices: [deck("ISO 1", ip: "10.0.0.5", linkedTo: "z")],
                                                equipment: [record("a", "Deck", ip: "10.0.0.5"), record("z", "Other", ip: "10.0.0.9")])
        #expect(linked.isEmpty)

        // A record another device already claims isn't handed out again.
        let taken = LocalDevice.addressMatches(devices: [deck("ISO 1", ip: "10.0.0.5", linkedTo: "a"), deck("ISO 2", ip: "10.0.0.5")],
                                               equipment: [record("a", "Deck", ip: "10.0.0.5")])
        #expect(taken.isEmpty)
    }

    @Test func aLinkToADeletedRecordIsReplaced() {
        let pairs = LocalDevice.addressMatches(devices: [deck("ISO 1", ip: "10.0.0.5", linkedTo: "gone")],
                                               equipment: [record("a", "Deck", ip: "10.0.0.5")])
        #expect(pairs.map { $0.equipment.id } == ["a"])
    }

    @Test func blankAddressesNeverMatch() {
        let pairs = LocalDevice.addressMatches(devices: [deck("ISO 1", ip: "")], equipment: [record("a", "Deck", ip: "")])
        #expect(pairs.isEmpty)
    }
}
