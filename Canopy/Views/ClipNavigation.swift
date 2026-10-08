import SwiftUI

extension View {
    /// Left / right arrow keys step to the previous / next clip while a
    /// preview sheet is open. Hidden buttons carry the shortcuts so they work
    /// without the sheet needing keyboard focus.
    @ViewBuilder
    func clipNavigationShortcuts(_ onNavigate: ((Int) -> Void)?) -> some View {
        if let onNavigate {
            background {
                HStack {
                    Button("Previous") { onNavigate(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("Next") { onNavigate(1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            self
        }
    }
}

/// Actions the video player exposes to keyboard shortcuts.
struct PlayerShortcutActions {
    var togglePlayback: () -> Void
    var shuttleReverse: () -> Void
    var pause: () -> Void
    var shuttleForward: () -> Void
    var stepFrame: (Int) -> Void
    var setIn: () -> Void
    var setOut: () -> Void
    var clearRange: () -> Void
    var addMarker: () -> Void
}

extension View {
    /// Space, J/K/L shuttle, `,` `.` frame step, I/O in/out (⌥ clears the
    /// range), M marker. Same hidden-button approach as
    /// `clipNavigationShortcuts` so no keyboard focus is needed.
    func playerShortcuts(_ a: PlayerShortcutActions) -> some View {
        background {
            HStack {
                Button("Play/Pause") { a.togglePlayback() }.keyboardShortcut(.space, modifiers: [])
                Button("Shuttle Back") { a.shuttleReverse() }.keyboardShortcut("j", modifiers: [])
                Button("Pause") { a.pause() }.keyboardShortcut("k", modifiers: [])
                Button("Shuttle Forward") { a.shuttleForward() }.keyboardShortcut("l", modifiers: [])
                Button("Previous Frame") { a.stepFrame(-1) }.keyboardShortcut(",", modifiers: [])
                Button("Next Frame") { a.stepFrame(1) }.keyboardShortcut(".", modifiers: [])
                Button("Set In") { a.setIn() }.keyboardShortcut("i", modifiers: [])
                Button("Set Out") { a.setOut() }.keyboardShortcut("o", modifiers: [])
                Button("Clear Range") { a.clearRange() }.keyboardShortcut("x", modifiers: [.option])
                Button("Add Marker") { a.addMarker() }.keyboardShortcut("m", modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
