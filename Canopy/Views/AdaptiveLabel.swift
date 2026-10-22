import SwiftUI

// MARK: - Adaptive Label
// Text at regular widths, just the icon once the toolbar tightens.

struct AdaptiveLabel: View {
    let title: String
    let icon: String
    let iconOnly: Bool

    var body: some View {
        if iconOnly {
            Image(systemName: icon)
        } else {
            Text(title).lineLimit(1).fixedSize()
        }
    }
}
