import SwiftUI

// MARK: - CloudStoreVolumePickerSheet
// Connects to an SMB server using the credentials currently entered in the
// edit form and lists its disk shares, so the user can pick a volume name
// instead of typing it. Calls onSelect with the chosen share name.

struct CloudStoreVolumePickerSheet: View {
    let ipAddress: String
    let username: String
    let password: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var shares: [String] = []
    @State private var isLoading = true
    @State private var highlighted: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 360)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.wifi")
                .foregroundStyle(.purple)
            Text("Choose Volume")
                .font(.title3).bold()
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack { Spacer(); ProgressView("Connecting to \(ipAddress)…"); Spacer() }
        } else if shares.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "externaldrive")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("No shares found")
                    .foregroundStyle(.secondary)
                Text("Check the IP address and credentials above.")
                    .font(.caption).foregroundStyle(.tertiary)
                Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
                Spacer()
            }
        } else {
            List(shares, id: \.self, selection: $highlighted) { share in
                Label(share, systemImage: "externaldrive.fill")
                    .tag(share)
                    .onTapGesture(count: 2) { select(share) }
                    .onTapGesture(count: 1) { highlighted = share }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Select") {
                if let share = highlighted { select(share) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(highlighted == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func select(_ share: String) {
        onSelect(share)
        dismiss()
    }

    private func load() async {
        isLoading = true
        shares = await SMBService.listShares(ip: ipAddress, username: username, password: password)
        isLoading = false
    }
}
