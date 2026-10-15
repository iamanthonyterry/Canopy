import Foundation
import Testing
@testable import Canopy

struct BatchDeviceAddTests {
    @Test func singleDeviceKeepsItsNameAndAddress() {
        #expect(BatchDeviceAdd.names(base: "ISO 1", count: 1) == ["ISO 1"])
        #expect(BatchDeviceAdd.addresses(base: "10.0.0.5", count: 1) == ["10.0.0.5"])
    }

    @Test func namesCountUpFromATrailingNumber() {
        #expect(BatchDeviceAdd.names(base: "Wedge 3", count: 3) == ["Wedge 3", "Wedge 4", "Wedge 5"])
        #expect(BatchDeviceAdd.names(base: "Wedge 08", count: 3) == ["Wedge 08", "Wedge 09", "Wedge 10"])
        #expect(BatchDeviceAdd.names(base: "Wedge 9", count: 2) == ["Wedge 9", "Wedge 10"])
    }

    @Test func modelNumbersAreNotBumped() {
        #expect(BatchDeviceAdd.names(base: "SQ-5", count: 2) == ["SQ-5 1", "SQ-5 2"])
        #expect(BatchDeviceAdd.names(base: "Behringer X32", count: 2) == ["Behringer X32 1", "Behringer X32 2"])
        #expect(BatchDeviceAdd.names(base: "Shure SM58", count: 3) == ["Shure SM58 1", "Shure SM58 2", "Shure SM58 3"])
    }

    @Test func ipv4LastOctetCountsUp() {
        #expect(BatchDeviceAdd.addresses(base: "192.168.1.21", count: 3)
                == ["192.168.1.21", "192.168.1.22", "192.168.1.23"])
    }

    @Test func otherAddressesStayOnTheFirstOnly() {
        #expect(BatchDeviceAdd.addresses(base: "deck.local", count: 3) == ["deck.local", "", ""])
        #expect(BatchDeviceAdd.addresses(base: "", count: 2) == ["", ""])
    }

    @Test func quantityIsCappedByTheLastOctet() {
        #expect(BatchDeviceAdd.maxQuantity(forAddress: "192.168.1.10") == BatchDeviceAdd.hardLimit)
        #expect(BatchDeviceAdd.maxQuantity(forAddress: "192.168.1.250") == 5)
        #expect(BatchDeviceAdd.maxQuantity(forAddress: "192.168.1.255") == 1)
        #expect(BatchDeviceAdd.maxQuantity(forAddress: "deck.local") == BatchDeviceAdd.hardLimit)
    }
}
