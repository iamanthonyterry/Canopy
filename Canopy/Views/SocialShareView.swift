import SwiftUI

struct SocialShareView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "paperplane")
                .font(.system(size: 36))
                .foregroundStyle(Color.canopySage)
            Text("Social Share").font(.canopyTitle).foregroundStyle(Color.canopyInk)
            Text("Coming soon")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canopyPaper)
    }
}
