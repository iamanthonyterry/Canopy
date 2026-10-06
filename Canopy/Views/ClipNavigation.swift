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
