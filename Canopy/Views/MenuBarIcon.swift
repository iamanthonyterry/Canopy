import AppKit
import SwiftUI

/// Canopy's menu bar icon: the tree, turning red while a workflow is running.
/// Menu bar icons are templates (always monochrome), so the red one has to be a pre-tinted, non-template image.
struct MenuBarIcon: View {
    static let symbol = "tree.circle"
    let isRunning: Bool

    var body: some View {
        if isRunning, let tinted = Self.tinted(.systemRed) {
            Image(nsImage: tinted)
        } else {
            Image(systemName: Self.symbol)
        }
    }

    private static func tinted(_ color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Canopy, a workflow is running")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
