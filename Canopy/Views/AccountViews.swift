import SwiftUI

// MARK: - One sign-in
// Signing in with the church's website once covers everything in Canopy that
// uses it: the inventory, synced workflows, run sharing, notification email and
// the Transcriber helper's campus. These views are the single place that
// sign-in is explained and done; every other screen shows a status or a
// compact prompt that points here.

/// The sign-in button with its waiting, cancel and error states.
struct AccountSignInButton: View {
    @ObservedObject private var account = SiteAccount.shared
    var title = "Sign in with website…"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { account.signIn() } label: {
                    Label(account.isConnecting ? "Waiting for the browser…" : title, systemImage: "person.badge.key")
                }
                .buttonStyle(.canopyPrimary)
                .disabled(account.isConnecting)
                if account.isConnecting {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { account.cancelSignIn() }.buttonStyle(.canopySecondary)
                }
            }
            if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.canopyCaption).foregroundStyle(Color.canopyRust)
            }
        }
    }
}

/// A short "sign in to use this" prompt for screens that need the account.
struct AccountPrompt: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.canopyBody).foregroundStyle(.secondary)
            AccountSignInButton()
        }
        .canopyCard()
    }
}

/// Settings: the one place to see and manage the sign-in and what it covers.
struct AccountCard: View {
    @ObservedObject private var account = SiteAccount.shared
    @ObservedObject private var sync = WorkflowSyncService.shared
    @ObservedObject private var publisher = WorkflowRunPublisher.shared
    @ObservedObject private var remote = RemoteComputersService.shared
    @ObservedObject private var helper = TranscriberHelper.shared
    @State private var showAddress = false

    var body: some View {
        GroupBox(label: Label("Church Account", systemImage: "person.crop.circle")) {
            VStack(alignment: .leading, spacing: 12) {
                if account.isConnected { signedIn } else { signedOut }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal)
        .background(Color.canopyPaper)
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in once with your church's website. It covers everything below, in Canopy and in Transcriber.")
                .font(.canopyBody).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                bullet("Inventory and patch sheets")
                bullet("Workflows kept in sync across your computers")
                bullet("Run progress on the website")
                bullet("Notification email")
                if helper.isBundled { bullet("Transcriber's campus") }
            }
            AccountSignInButton()
            DisclosureGroup("Site address", isExpanded: $showAddress) {
                TextField("https://", text: $account.baseURL).textFieldStyle(.roundedBorder)
                Text("Only change this if your church uses its own domain.").font(.canopyCaption).foregroundStyle(.secondary)
            }
            .font(.canopyCaption)
        }
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(account.email ?? "Signed in", systemImage: "checkmark.circle.fill")
                    .font(.canopyBody).foregroundStyle(Color.canopySage)
                Spacer()
                if let origin = account.origin {
                    Link("Open website", destination: origin).font(.canopyCaption)
                }
                Button("Sign out", role: .destructive) { account.signOut() }.controlSize(.small)
            }

            Divider()

            row("Workflows", icon: "arrow.triangle.2.circlepath",
                detail: sync.isEnabled ? SyncStatus.text(sync) : "Sync is off",
                ok: sync.isEnabled && sync.lastError == nil) {
                Toggle("Sync", isOn: $sync.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            row("Run progress", icon: "globe",
                detail: publisher.isEnabled ? "Shared on the website" : "Not shared",
                ok: publisher.isEnabled) {
                Toggle("Share", isOn: $publisher.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            row("Remote runs", icon: "desktopcomputer",
                detail: remote.acceptsRemote ? "Your other computers can run workflows here" : "Other computers can't run workflows here",
                ok: remote.acceptsRemote) {
                Toggle("Allow", isOn: $remote.acceptsRemote).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            row("Email", icon: "envelope", detail: "Sends from \(NotificationMailer.fromAddress)", ok: true)

            if helper.isBundled {
                row("Transcriber", icon: "captions.bubble",
                    detail: helper.knownCampus.isEmpty ? "No campus chosen yet" : "Sending to \(helper.knownCampus)",
                    ok: !helper.knownCampus.isEmpty) {
                    if helper.isChoosingCampus {
                        Button("Cancel") { helper.cancelChoosingCampus() }.controlSize(.small)
                    } else {
                        Button(helper.knownCampus.isEmpty ? "Choose Campus…" : "Change…") {
                            if let origin = account.origin { helper.chooseCampus(site: origin) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").font(.canopyCaption).foregroundStyle(.secondary)
    }

    private func row(_ title: String, icon: String, detail: String, ok: Bool,
                     @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(ok ? Color.canopySage : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.canopySubheadline)
                Text(detail).font(.canopyCaption).foregroundStyle(.secondary)
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

/// Shown at the bottom of the sidebar so who's signed in, and whether workflows
/// are synced, is visible from every page.
struct AccountChip: View {
    @ObservedObject private var account = SiteAccount.shared
    @ObservedObject private var sync = WorkflowSyncService.shared
    var openSettings: (() -> Void)?

    var body: some View {
        if account.isConnected {
            Menu {
                if let email = account.email { Text("Signed in as \(email)") }
                Text(sync.isEnabled ? "Workflows: \(SyncStatus.text(sync))" : "Workflow sync is off")
                Divider()
                Button("Sync workflows now") { sync.requestSync() }.disabled(!sync.isEnabled)
                if let openSettings { Button("Account settings…", action: openSettings) }
                if let origin = account.origin { Link("Open website", destination: origin) }
                Divider()
                Button("Sign out", role: .destructive) { account.signOut() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(Color.canopySage)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.email ?? "Signed in").font(.canopyCaption).lineLimit(1).truncationMode(.middle)
                        Text(sync.isEnabled ? SyncStatus.text(sync) : "Sync off")
                            .font(.canopyCaption2)
                            .foregroundStyle(sync.lastError == nil ? Color.secondary : Color.canopyRust)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            Button { account.signIn() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.key")
                    Text(account.isConnecting ? "Waiting for the browser…" : "Sign in").font(.canopyCaption)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(account.isConnecting)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .help("Sign in once for synced workflows, email and Transcriber")
        }
    }
}
