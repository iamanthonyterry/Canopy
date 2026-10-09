import Foundation
import Testing
@testable import Canopy

@MainActor
struct ClipSuggestionsModelTests {
    @Test func slugKeepsFileNamesSafe() {
        #expect(ClipSuggestionsModel.slug("Fired from graphic design job!") == "Fired-from-graphic-design-job")
        #expect(ClipSuggestionsModel.slug("A/B: what? ??") == "A-B-what")
        #expect(ClipSuggestionsModel.slug("???") == "clip")
    }
}
