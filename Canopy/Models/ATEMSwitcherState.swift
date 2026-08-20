import Foundation

// MARK: - ATEM Switcher State
//
// A saved snapshot of an ATEM switcher's live production settings — the
// things a director actually wants back after someone else has been on the
// switcher: which input is on program/preview, and which upstream keyers
// are on air, per M/E.
//
// Deliberately NOT included yet (see ATEMStateSession.swift for why):
// transition style/rate, downstream keyers, color generators, audio mixer,
// camera control, media pool stills, and macros. Each of those needs its
// exact wire-protocol byte layout confirmed against a real switcher before
// it's safe to replay blind during a live service — this snapshot only
// contains the handful of fields already proven out by ATEMControlService's
// existing Cut/Auto/Program-Input commands.
struct ATEMSwitcherState: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String = ""
    var savedAt: Date = Date()
    var mixEffects: [MixEffectState] = []
}

struct MixEffectState: Codable, Equatable {
    var index: UInt8
    var programInput: UInt16 = 1
    var previewInput: UInt16 = 1
    var upstreamKeyers: [KeyerOnAirState] = []
}

struct KeyerOnAirState: Codable, Equatable {
    var index: UInt8
    var isOnAir: Bool = false
}
