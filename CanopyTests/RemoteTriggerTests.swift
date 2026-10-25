import Foundation
import Testing
@testable import Canopy

@MainActor
struct ControlTriggerMatchTests {
    private func osc(_ address: String, _ args: OSCValue...) -> OSCMessage { OSCMessage(address: address, arguments: args) }

    @Test func oscAddressesMatchPartByPartIgnoringCase() {
        let m = osc("/Cue/12/Start")
        #expect(ControlTriggerMatch.osc(address: "/cue/12/start", argument: "", message: m))
        #expect(ControlTriggerMatch.osc(address: "/cue/*/start", argument: "", message: m))
        #expect(!ControlTriggerMatch.osc(address: "/cue/13/start", argument: "", message: m))
        #expect(!ControlTriggerMatch.osc(address: "/cue/12", argument: "", message: m), "a shorter address is not a match")
        #expect(!ControlTriggerMatch.osc(address: "/cue/12/start/now", argument: "", message: m))
        #expect(!ControlTriggerMatch.osc(address: "cue/12/start", argument: "", message: m), "an address starts with a slash")
        #expect(!ControlTriggerMatch.osc(address: "", argument: "", message: m))
    }

    @Test func anArgumentFilterComparesNumbersAsNumbers() {
        #expect(ControlTriggerMatch.osc(address: "/go", argument: "1", message: osc("/go", .int(1))))
        #expect(ControlTriggerMatch.osc(address: "/go", argument: "1", message: osc("/go", .float(1.0))))
        #expect(ControlTriggerMatch.osc(address: "/go", argument: "1", message: osc("/go", .string("1"))))
        #expect(!ControlTriggerMatch.osc(address: "/go", argument: "1", message: osc("/go", .int(0))), "a button release is not a press")
        #expect(ControlTriggerMatch.osc(address: "/scene", argument: "Intro", message: osc("/scene", .string("intro"))))
        #expect(!ControlTriggerMatch.osc(address: "/go", argument: "1", message: osc("/go")), "a filter needs an argument to compare")
        #expect(ControlTriggerMatch.osc(address: "/go", argument: "", message: osc("/go")), "no filter, any value")
    }

    @Test func midiMatchesKindChannelAndNumberButNotReleases() {
        func note(_ n: Int, ch: Int = 0, v: Int = 100, kind: MIDIMessage.Kind = .noteOn) -> MIDIMessage { MIDIMessage(kind: kind, channel: ch, number: n, value: v) }
        #expect(ControlTriggerMatch.midi(kind: .noteOn, channel: 0, number: 60, message: note(60)))
        #expect(!ControlTriggerMatch.midi(kind: .noteOn, channel: 1, number: 60, message: note(60)))
        #expect(!ControlTriggerMatch.midi(kind: .noteOn, channel: 0, number: 61, message: note(60)))
        #expect(!ControlTriggerMatch.midi(kind: .noteOn, channel: 0, number: 60, message: note(60, kind: .noteOff)))
        #expect(!ControlTriggerMatch.midi(kind: .noteOn, channel: 0, number: 60, message: note(60, v: 0)), "Note On with velocity 0 is a release")
        #expect(ControlTriggerMatch.midi(kind: .controlChange, channel: 2, number: 20, message: note(20, ch: 2, v: 0, kind: .controlChange)))
        #expect(ControlTriggerMatch.midi(kind: .programChange, channel: 0, number: 5, message: note(5, v: 0, kind: .programChange)))
    }
}

@MainActor
struct RemoteTriggerModelTests {
    @Test func newTriggerFieldsSurviveSavingAndLoading() throws {
        var t = ScheduleSettings()
        t.mode = .osc; t.oscAddress = "/cue/*/start"; t.oscArgument = "1"; t.midiKind = .controlChange; t.midiChannel = 3; t.midiNumber = 20
        t.voicePhrase = "start the offload, begin offload"; t.cooldownSeconds = 9
        let back = try JSONDecoder().decode(ScheduleSettings.self, from: JSONEncoder().encode(t))
        #expect(back.mode == .osc && back.oscAddress == "/cue/*/start" && back.oscArgument == "1")
        #expect(back.midiKind == .controlChange && back.midiChannel == 3 && back.midiNumber == 20)
        #expect(back.voicePhrase == "start the offload, begin offload" && back.cooldownSeconds == 9)
    }

    @Test func triggersSavedBeforeTheseExistedStillLoad() throws {
        let old = #"{"isEnabled":true,"mode":"daily","hour":9,"minute":30}"#
        let t = try JSONDecoder().decode(ScheduleSettings.self, from: Data(old.utf8))
        #expect(t.mode == .daily && t.hour == 9 && t.oscAddress.isEmpty && t.cooldownSeconds == 3)
    }

    @Test func aVoiceTriggerBecomesAPhraseRuleThatMatchesWhatIsSaid() throws {
        let id = UUID()
        let rule = OSCRule(phrase: "start the offload, begin offload", kind: .workflow, address: OSCRule.workflowPrefix + id.uuidString)
        #expect(rule.isSendable)
        #expect(rule.workflowTriggerID == id)
        #expect(!OSCRule(phrase: "x", kind: .workflow, address: "workflow:not-a-uuid").isSendable)
        #expect(OSCRule(phrase: "x", kind: .osc, address: "workflow:\(id)").workflowTriggerID == nil, "only a workflow rule runs a workflow")
        for said in ["okay please start the offload now", "Begin offload.", "start the off-load"] {
            let found = Cues.matches([rule], in: Cues.words(said))
            #expect(found.count == (said.contains("off-load") ? 0 : 1), "\(said)")
        }
    }

    @Test func remoteModesAreEventTriggersTheBuilderOffers() {
        for mode in [ScheduleMode.osc, .midi, .voiceCue] {
            #expect(mode.isEvent && mode.isRemote)
            #expect(ScheduleMode.eventModes.contains(mode))
            #expect(!ScheduleMode.scheduleModes.contains(mode))
        }
        #expect(!ScheduleMode.folderChanged.isRemote)
    }
}
