import SwiftUI

/// Settings-level email integration setup: connect (or disconnect) the
/// Gmail account that Notification workflow steps send from. Recipients,
/// headers, and messages are configured per-step in a workflow, not here.
struct EmailNotificationsView: View {
    @EnvironmentObject var appState: AppState
    @State private var gmailAuth = GmailAuthService.shared

    var body: some View {
        GroupBox(label: Label("Email Integration", systemImage: "envelope")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Send From")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let email = gmailAuth.connectedEmail {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(email)
                            .font(.body)
                        Spacer()
                        Button("Disconnect") {
                            gmailAuth.signOut()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    HStack {
                        Button {
                            gmailAuth.signIn()
                        } label: {
                            Label("Connect Gmail Account", systemImage: "envelope.badge")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(gmailAuth.isConnecting)

                        if gmailAuth.isConnecting {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let error = gmailAuth.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                Text("Add a Notification step to any workflow to send email with a custom header, message, and recipients.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
    }
}
