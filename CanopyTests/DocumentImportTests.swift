import Foundation
import Testing
@testable import Canopy

@MainActor
struct DocumentImportTests {
    private func device(_ name: String, model: String = "", room: String = "", ip: String = "", network: String = "", mac: String = "", role: String = "") -> RawAnswer.Device {
        RawAnswer.Device(name: name, model: model, role: role, room: room, ip: ip, network: network, mac: mac)
    }

    @Test func chunksSmallAndRepeatTheHeadings() {
        let text = (1...25).map { "row \($0)" }.joined(separator: "\n")
        let (head, chunks) = DocumentImport.chunk("Title\n\n" + text, lines: 10, chars: 10_000)
        #expect(head.hasPrefix("Title\nrow 1"))
        #expect(chunks.count == 3)
        #expect(chunks[0].split(separator: "\n").count == 10)
    }

    @Test func oneSwitchListedPerVLANIsOneDeviceWithItsControlAddress() {
        let a = RawAnswer(devices: [
            device("Core Switch", model: "Netgear M4250", ip: "10.0.20.2", network: "Dante", mac: "00-0F-9B-04-00-2F"),
            device("Core Switch", model: "Netgear M4250", ip: "10.0.10.2", network: "Control", mac: "00:0f:9b:04:00:2f"),
        ])
        let r = DocumentImport.build([a])
        #expect(r.devices.count == 1)
        #expect(r.devices[0].ipAddress == "10.0.10.2")
        #expect(r.devices[0].notes.contains("MAC: 00:0F:9B:04:00:2F"))
        #expect(r.devices[0].notes.contains("Also at: 10.0.20.2 (Dante)"))
        #expect(r.devices[0].role == .networkSwitch)
    }

    @Test func controlAndDantePortsOfAReceiverAreOneDevice() {
        let a = RawAnswer(devices: [
            device("Receiver 2 - Control", model: "Shure ULXD4Q", room: "FOH"),
            device("Receiver 2 - Dante", model: "Shure ULXD4Q", room: "FOH"),
        ])
        let r = DocumentImport.build([a])
        #expect(r.devices.map(\.name) == ["Receiver 2"])
    }

    @Test func identicalRowsStayTwoUnitsAndGetToldApart() {
        let a = RawAnswer(devices: [device("Audio DSP", model: "Q-SYS Core 110f", room: "Chapel"), device("Audio DSP", model: "Q-SYS Core 110f", room: "Gym")])
        let r = DocumentImport.build([a])
        #expect(r.devices.map(\.name) == ["Audio DSP (Chapel)", "Audio DSP (Gym)"])
    }

    @Test func cablesNameDevicesAndAddBareOnesWhenNeeded() {
        let a = RawAnswer(devices: [device("Stage Box", model: "A&H DX168")],
                          cables: [RawAnswer.Cable(signal: "Kick In", from: "Stage Box", fromChannel: "Ch 1", to: "FOH Console", toChannel: "1"),
                                   RawAnswer.Cable(signal: "Kick In", from: "stage box", fromChannel: "1", to: "FOH Console", toChannel: "1")])
        let r = DocumentImport.build([a, nil])
        #expect(r.devices.map(\.name) == ["Stage Box", "FOH Console"])
        #expect(r.cables.count == 1)  // the repeat is dropped
        #expect(r.cables[0].fromDevice == "d1" && r.cables[0].toDevice == "d2" && r.cables[0].fromChannel == 1)
        #expect(r.warnings.first?.hasPrefix("1 of the document's 2 parts") == true)
    }

    @Test func matchesBySerialMacNameOrTheOnlyOneOfARole() {
        let known = [
            Equipment(id: "a", name: "FOH dLive", role: .console, makeModel: "Allen & Heath dLive S5000"),
            Equipment(id: "b", name: "DX168", role: .stageBox, serial: "SN-123"),
            Equipment(id: "c", name: "Switch", role: .networkSwitch, notes: "MAC: 00:0F:9B:04:00:2F"),
        ]
        let bySerial = FoundDevice(key: "1", name: "Stage rack box", serial: "sn123", rows: 1)
        let byMac = FoundDevice(key: "2", name: "Core", macs: ["000f9b04002f"], rows: 1)
        let byName = FoundDevice(key: "3", name: "dLive", rows: 1)
        let onlyConsole = FoundDevice(key: "4", name: "Mixer", role: .console, rows: 0)
        let none = FoundDevice(key: "5", name: "Coffee maker", rows: 1)
        let m = DocumentImport.matchAll([bySerial, byMac, byName, none], in: known)
        #expect(m["1"]?.id == "b" && m["1"]?.why.contains("serial") == true)
        #expect(m["2"]?.id == "c")
        #expect(m["3"]?.id == "a")
        #expect(m["5"] == nil)
        #expect(DocumentImport.match(onlyConsole, in: known)?.id == "a")
    }

    @Test func aDeviceIsNeverClaimedTwice() {
        let known = [Equipment(id: "a", name: "Stage Box")]
        let weak = FoundDevice(key: "1", name: "Stage Box Left", rows: 1)
        let strong = FoundDevice(key: "2", name: "Stage Box", rows: 1)
        let m = DocumentImport.matchAll([weak, strong], in: known)
        #expect(m["2"]?.id == "a")
        #expect(m["1"] == nil)
    }

    @Test func fieldsThatOnlyRepeatTheRowAreDropped() {
        var d = device("Videohub", model: "Blackmagic Smart Videohub 40x40", room: "Video Rack", ip: "10.10.1.50", network: "10.10.1.50", role: "video-encoder")
        d.hostname = "Videohub"
        d.notes = "Blackmagic Smart Videohub 40x40, Location: Video Rack, VLAN: Control"
        let r = DocumentImport.build([RawAnswer(devices: [d])])
        #expect(r.devices[0].role == .videoSwitcher)
        #expect(r.devices[0].hostname == "")
        #expect(r.devices[0].notes == "")
        var kept = device("Encoder", model: "Resi E1210")
        kept.notes = "Firmware 3.2"
        #expect(DocumentImport.build([RawAnswer(devices: [kept])]).devices[0].notes == "Firmware 3.2")
    }

    @Test func aMacCopiedOntoTheNextRowIsDroppedAndNeverMerges() {
        let chunk = "Core Switch,Netgear M4250,10.10.1.2,00:0F:9B:04:00:2F\nWireless Receiver 1,Shure ULXD4Q,10.10.1.31,"
        let copied = DocumentImport.ground(device("Wireless Receiver 1", model: "Shure ULXD4Q", ip: "10.10.1.31", mac: "00:0F:9B:04:00:2F"), in: chunk)
        #expect(copied.mac == "" && copied.ip == "10.10.1.31")
        let real = DocumentImport.ground(device("Core Switch", model: "Netgear M4250", ip: "10.10.1.2", mac: "00-0f-9b-04-00-2f"), in: chunk)
        #expect(real.mac == "00-0f-9b-04-00-2f")
        // Even if a copied MAC got through, different models never merge.
        let r = DocumentImport.build([RawAnswer(devices: [device("Core Switch", model: "Netgear M4250", mac: "00:0F:9B:04:00:2F"),
                                                          device("Receiver", model: "Shure ULXD4Q", mac: "00:0F:9B:04:00:2F")])])
        #expect(r.devices.count == 2)
    }

    @Test func readsAnInputListExactly() {
        let text = "Sunday Input List\nSignal,Stage Box (DX168),FOH (dLive),Recording,Notes\nKick In,1,1,1,\nSnare Top,2,2,2,\nPastor Headset,,9,9,wireless\nAcoustic DI,5,5,,\nWalk-in music,,,,\n"
        let r = DocumentImport.inputList(text)!
        #expect(r.devices.map(\.name) == ["Stage Box", "FOH", "Recording"])
        #expect(r.devices[0].makeModel == "DX168" && r.devices[0].role == .stageBox && r.devices[1].role == .console)
        let lines = r.cables.map { "\($0.fromDevice):\($0.fromChannel!)>\($0.toDevice):\($0.toChannel!) \($0.fromName)" }
        #expect(lines == ["d1:1>d2:1 Kick In", "d1:1>d3:1 Kick In", "d1:2>d2:2 Snare Top", "d1:2>d3:2 Snare Top", "d2:9>d3:9 Pastor Headset", "d1:5>d2:5 Acoustic DI"])
        #expect(r.cables[4].note == "wireless")
    }

    @Test func readsATabbedTableUnderATitle() {
        let text = "Input List\nSignal\tStage Box\tFOH\nKick In\t1\t1\nSnare\t2\t2\n\nThanks"
        #expect(DocumentImport.inputList(text)?.cables.count == 2)
    }

    @Test func aDeviceListIsNotAnInputList() {
        let text = "Device,Make/Model,Location,IP Address\nCore Switch,Netgear M4250,Rack,10.10.1.2\nFOH Console,dLive S5000,FOH,10.10.1.10\nStage Box,DX168,Stage,10.10.1.21\n"
        #expect(DocumentImport.inputList(text) == nil)
    }

    @Test func macsAndPortlessNames() {
        #expect(DocumentImport.normalMac("7c:2e:d:a5:be:d4") == "7c2e0da5bed4")
        #expect(DocumentImport.normalMac("not a mac") == "")
        #expect(DocumentImport.portless("Receiver 2 - Control") == "Receiver 2")
        #expect(DocumentImport.portless("Encoder Dante Interface") == "Encoder")
    }
}
