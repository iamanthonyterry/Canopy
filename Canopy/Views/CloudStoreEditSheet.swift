import SwiftUI
import Network

struct CloudStoreEditSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let existingStore: CloudStore?

    @State private var name       = ""
    @State private var ipAddress  = ""
    @State private var volumeName = ""
    @State private var username   = ""
    @State private var password   = ""
    @State private var pingStatus: DeckStatus = .unknown
    @State private var isTesting  = false
    @State private var mountResult: String? = nil
    @State private var showVolumePicker = false

    init(store: CloudStore?) {
        existingStore = store
        _name       = State(initialValue: store?.name       ?? "")
        _ipAddress  = State(initialValue: store?.ipAddress  ?? "")
        _volumeName = State(initialValue: store?.volumeName ?? "")
        _username   = State(initialValue: store?.username   ?? "")
        _password   = State(initialValue: store?.password   ?? "")
    }

    var canSave: Bool { !name.isEmpty && !ipAddress.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingStore == nil ? "Add Cloud Store" : "Edit Cloud Store")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingStore == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Section("Device Info") {
                    LabeledContent("Name") {
                        TextField("e.g. Cloud Store 1", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("IP Address") {
                        TextField("192.168.x.x", text: $ipAddress).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Volume Name") {
                        HStack(spacing: 8) {
                            TextField("e.g. CloudStore", text: $volumeName)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                showVolumePicker = true
                            } label: {
                                Label("Browse…", systemImage: "externaldrive")
                            }
                            .buttonStyle(.bordered)
                            .disabled(ipAddress.isEmpty)
                        }
                    }
                }
                Section("Credentials") {
                    LabeledContent("Username") {
                        TextField("Username", text: $username).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Password") {
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    }
                }
                Section {
                    HStack {
                        Button(action: testConnection) {
                            if isTesting {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            } else {
                                Label("Test & Mount", systemImage: "network")
                            }
                        }.disabled(ipAddress.isEmpty || isTesting)
                        Spacer()
                        if let result = mountResult {
                            Text(result)
                                .font(.subheadline)
                                .foregroundStyle(result.hasPrefix("✅") ? .green : .red)
                        } else if pingStatus != .unknown {
                            Label(
                                pingStatus == .online ? "Reachable" : "No Response",
                                systemImage: pingStatus == .online ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(pingStatus == .online ? .green : .red)
                            .font(.subheadline)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440)
        .sheet(isPresented: $showVolumePicker) {
            CloudStoreVolumePickerSheet(ipAddress: ipAddress, username: username, password: password) { share in
                volumeName = share
            }
        }
    }

    private func save() {
        if var s = existingStore {
            s.name = name; s.ipAddress = ipAddress
            s.volumeName = volumeName; s.username = username; s.password = password
            appState.updateCloudStore(s)
        } else {
            appState.addCloudStore(CloudStore(
                name: name, ipAddress: ipAddress,
                volumeName: volumeName, username: username, password: password
            ))
        }
        dismiss()
    }

    private func testConnection() {
        isTesting = true
        pingStatus = .unknown
        mountResult = nil

        Task {
            // 1. TCP reachability check on SMB port
            guard let port = NWEndpoint.Port(rawValue: UInt16(445)) else {
                isTesting = false; return
            }
            let conn = NWConnection(host: NWEndpoint.Host(ipAddress), port: port, using: .tcp)
            conn.start(queue: .global())
            pingStatus = await resolveConnectionStatus(conn)

            guard pingStatus == .online else {
                isTesting = false; return
            }

            // 2. Attempt SMB mount
            do {
                let mountPath = try await SMBService.mountAndResolve(
                    ip: ipAddress, volume: volumeName,
                    username: username, password: password
                )
                mountResult = "✅ Mounted at \(mountPath)"
            } catch {
                mountResult = "❌ \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}
