import Foundation
import Testing
@testable import Canopy

@MainActor
struct FindClipsStepTests {
    @Test func exportSettingsRoundTrip() throws {
        let action = StepAction.findClips(maxClips: 3, minSeconds: 15, maxSeconds: 45, exportFormat: .square, captions: false)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
    }

    @Test func stepSavedBeforeExportExistedStillLoads() throws {
        let json = #"{"findClips":{"maxClips":4,"minSeconds":20,"maxSeconds":60}}"#.data(using: .utf8)!
        let action = try JSONDecoder().decode(StepAction.self, from: json)
        #expect(action == .findClips(maxClips: 4, minSeconds: 20, maxSeconds: 60, exportFormat: nil, captions: true))
    }
}
