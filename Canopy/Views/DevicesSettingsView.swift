import SwiftUI

/// The devices workflows run on: HyperDecks, network storage (Cloud Stores and NAS units) and local folders.
/// Add them by hand or scan the network. Each row has a gear for its settings; right-click for more.
struct DevicesSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var discovery = DeviceDiscovery()
    @ObservedObject private var monitor = ConnectionMonitor.shared

    @State private var showingAddDeck = false
    @State private var showingAddCloudStore = false
    @State private var addCloudStoreKind: CloudStore.Kind = .blackmagicCloudStore
    @State private var showingAddLocalFolder = false

    private var total: Int { appState.hyperDecks.count + appState.cloudStores.count + appState.localFolders.count }

    private var newDecks: [HyperDeck] {
        discovery.discoveredDecks.filter { d in !appState.hyperDecks.contains { $0.ipAddress == d.ipAddress } }
    }
    private var newStores: [CloudStore] {
        discovery.discoveredCloudStores.filter { s in !appState.cloudStores.contains { $0.ipAddress == s.ipAddress } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            if total == 0 && newDecks.isEmpty && newStores.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
        .background(Color.canopyPaper)
        .sheet(isPresented: $showingAddDeck) { DeckEditSheet(deck: nil) }
        .sheet(isPresented: $showingAddCloudStore) { CloudStoreEditSheet(store: nil, defaultKind: addCloudStoreKind) }
        .sheet(isPresented: $showingAddLocalFolder) { LocalFolderEditSheet(folder: nil) }
        .onAppear { monitor.start() }
        .onDisappear { discovery.stopScanning() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Devices").font(.canopyTitle).foregroundStyle(Color.canopyInk)
                Text("\(appState.hyperDecks.count) decks · \(appState.cloudStores.count) network storage · \(appState.localFolders.count) local folders")
                    .font(.canopySubheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if discovery.isScanning { discovery.stopScanning() } else { discovery.startScanning() }
            } label: {
                if discovery.isScanning {
                    Label("Scanning…", systemImage: "antenna.radiowaves.left.and.right").symbolEffect(.pulse)
                } else {
                    Label("Scan Network", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            .buttonStyle(.canopySecondary)
            Menu {
                Button("HyperDeck") { showingAddDeck = true }
                Button("Cloud Store") { addCloudStoreKind = .blackmagicCloudStore; showingAddCloudStore = true }
                Button("Synology NAS") { addCloudStoreKind = .synologyNAS; showingAddCloudStore = true }
                Button("Local Folder") { showingAddLocalFolder = true }
            } label: {
                Label("Add Device", systemImage: "plus")
            }
            .buttonStyle(.canopyPrimary)
        }
        .padding()
    }

    private var deviceList: some View {
        List {
            if !appState.hyperDecks.isEmpty {
                Section("HyperDecks") {
                    ForEach(appState.hyperDecks) { DeckListRow(deck: $0) }
                }
            }
            if !appState.cloudStores.isEmpty {
                Section("Network Storage") {
                    ForEach(appState.cloudStores) { CloudStoreListRow(store: $0) }
                }
            }
            if !appState.localFolders.isEmpty {
                Section("Local Folders") {
                    ForEach(appState.localFolders) { LocalFolderListRow(folder: $0) }
                }
            }
            if !newDecks.isEmpty || !newStores.isEmpty {
                Section("Discovered on Network") {
                    ForEach(newDecks) { deck in
                        DiscoveredDeviceRow(name: deck.name, ip: deck.ipAddress, icon: "server.rack") { appState.addDeck(deck) }
                    }
                    ForEach(newStores) { store in
                        DiscoveredDeviceRow(name: store.name, ip: store.ipAddress, icon: store.kind.icon) { appState.addCloudStore(store) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No devices yet").font(.canopyHeadline)
            Text("Add the HyperDecks, network storage and folders your workflows run on, or scan the network to find them.")
                .font(.canopySubheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack {
                Button("Scan Network") { discovery.startScanning() }.buttonStyle(.canopyPrimary)
                Button("Add Local Folder") { showingAddLocalFolder = true }.buttonStyle(.canopySecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
