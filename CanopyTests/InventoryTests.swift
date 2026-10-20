import Foundation
import Testing
@testable import Canopy

@MainActor
struct InventoryTests {
    private func port(_ id: String, _ device: String, _ n: Int?, _ dir: PortDirection, label: String = "", signal: Signal = .analog, card: String? = nil) -> EquipmentPort {
        EquipmentPort(id: id, equipmentId: device, number: n, label: label, kind: "", direction: dir, signal: signal, cardId: card)
    }

    // MARK: Patch import

    @Test func parsesTheTemplate() {
        let (rows, problems) = PatchImport.parse(PatchImport.templateCSV)
        #expect(problems.isEmpty)
        #expect(rows.count == 3)
        #expect(rows[0].fromDevice == "Stage box" && rows[0].fromChannel == 1 && rows[0].toName == "Kick In")
        #expect(rows[1].note == "Long run, snake A")
        #expect(rows[2].fromCard == "Dante" && rows[2].toCard == "Dante")
    }

    @Test func readsLooseHeadingsTabsAndQuotes() {
        let text = "Source\tSource ch\tDestination\tDest channel\tNotes\nStage box\tCh 3\tMixer\t3\t\"tab\tinside\"\n"
        let (rows, problems) = PatchImport.parse(text)
        #expect(problems.isEmpty)
        #expect(rows.count == 1)
        #expect(rows[0].fromChannel == 3 && rows[0].toChannel == 3)
        #expect(rows[0].note == "tab\tinside")
    }

    @Test func reportsBadRowsByTheirSpreadsheetNumber() {
        let text = "From device,From channel,To device,To channel\nA,1,B,1\nA,x,B,2\n,3,B,3\n"
        let (rows, problems) = PatchImport.parse(text)
        #expect(rows.count == 1)
        #expect(problems == ["row 3: \"x\" isn't a channel number", "row 4: needs a device on both ends"])
    }

    @Test func refusesASheetWithoutBothEnds() {
        let (rows, problems) = PatchImport.parse("Device,Channel\nA,1\n")
        #expect(rows.isEmpty)
        #expect(problems.first?.hasPrefix("Couldn't find the from and to columns") == true)
    }

    @Test func exportRoundTrips() {
        let mixer = Equipment(id: "m", name: "Mixer, FOH", ports: [port("mi1", "m", 1, .input, label: "Kick")])
        let box = Equipment(id: "b", name: "Stage box", ports: [port("bo1", "b", 1, .output)])
        let patch = Patch(cable: Cable(id: "c", fromPort: "bo1", toPort: "mi1", note: "say \"hi\""),
                          from: PatchPort(port: box.ports[0], device: box, place: ""), to: PatchPort(port: mixer.ports[0], device: mixer, place: ""))
        let (rows, problems) = PatchImport.parse(PatchImport.export([patch]))
        #expect(problems.isEmpty)
        #expect(rows == [ImportRow(fromDevice: "Stage box", fromChannel: 1, toDevice: "Mixer, FOH", toChannel: 1, toName: "Kick", note: "say \"hi\"")])
    }

    // MARK: Links and signal flow

    @Test func stageBoxLandsOneToOnePlusOffsetUnlessReassigned() {
        let box = [port("b1", "box", 1, .input), port("b2", "box", 2, .input), port("bo1", "box", 1, .output)]
        let host = [port("h3", "con", 3, .input), port("h4", "con", 4, .input), port("h9", "con", 9, .input), port("ho3", "con", 3, .output)]
        let link = StageLink(id: "l", equipmentId: "box", hostId: "con", hostCardId: nil, signal: .gigaace, portOffset: 2)
        let pairs = InventoryRules.resolveLink(link, box: box, host: host, overrides: ["b2": "h9"])
        #expect(pairs.map { "\($0.box.id)>\($0.host.id)>\($0.custom)" } == ["b1>h3>false", "b2>h9>true", "bo1>ho3>false"])  // outputs come back the same way
    }

    @Test func aBoxsDefaultLandingGivesWayToACableOrAReassignedChannel() {
        let box = [port("b1", "box", 1, .input), port("b2", "box", 2, .input), port("b3", "box", 3, .input),
                   port("bo1", "box", 1, .output), port("bo2", "box", 2, .output)]
        let host = [port("h1", "con", 1, .input), port("h2", "con", 2, .input), port("h3", "con", 3, .input),
                    port("ho1", "con", 1, .output), port("ho2", "con", 2, .output)]
        let link = StageLink(id: "l", equipmentId: "box", hostId: "con", hostCardId: nil, signal: .gigaace, portOffset: 0)
        // A Dante cable feeds console input 2, box channel 3 was reassigned onto console input 1, and console output 1
        // is cabled to a processor.
        let pairs = InventoryRules.resolveLink(link, box: box, host: host, overrides: ["b3": "h1"], taken: ["h2", "ho1"])
        #expect(pairs.map { "\($0.box.id)>\($0.host.id)" } == ["b3>h1", "bo2>ho2"])
    }

    @Test func onlyAudioOverANetworkFansOut() {
        #expect(Signal.allCases.filter(\.fansOut) == [.dante, .soundgrid, .avb])
    }

    @Test func aReassignedBoxOutputCanStillShareAConsoleOutput() {
        let box = [port("bo1", "box", 1, .output)]
        let host = [port("ho1", "con", 1, .output), port("ho5", "con", 5, .output)]
        let link = StageLink(id: "l", equipmentId: "box", hostId: "con", hostCardId: nil, signal: .gigaace, portOffset: 0)
        // Chosen on purpose, so a mix already cabled elsewhere can go out of the box too.
        let pairs = InventoryRules.resolveLink(link, box: box, host: host, overrides: ["bo1": "ho5"], taken: ["ho5"])
        #expect(pairs.map { "\($0.box.id)>\($0.host.id)" } == ["bo1>ho5"])
    }

    @Test func linksThroughACardOnlyUseThatCardsChannels() {
        let box = [port("b1", "box", 1, .input)]
        let host = [port("own1", "con", 1, .input), port("card1", "con", 1, .input, card: "slot1")]
        let link = StageLink(id: "l", equipmentId: "box", hostId: "con", hostCardId: "slot1", signal: .dante, portOffset: 0)
        #expect(InventoryRules.resolveLink(link, box: box, host: host, overrides: [:]).map(\.host.id) == ["card1"])
    }

    @Test func chainsFollowCablesAndLinksToTheEnd() {
        let mic = Equipment(id: "mic", name: "Mic", role: .source, ports: [port("mo", "mic", 1, .output)])
        let box = Equipment(id: "box", name: "Box", role: .stageBox, ports: [port("bi", "box", 1, .input)])
        let con = Equipment(id: "con", name: "Console", role: .console, ports: [port("ci", "con", 1, .input)])
        let pp = { (p: EquipmentPort, e: Equipment) in PatchPort(port: p, device: e, place: "") }
        let cable = Patch(cable: Cable(id: "c1", fromPort: "mo", toPort: "bi", note: "snake A"), from: pp(mic.ports[0], mic), to: pp(box.ports[0], box))
        let hop = Hop(from: pp(box.ports[0], box), to: pp(con.ports[0], con), custom: false, linkId: "l")
        let chains = InventoryRules.buildChains(patches: [cable], hops: [hop])
        #expect(chains.count == 1)
        #expect(chains[0].stops.map(\.device.name) == ["Mic", "Box", "Console"])
        #expect(chains[0].via == [.cable, .link])
        #expect(chains[0].notes == ["snake A", ""])
    }

    @Test func chainsNeverLoopForever() {
        let a = Equipment(id: "a", name: "A", ports: [port("a1", "a", 1, .both)])
        let b = Equipment(id: "b", name: "B", ports: [port("b1", "b", 1, .both)])
        let pa = PatchPort(port: a.ports[0], device: a, place: ""), pb = PatchPort(port: b.ports[0], device: b, place: "")
        let loop = [Patch(cable: Cable(id: "1", fromPort: "a1", toPort: "b1", note: ""), from: pa, to: pb),
                    Patch(cable: Cable(id: "2", fromPort: "b1", toPort: "a1", note: ""), from: pb, to: pa)]
        #expect(InventoryRules.buildChains(patches: loop, hops: []).isEmpty)  // everything is fed, so nothing starts
    }

    // MARK: Console channels

    private func channel(_ id: String, _ kind: ChannelKind, _ n: Int, label: String = "") -> ConsoleChannel {
        ConsoleChannel(id: id, equipmentId: "con", kind: kind, number: n, label: label)
    }

    @Test func channelCountsAddTheGapsAndDropPastTheEnd() {
        let have = [channel("c1", .input, 1), channel("c3", .input, 3), channel("c5", .input, 5)]
        let change = InventoryRules.channelChanges(have, count: 4)
        #expect(change.add == [2, 4])
        #expect(change.remove == ["c5"])
        let none = InventoryRules.channelChanges(have, count: 0)
        #expect(none.add.isEmpty && none.remove == ["c1", "c3", "c5"])
    }

    @Test func blockPairsChannelsWithSocketsInOrderUntilEitherRunsOut() {
        let chs = (1...8).map { channel("c\($0)", .input, $0) }
        let sockets = (1...4).map { (n: Int) in port("s\(n)", "box", n, .input) }
        let pairs = InventoryRules.block(channels: chs, first: 3, count: 16, sockets: sockets, start: "s2")
        #expect(pairs.map { "\($0.channel.number)>\($0.socket.id)" } == ["3>s2", "4>s3", "5>s4"])
        #expect(InventoryRules.block(channels: chs, first: 1, count: 2, sockets: sockets, start: "nope").isEmpty)
    }

    @Test func stereoSidesReadTheTrailingLOrR() {
        #expect(InventoryRules.stereoSide("Keys L")?.right == false)
        #expect(InventoryRules.stereoSide("keys-r")?.right == true)
        #expect(InventoryRules.stereoSide("Keys L")?.base == InventoryRules.stereoSide("KEYS R")?.base)
        #expect(InventoryRules.stereoSide("Overhead") == nil)
        #expect(InventoryRules.stereoSide("L") == nil)
        #expect(InventoryRules.runs([1, 2, 3, 7, 9, 10]) == "1–3, 7, 9–10")
    }

    @Test func channelIssuesFlagSharedLooseUnnamedAndBrokenPairs() {
        let chs = [channel("c1", .input, 1, label: "Kick"), channel("c2", .input, 2, label: "Snare"), channel("c3", .input, 3),
                   channel("c4", .input, 4, label: "Keys L"), channel("c6", .input, 6, label: "Keys R"),
                   channel("c7", .input, 7, label: "Pad L")]
        let ports = ["s1": port("s1", "box", 1, .input), "s2": port("s2", "box", 2, .input), "s3": port("s3", "box", 3, .input), "s9": port("s9", "box", 9, .input)]
        let patches = [ConsolePatch(id: "p1", channelId: "c1", portId: "s1"), ConsolePatch(id: "p2", channelId: "c3", portId: "s1"),
                       ConsolePatch(id: "p3", channelId: "c4", portId: "s2"), ConsolePatch(id: "p4", channelId: "c6", portId: "s9")]
        let issues = InventoryRules.channelIssues(channels: chs, patches: patches, port: { ports[$0] }, portName: { $0 })
        let text = issues.map(\.message)
        #expect(text.contains { $0.contains("s1 feeds channels 1, 3") })
        #expect(text.contains { $0.contains("Channels 2, 7") || $0.contains("Channel 2") })
        #expect(text.contains { $0.contains("Channel 3 is patched but unnamed") })
        #expect(text.contains { $0.contains("Keys L") && $0.contains("neighbouring channels") })
        #expect(text.contains { $0.contains("Pad L has no matching right") })
        let good = [channel("a", .input, 1, label: "Keys L"), channel("b", .input, 2, label: "Keys R")]
        let ok = InventoryRules.channelIssues(channels: good, patches: [ConsolePatch(id: "x", channelId: "a", portId: "s1"), ConsolePatch(id: "y", channelId: "b", portId: "s2")],
                                              port: { ports[$0] }, portName: { $0 })
        #expect(ok.isEmpty)
    }

    @Test func surfacesAndBoxesOnThemDontLandOnChannels() {
        #expect(InventoryRules.landsChannels(box: .stageBox, host: .console))
        #expect(!InventoryRules.landsChannels(box: .surface, host: .console))
        #expect(!InventoryRules.landsChannels(box: .stageBox, host: .surface))
    }

    @Test func chainsRunThroughTheConsolePatchToAChannelAndOutOfAMix() {
        let mic = Equipment(id: "mic", name: "Mic", role: .source, ports: [port("mo", "mic", 1, .output)])
        let surface = Equipment(id: "srf", name: "S5000", role: .surface, ports: [port("si", "srf", 1, .input), port("so", "srf", 1, .output)])
        let con = Equipment(id: "con", name: "MixRack", role: .console)
        let amp = Equipment(id: "amp", name: "Amp", role: .amp, ports: [port("ai", "amp", 1, .input)])
        let pp = { (p: EquipmentPort, e: Equipment) in PatchPort(port: p, device: e, place: "") }
        let kick = channel("ch1", .input, 1, label: "Kick"), mains = channel("mx1", .output, 1, label: "Mains")
        let cables = [
            Patch(cable: Cable(id: "c1", fromPort: "mo", toPort: "si", note: ""), from: pp(mic.ports[0], mic), to: pp(surface.ports[0], surface)),
            Patch(cable: Cable(id: "c2", fromPort: "so", toPort: "ai", note: ""), from: pp(surface.ports[1], surface), to: pp(amp.ports[0], amp)),
        ]
        let routes = [Route(from: pp(surface.ports[0], surface), to: pp(kick.asPort, con), channelId: "ch1"),
                      Route(from: pp(mains.asPort, con), to: pp(surface.ports[1], surface), channelId: "mx1")]
        let chains = InventoryRules.buildChains(patches: cables, hops: [], routes: routes)
        #expect(chains.map { $0.stops.map(\.name) } == [["Output 1", "Input 1", "Ch 1 · Kick"], ["Mix 1 · Mains", "Output 1", "Input 1"]])
        #expect(chains[0].via == [.cable, .route])
        #expect(chains[1].via == [.route, .cable])
    }

    // MARK: Advice

    @Test func peerFitPrefersTheUsualDeviceAndMatchingSignal() {
        let usual = InventoryRules.peerFit(mineRole: .console, direction: .input, signal: .analog, otherRole: .stageBox, otherSignal: .analog)
        let odd = InventoryRules.peerFit(mineRole: .console, direction: .input, signal: .analog, otherRole: .speaker, otherSignal: .analog)
        let wrongSignal = InventoryRules.peerFit(mineRole: .console, direction: .input, signal: .dante, otherRole: .stageBox, otherSignal: .analog)
        #expect(usual.rank == 0 && usual.warning.isEmpty)
        #expect(odd.rank == 50 && odd.warning.contains("don't usually connect to a speaker"))
        #expect(wrongSignal.rank == 100 && wrongSignal.warning.hasPrefix("Dante doesn't connect straight to Analog"))
    }

    @Test func suggestsRolesFromNames() {
        #expect(InventoryRules.suggestRole(name: "dLive DM64", makeModel: "", category: "Audio") == .console)
        #expect(InventoryRules.suggestRole(name: "DX168 stage left", makeModel: "", category: "Audio") == .stageBox)
        #expect(InventoryRules.suggestRole(name: "Shure PSM1000", makeModel: "", category: "Audio") == .iemTransmitter)
        #expect(InventoryRules.suggestRole(name: "Shure AD4Q", makeModel: "", category: "Audio") == .wirelessReceiver)
        #expect(InventoryRules.suggestRole(name: "NovaStar VX1000", makeModel: "", category: "Video") == .ledProcessor)
        #expect(InventoryRules.suggestRole(name: "Coffee maker", makeModel: "", category: "") == nil)
    }

    // MARK: Places and addresses

    @Test func placeLabelSkipsATypedLocationThatRepeatsTheRoom() {
        let rooms = ["r": Room(id: "r", name: "Sanctuary", campus: "")]
        let racks = ["k": Rack(id: "k", roomId: "r", name: "Rack A", units: 42)]
        var e = Equipment(id: "e", name: "X", location: "sanctuary", roomId: "r", rackId: "k", rackUnit: 12, rackHeight: 2)
        #expect(InventoryRules.placeLabel(e, rooms: rooms, racks: racks) == "Sanctuary · Rack A U12–13")
        e.location = "left shelf"
        #expect(InventoryRules.placeLabel(e, rooms: rooms, racks: racks) == "Sanctuary · Rack A U12–13 · left shelf")
    }

    @Test func hostOfStripsSchemePortAndPath() {
        #expect(InventoryRules.hostOf("http://192.168.1.20:8080/index.html") == "192.168.1.20")
        #expect(InventoryRules.hostOf(" videohub.local ") == "videohub.local")
        #expect(InventoryRules.hostOf("not a host!") == nil)
    }

    @Test func storedDaysSurviveTheDatePickerInAnyTimeZone() {
        let d = InventoryRules.localDate("2027-03-15")!
        #expect(InventoryRules.localDayString(d) == "2027-03-15")
    }

    @Test func warrantyStates() {
        let now = InventoryRules.day("2026-10-14")!
        #expect(InventoryRules.warrantyState(nil, now: now) == .none)
        #expect(InventoryRules.warrantyState("2026-10-13", now: now) == .expired)
        #expect(InventoryRules.warrantyState("2026-12-01", now: now) == .soon)
        #expect(InventoryRules.warrantyState("2027-06-01", now: now) == .active)
    }

    @Test func detectsDrivers() {
        #expect(DeviceDriver.detect(name: "Router", makeModel: "Blackmagic Smart Videohub 40x40") == .videohub)
        #expect(DeviceDriver.detect(name: "FOH", makeModel: "Allen & Heath dLive DM64") == .ahScene)
        #expect(DeviceDriver.detect(name: "DX168 expander", makeModel: "Allen & Heath dLive") == nil)
    }
}
