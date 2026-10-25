import SwiftUI

// MARK: - The website connection
// Canopy talks to the church's website with one thing: the campus key, set when this Mac is connected to a campus
// (Settings → Transcription → Website). It covers the live transcript, device jobs, workflow progress, the shared workflow
// list and email. There is no separate person sign-in. This card shows what the connection is being used for.

/// Settings → More: what the campus connection covers, and switches for sharing progress and syncing workflows.
struct WebsiteCard: View {
    @ObservedObject private var connection = CampusConnection.shared
    @ObservedObject private var sync = WorkflowSyncService.shared
    @ObservedObject private var publisher = WorkflowRunPublisher.shared

    var body: some View {
        GroupBox(label: Label("Website", systemImage: "globe")) {
            VStack(alignment: .leading, spacing: 12) {
                if connection.isConnected { connected } else { notConnected }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect this Mac to your campus to share workflow progress on the website, keep workflows in step with your other Macs at the campus, and send email from workflows.")
                .font(.canopyBody).foregroundStyle(.secondary)
            Button {
                UserDefaults.standard.set(SettingsTab.transcription.rawValue, forKey: SettingsTab.storageKey)
            } label: { Label("Connect in Transcription settings…", systemImage: "link") }
                .buttonStyle(.canopyPrimary)
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.canopySage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.campusName.isEmpty ? "Connected to a campus" : "Connected to \(connection.campusName)").font(.canopySubheadline)
                    if let host = connection.site?.host { Text(host).font(.canopyCaption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let origin = connection.origin { Link("Open website", destination: origin).font(.canopyCaption) }
            }
            Divider()

            row("Workflows", icon: "arrow.triangle.2.circlepath",
                detail: sync.isEnabled ? SyncStatus.text(sync) : "Not shared with this campus's other Macs",
                ok: sync.isEnabled && sync.lastError == nil) {
                Toggle("Sync", isOn: $sync.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            row("Run progress", icon: "globe",
                detail: publisher.lastError ?? (publisher.isEnabled ? "Shared on the website" : "Not shared"),
                ok: publisher.isEnabled && publisher.lastError == nil) {
                Toggle("Share", isOn: $publisher.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            row("Email", icon: "envelope", detail: "Sends from \(NotificationMailer.fromAddress)", ok: true)
        }
    }

    private func row(_ title: String, icon: String, detail: String, ok: Bool,
                     @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(ok ? Color.canopySage : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.canopySubheadline)
                Text(detail).font(.canopyCaption).foregroundStyle(ok ? Color.secondary : Color.canopyRust)
            }
            Spacer()
            trailing()
        }
    }
}

/// One-line description of where workflow sync stands.
enum SyncStatus {
    @MainActor static func text(_ sync: WorkflowSyncService) -> String {
        if let error = sync.lastError { return error }
        if sync.isSyncing { return "Syncing…" }
        if let at = sync.lastSynced { return "Synced \(at.formatted(date: .omitted, time: .shortened))" }
        return "Waiting to sync"
    }
}
