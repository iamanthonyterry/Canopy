import SwiftUI

/// Settings for the real-time alerts fired by AlertingService when a
/// device that's actively recording or mid-workflow drops offline, loses
/// auth, loses its drive, or runs low on storage.
struct AlertSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddRecipient = false

    private var settings: Binding<AlertSettings> {
        Binding(get: { appState.alertSettings }, set: { appState.alertSettings = $0 })
    }

    var body: some View {
        GroupBox(label: Label("Live Alerts", systemImage: "bell.badge")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Alert me if a recording device drops or runs low on storage", isOn: settings.isEnabled)

                Text("Fires the instant a device that's actively recording or mid-workflow goes offline, loses its login, loses its drive, or fills up — not for a routine offline device sitting idle.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if settings.wrappedValue.isEnabled {
                    thresholdRow
                    Divider()
                    recipientsHeader
                    recipientsList
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
        .sheet(isPresented: $showingAddRecipient) {
            AddRecipientSheet(isPresented: $showingAddRecipient) { name, email in
                appState.alertSettings.emailRecipients.append(NotificationRecipient(name: name, email: email))
            }
        }
    }

    private var thresholdRow: some View {
        HStack {
            Text("Low Storage Warning At").font(.caption)
            Spacer()
            Stepper(
                "\(settings.wrappedValue.lowStorageThresholdPercent)%",
                value: settings.lowStorageThresholdPercent,
                in: 50...99, step: 5
            )
            .frame(width: 140)
            .font(.caption)
        }
    }

    private var recipientsHeader: some View {
        HStack {
            Text("Also Email").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                showingAddRecipient = true
            } label: {
                Label("Add", systemImage: "plus").font(.caption)
            }
            .buttonStyle(.canopySecondary)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var recipientsList: some View {
        if settings.wrappedValue.emailRecipients.isEmpty {
            Text("No recipients added — the alert will show on this Mac only.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            ForEach(settings.wrappedValue.emailRecipients) { recipient in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipient.name).font(.body)
                        Text(recipient.email).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appState.alertSettings.emailRecipients.removeAll { $0.id == recipient.id }
                    } label: {
                        Image(systemName: "trash").foregroundStyle(Color.canopyRust)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
