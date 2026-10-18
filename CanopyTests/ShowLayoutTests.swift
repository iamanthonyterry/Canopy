import Foundation
import Testing
@testable import Canopy

@MainActor
struct ShowLayoutTests {
    @Test func addPacksTilesWithoutOverlap() {
        var screen = ShowScreen(name: "A")
        screen.add(.activeRuns)
        screen.add(.hyperDeck(UUID()))
        screen.add(.hyperDeck(UUID()))
        screen.add(.hyperDeck(UUID()))
        for (i, a) in screen.tiles.enumerated() {
            #expect(a.col >= 0 && a.col + a.width <= ShowScreen.columns)
            for b in screen.tiles[(i + 1)...] { #expect(!a.overlaps(b)) }
        }
        // Three 4-wide decks fill one row beneath the full-width runs tile.
        #expect(screen.tiles.dropFirst().allSatisfy { $0.row == 2 })
    }

    @Test func aDeviceIsOnAViewOnlyOnce() {
        var screen = ShowScreen(name: "A")
        let id = UUID()
        let first = screen.add(.cloudStore(id))
        let second = screen.add(.cloudStore(id))
        #expect(first && !second)
        #expect(screen.tiles.count == 1)
    }

    @Test func placeRefusesOffGridAndOverlap() {
        var screen = ShowScreen(name: "A")
        screen.add(.cloudStore(UUID()))
        screen.add(.cloudStore(UUID()))
        let first = screen.tiles[0], second = screen.tiles[1]
        let onto = screen.place(second.id, col: first.col, row: first.row, width: 3, height: 1)
        let offRight = screen.place(second.id, col: 11, row: 0, width: 3, height: 1)
        let offLeft = screen.place(second.id, col: -1, row: 0, width: 3, height: 1)
        let empty = screen.place(second.id, col: 0, row: 5, width: 0, height: 1)
        #expect(!onto && !offRight && !offLeft && !empty)
        #expect(screen.tiles[1] == second)
        let moved = screen.place(second.id, col: 0, row: 4, width: 5, height: 2)
        #expect(moved)
        #expect(screen.rowCount == 6)
    }

    @Test func duplicateHasFreshIDsAndSameLayout() {
        var screen = ShowScreen(name: "A")
        screen.add(.activeRuns)
        let copy = screen.duplicated(named: "B")
        #expect(copy.id != screen.id && copy.tiles[0].id != screen.tiles[0].id)
        #expect(copy.tiles[0].device == .activeRuns && copy.tiles[0].width == screen.tiles[0].width)
    }

    @Test func savedScreensRoundTrip() throws {
        var screen = ShowScreen(name: "A")
        screen.add(.wireless("abc"))
        screen.add(.hyperDeck(UUID()))
        let back = try JSONDecoder().decode(ShowScreen.self, from: JSONEncoder().encode(screen))
        #expect(back == screen)
    }
}
