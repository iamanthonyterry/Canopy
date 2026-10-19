import SwiftUI

// MARK: - Workflows on your other computers
// Lists the person's other signed-in computers with the workflows each has, and
// lets them start one there (see RemoteComputersService). Hidden when signed
// out or when no other computer has signed in.

struct OtherComputersSection: View {
    @ObservedObject private var account = SiteAccount.shared
    @ObservedObject private var service = RemoteComputersService.shared
    @State private var expanded = true
    @State private var error: String?

    var body: some View {
        if account.isConnected && !service.computers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.canopyCaption)
                        Text("Other computers").font(.canopySubheadline).bold()
                        Text("\(service.computers.count)").font(.canopyCaption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(service.computers) { computer in
                        ComputerRow(computer: computer) { error = $0 }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.canopyRule).frame(height: 1)
        }
    }
}

private struct ComputerRow: View {
    let computer: RemoteComputer
    let onError: (String?) -> Void
    @ObservedObject private var service = RemoteComputersService.shared

    private var canRun: Bool { computer.isOnline && computer.acceptsRemote }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").foregroundStyle(computer.isOnline ? Color.canopySage : .secondary)
                Text(computer.name).font(.canopySubheadline).bold()
                Text(status).font(.canopyCaption).foregroundStyle(.secondary)
            }
            if computer.workflows.isEmpty {
                Text("No workflows yet").font(.canopyCaption).foregroundStyle(.secondary).padding(.leading, 28)
            }
            ForEach(computer.workflows) { w in
                HStack {
                    Text(w.name).font(.canopyBody)
                    Spacer()
                    Button { run(w) } label: { Label("Run there", systemImage: "play.fill") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!canRun)
                        .help(canRun ? "Start this on \(computer.name)" : status)
                }
                .padding(.leading, 28)
            }
            if let outcome = service.outcomes[computer.deviceId] {
                Text(outcome).font(.canopyCaption).foregroundStyle(.secondary).padding(.leading, 28)
            }
        }
    }

    private var status: String {
        if !computer.isOnline {
            if let seen = computer.seen { return "Last seen \(seen.formatted(.relative(presentation: .named)))" }
            return "Offline"
        }
        return computer.acceptsRemote ? "Online" : "Online · remote runs are off (turn on in its Settings → Church Account)"
    }

    private func run(_ w: RemoteComputer.Entry) {
        Task { onError(await service.request(w, on: computer)) }
    }
}
