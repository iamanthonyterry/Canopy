import Foundation
import Testing
@testable import Canopy

struct WirelessTests {
    // MARK: Detection

    @Test func detectsBrandsFromModelOrName() {
        #expect(WirelessBrand.detect(name: "Wireless 1", makeModel: "Shure ULXD4Q") == .shure)
        #expect(WirelessBrand.detect(name: "QLX-D rack", makeModel: "") == .shure)
        #expect(WirelessBrand.detect(name: "", makeModel: "Sennheiser EW-DX EM 4 Dante") == .sennheiser)
        #expect(WirelessBrand.detect(name: "", makeModel: "Audio-Technica ATW-R3210N") == .audioTechnica)
        #expect(WirelessBrand.detect(name: "FOH", makeModel: "Yamaha DM7") == nil)
    }

    @Test func shureChannelCountFollowsTheModelSuffix() {
        #expect(WirelessBrand.shureChannels(model: "ULXD4") == 1)
        #expect(WirelessBrand.shureChannels(model: "ULXD4D") == 2)
        #expect(WirelessBrand.shureChannels(model: "ULXD4Q") == 4)
    }

    @Test func namesFitTheReceiver() {
        #expect(WirelessBrand.shure.sanitizedName("Pastor Mike HH") == "Pastor M")
        #expect(WirelessBrand.audioTechnica.sanitizedName("lead vox, ok") == "LEAD VOX")
        #expect(WirelessBrand.audioTechnica.sanitizedName("a,b") == "AB")
        #expect(WirelessBrand.sennheiser.sanitizedName("  Keys  ") == "Keys")
    }

    // MARK: Shure

    @Test func shureMessagesAreSplitOutOfAStream() {
        var buffer = "< REP 1 CHAN_NAME {Pastor 1} > < SAMPLE 1 ALL AX 120 100 > < REP 2 CHAN"
        let messages = ShureProtocol.extract(&buffer)
        #expect(messages == ["REP 1 CHAN_NAME {Pastor 1}", "SAMPLE 1 ALL AX 120 100"])
        buffer += "_NAME {Keys} >"
        #expect(ShureProtocol.extract(&buffer) == ["REP 2 CHAN_NAME {Keys}"])
        #expect(buffer.isEmpty)
    }

    @Test func shureSampleGivesRFAndAudio() {
        var snap = WirelessSnapshot()
        // RF is the reported value minus 128 dBm; audio is the reported value minus 50 dBFS.
        #expect(ShureProtocol.apply("SAMPLE 1 ALL AX 090 075", to: &snap))
        let c = snap.channels[1]
        #expect(c?.rfDbm == -38)
        #expect(c?.audioDb == 25)  // 75 - 50
        #expect(c?.antenna == "A")
    }

    @Test func shureSampleWithTwoAntennaeUsesTheStrongest() {
        var snap = WirelessSnapshot()
        ShureProtocol.apply("SAMPLE 2 ALL AB 070 100 050", to: &snap)
        #expect(snap.channels[2]?.rfDbm == -28)
        #expect(snap.channels[2]?.antenna == "A+B")
    }

    @Test func shureNoSignalHasNoRF() {
        var snap = WirelessSnapshot()
        ShureProtocol.apply("SAMPLE 1 ALL XX 000 000", to: &snap)
        #expect(snap.channels[1]?.rfDbm == nil)
    }

    @Test func shureReportsFillTheChannel() {
        var snap = WirelessSnapshot()
        ShureProtocol.apply("REP 3 CHAN_NAME {Drum OH }", to: &snap)
        ShureProtocol.apply("REP 3 BATT_BARS 004", to: &snap)
        ShureProtocol.apply("REP 3 FREQUENCY 584500", to: &snap)
        ShureProtocol.apply("REP 3 TX_TYPE ULXD2", to: &snap)
        ShureProtocol.apply("REP MODEL {ULXD4Q}", to: &snap)
        let c = snap.channels[3]
        #expect(c?.name == "Drum OH")
        #expect(c?.batteryFraction == 0.8)
        #expect(c?.frequencyText == "584.500 MHz")
        #expect(c?.transmitterPresent == true)
        #expect(snap.model == "ULXD4Q")
    }

    @Test func shureUnknownBatteryIsBlankAndNoTransmitterIsAbsent() {
        var snap = WirelessSnapshot()
        ShureProtocol.apply("REP 1 BATT_BARS 255", to: &snap)
        ShureProtocol.apply("REP 1 TX_TYPE UNKN", to: &snap)
        #expect(snap.channels[1]?.batteryFraction == nil)
        #expect(snap.channels[1]?.transmitterPresent == false)
    }

    @Test func shureCommandsMatchTheDocument() {
        #expect(ShureProtocol.get(0, "ALL") == "< GET 0 ALL >")
        #expect(ShureProtocol.meterRate(2, milliseconds: 500) == "< SET 2 METER_RATE 00500 >")
        #expect(ShureProtocol.setName(1, "Pastor") == "< SET 1 CHAN_NAME {Pastor} >")
    }

    // MARK: Sennheiser

    @Test func sennheiserMeterReplyFillsTheChannel() {
        var snap = WirelessSnapshot()
        let json = #"{"m":{"rx1":{"rssi":-62.5,"rsqi":88,"divi":2,"af":-18.5}}}"#
        let seen = SennheiserProtocol.apply(Data(json.utf8), to: &snap)
        #expect(seen == [1])
        let c = snap.channels[1]
        #expect(c?.rfDbm == -62.5)
        #expect(c?.rfQuality == 0.88)
        #expect(c?.antenna == "B")
        #expect(c?.audioDb == -18.5)
    }

    @Test func sennheiserStatusReplyFillsNameBatteryAndFrequency() {
        var snap = WirelessSnapshot()
        let json = #"{"rx2":{"name":"Vocal 2","mute":false,"frequency":520000,"warnings":[]},"mates":{"tx2":{"battery":{"gauge":65,"lifetime":312}}}}"#
        SennheiserProtocol.apply(Data(json.utf8), to: &snap)
        let c = snap.channels[2]
        #expect(c?.name == "Vocal 2")
        #expect(c?.frequencyKHz == 520000)
        #expect(c?.batteryFraction == 0.65)
        #expect(c?.batteryText.contains("5h 12m") == true)
        #expect(c?.transmitterPresent == true)
    }

    @Test func sennheiserNoLinkWarningMeansNoTransmitter() {
        var snap = WirelessSnapshot()
        SennheiserProtocol.apply(Data(#"{"rx1":{"warnings":["NoLink"]}}"#.utf8), to: &snap)
        #expect(snap.channels[1]?.transmitterPresent == false)
    }

    @Test func sennheiserErrorEchoDoesNotCreateAChannel() {
        var snap = WirelessSnapshot()
        let seen = SennheiserProtocol.apply(Data(#"{"rx3":{"name":null},"osc":{"error":[404]}}"#.utf8), to: &snap)
        #expect(seen.isEmpty)
        #expect(snap.channels.isEmpty)
    }

    @Test func sennheiserIgnoresGarbage() {
        var snap = WirelessSnapshot()
        #expect(SennheiserProtocol.apply(Data("not json".utf8), to: &snap).isEmpty)
        #expect(snap.channels.isEmpty)
    }

    @Test func sennheiserRequestsAreValidJSON() throws {
        for text in [SennheiserProtocol.meterRequest(1), SennheiserProtocol.statusRequest(2), SennheiserProtocol.probeRequest(3),
                     SennheiserProtocol.setName(1, "A \"B\"")] {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8))
        }
    }

    // MARK: Audio-Technica

    @Test func audioTechnicaCommandsMatchTheDocument() {
        #expect(AudioTechnicaProtocol.levelRequest(1) == "garlv O 0000 00 NC 1\r")
        #expect(AudioTechnicaProtocol.nameRequest(2) == "gprch O 0000 00 NC 2\r")
        #expect(AudioTechnicaProtocol.setName(1, "LEAD") == "sprch S 0000 00 NC 1,\"LEAD\",,,,,,,,\r")
    }

    @Test func audioTechnicaLevelAnswer() {
        var snap = WirelessSnapshot()
        // The example answer from the document.
        let line = "garlv 0000 00 NC 1,10,9,8,-80,9,-78,1,0,0,0,,0,0,0,0,,0,1,1,0,0,1,7,0,4,474325000,0,0"
        #expect(AudioTechnicaProtocol.apply(line, to: &snap))
        let c = snap.channels[1]
        #expect(c?.rfDbm == -78)
        #expect(c?.antenna == "A+B")
        #expect(c?.audioFraction == 9.0 / 16)
        #expect(c?.batteryFraction == 0.9)
        #expect(c?.batteryText == "80–100%")
        #expect(c?.frequencyKHz == 474325)
        #expect(c?.transmitterPresent == true)
    }

    @Test func audioTechnicaNoSignal() {
        var snap = WirelessSnapshot()
        let line = "garlv 0000 00 NC 1,0,0,0,-96,0,-96,0,0,0,0,,0,0,0,0,,0,0,0,0,0,0,0,0,0,474325000,0,0"
        AudioTechnicaProtocol.apply(line, to: &snap)
        #expect(snap.channels[1]?.rfDbm == nil)
        #expect(snap.channels[1]?.transmitterPresent == false)
    }

    @Test func audioTechnicaNameAnswerKeepsSpacesInsideQuotes() {
        var snap = WirelessSnapshot()
        AudioTechnicaProtocol.apply("gprch 0000 00 NC 2,\"LEAD VOX\",,1,,,0,470125000,0,0,0", to: &snap)
        #expect(snap.channels[2]?.name == "LEAD VOX")
    }

    @Test func audioTechnicaAckAndNakAreNotAnswers() {
        var snap = WirelessSnapshot()
        #expect(!AudioTechnicaProtocol.apply("sprch ACK", to: &snap))
        #expect(!AudioTechnicaProtocol.apply("garlv NAK 04", to: &snap))
    }
}
