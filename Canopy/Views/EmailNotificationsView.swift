import SwiftUI

/// Settings-level email status. Notification steps send from Canopy's own
/// address through the church site, so the only setup is being signed in to
/// it. Recipients, headers, and messages are configured per-step in a workflow.
struct EmailNotificationsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var account = SiteAccount.shared

    var body: some View {
        GroupBox(label: Label("Email Notifications", systemImage: "envelope")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Sent from") {
                    Text(NotificationMailer.fromAddress)
                        .font(.canopyBody)
                        .textSelection(.enabled)
                }

                if account.isConnected {
                    Label("Ready — signed in to the church site", systemImage: "checkmark.circle.fill")
                        .font(.canopyBody)
                        .foregroundStyle(Color.canopySage)
                } else {
                    Label("Sign in under Church Account above to send email", systemImage: "exclamationmark.triangle.fill")
                        .font(.canopyBody)
                        .foregroundStyle(.orange)
                }

                Text("Add a Notification step to any workflow to send email with a custom header, message, and recipients. Replies go to whoever ran the workflow.")
                    .font(.canopyCaption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
    }
}
