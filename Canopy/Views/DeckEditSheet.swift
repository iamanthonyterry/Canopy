import SwiftUI
import Network

struct DeckEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingDeck: HyperDeck?

    @State private var name            = ""
    @State private var ipAddress       = ""
    @State private var remotePath      = ""
    @State private var username        = ""
    @State private var password        = ""
    @State private var capacityText    = ""
    @State private var showPathPicker  = false
    @State private var pingStatus: DeckStatus = .unknown
    @State private var isTesting       = false
    @State private var isCheckingBrowseAvailability = false
    @State private var browseAvailable = false
    @State private var showingRemoveConfirmation = false

    init(deck: HyperDeck?) {
        existingDeck = deck
        _name           = State(initialValue: deck?.name           ?? "")
        _ipAddress      = State(initialValue: deck?.ipAddress      ?? "")
        _remotePath     = State(initialValue: deck?.remotePath     ?? "")
        _username       = State(initialValue: deck?.username       ?? "")
        _password       = State(initialValue: deck?.password       ?? "")
        _capacityText   = State(initialValue: deck?.capacityGB.map { String(format: "%g", $0) } ?? "")
    }

    var canSave: Bool { !name.isEmpty && !ipAddress.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            HStack {
                Text(existingDeck == nil ? "Add HyperDeck" : "Edit HyperDeck")
                    .font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingDeck == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.canopyPrimary).disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            Form {
                // MARK: Device Info
                Section("Device Info") {
                    LabeledContent("Name") {
                        TextField("e.g. ISO 1", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Address") {
                        TextField("192.168.x.x or hostname.local", text: $ipAddress).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Remote Path") {
                        HStack(spacing: 8) {
                            TextField("usb/DriveName", text: $remotePath)
                                .textFieldStyle(.roundedBorder)
                            if isCheckingBrowseAvailability {
                                ProgressView().controlSize(.small)
                            } else if browseAvailable {
                                Button {
                                    showPathPicker = true
                                } label: {
                                    Label("Browse…", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    if !browseAvailable && !isCheckingBrowseAvailability && !ipAddress.isEmpty {
                        Text("Enter the correct IP, username, and password to browse folders.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Media Capacity") {
                        HStack(spacing: 6) {
                            TextField("e.g. 500", text: $capacityText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("GB")
                        }
                    }
                    Text("The deck can't report its disk size over the network, so enter it here to show a used/total storage indicator in its file browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: Credentials
                Section("Credentials") {
                    LabeledContent("Username") {
                        TextField("Username", text: $username).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Password") {
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    }
                }

                // MARK: Test Connection
                Section {
                    HStack {
                        Button(action: testConnection) {
                            if isTesting {
                                ProgressView().controlSize(.small)
                                Text("Testing...")
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }.disabled(ipAddress.isEmpty || isTesting)
                        Spacer()
                        if pingStatus != .unknown {
                            testResultLabel
                        }
                    }
                }

                // MARK: Remove
                if existingDeck != nil {
                    Section {
                        Button(role: .destructive) {
                            showingRemoveConfirmation = true
                        } label: {
                            Label("Remove Device", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480)
        .background(Color.canopyPaper)
        .task(id: BrowseProbeKey(ip: ipAddress, user: username, pass: password)) {
            await refreshBrowseAvailability()
        }
        .sheet(isPresented: $showPathPicker) {
            DeckPathPickerSheet(ipAddress: ipAddress, username: username, password: password) { path in
                remotePath = path
            }
        }
        .confirmationDialog(
            "Remove \(existingDeck?.name ?? "this device")?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let id = existingDeck?.id {
                    appState.deleteDeck(id: id)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the device from Canopy. It won't affect any files already on it.")
        }
    }

    // MARK: - Save
    private func save() {
        let capacity = Double(capacityText.trimmingCharacters(in: .whitespaces))
        if var d = existingDeck {
            d.name = name; d.ipAddress = ipAddress
            d.remotePath = remotePath; d.username = username; d.password = password
            d.capacityGB = capacity
            appState.updateDeck(d)
        } else {
            appState.addDeck(HyperDeck(
                name: name, ipAddress: ipAddress, remotePath: remotePath,
                username: username, password: password,
                capacityGB: capacity
            ))
        }
        dismiss()
    }

    // MARK: - Test
    @ViewBuilder
    private var testResultLabel: some View {
        let (text, systemImage, color): (String, String, Color) = switch pingStatus {
        case .online:       ("Connected & logged in", "checkmark.circle.fill", .canopySage)
        case .unauthorized: ("Reachable — login failed", "exclamationmark.triangle.fill", .orange)
        default:            ("No Response", "xmark.circle.fill", .canopyRust)
        }
        Label(text, systemImage: systemImage)
            .foregroundStyle(color)
            .font(.subheadline)
    }

    private func testConnection() {
        isTesting = true; pingStatus = .unknown
        Task {
            guard let port = NWEndpoint.Port(rawValue: UInt16(21)) else {
                isTesting = false; return
            }
            let conn = NWConnection(host: NWEndpoint.Host(ipAddress), port: port, using: .tcp)
            conn.start(queue: .global())
            let reachable = await resolveConnectionStatus(conn)

            guard reachable == .online else {
                pingStatus = .offline
                isTesting = false
                return
            }

            // Reachable — now confirm the username/password can actually log in.
            let deck = HyperDeck(name: name, ipAddress: ipAddress, remotePath: remotePath,
                                  username: username, password: password)
            if case .unauthorized = await FTPService.probeAuth(on: deck) {
                pingStatus = .unauthorized
            } else {
                pingStatus = .online
            }
            isTesting = false
        }
    }

    // MARK: - Browse availability

    /// Debounces on IP/username/password so we're not hammering the deck
    /// with an FTP probe on every keystroke.
    private struct BrowseProbeKey: Equatable {
        let ip: String, user: String, pass: String
    }

    /// Only let the user browse remote folders once we've confirmed the
    /// login works *and* the deck actually has folders to show.
    private func refreshBrowseAvailability() async {
        guard !ipAddress.isEmpty else {
            browseAvailable = false
            return
        }
        isCheckingBrowseAvailability = true
        defer { isCheckingBrowseAvailability = false }

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        let probeDeck = HyperDeck(name: "", ipAddress: ipAddress, remotePath: "",
                                   username: username, password: password)
        guard case .authorized = await FTPService.probeAuth(on: probeDeck) else {
            browseAvailable = false
            return
        }
        guard !Task.isCancelled else { return }

        let entries = await FTPService.listAllFiles(on: probeDeck, path: "")
        browseAvailable = entries.contains { $0.isDirectory }
    }
}
