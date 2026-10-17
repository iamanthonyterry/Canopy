import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Document import
// Reads a device list, network sheet or patch list with Canopy's on-device
// model, then lets the person go through what it found before anything is
// saved: leave rows out, say which inventory device each one already is (a
// match is suggested, with why), fix names and rooms. Saving fills in blanks
// on matched devices, adds the rest, makes missing rooms, and patches the cables.

struct DocumentImportView: View {
    /// Called with the file's text when it turns out to be a spreadsheet already in the patch-sheet layout.
    var useSheet: (String) -> Void

    @ObservedObject private var store = InventoryStore.shared
    @ObservedObject private var ai = AIModels.shared
    @State private var fileURL: URL?
    @State private var about = ""
    @State private var campus = ""
    @State private var picking = false
    @State private var task: Task<Void, Never>?
    @State private var progress: (done: Int, total: Int)?
    @State private var error: String?
    @State private var sheetText: String?
    @State private var reading: DocumentReading?
    @State private var decisions: [DeviceDecision] = []
    @State private var matches: [String: DeviceMatch] = [:]
    @State private var leftOut: Set<String> = []
    @State private var query = ""
    @State private var showCables = false
    @State private var saving = false
    @State private var result: (ok: Bool, message: String)?

    private var campusDevices: [Equipment] { store.equipment.filter { $0.campus == campus } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if reading == nil { picker } else { review }
                if progress != nil { PatchingAnimation() }
                ResultLine(result: result)
            }
            .padding()
        }
        .onAppear {
            if campus.isEmpty {
                let real = store.scope == InventoryRules.unassigned ? "" : store.scope
                campus = real.isEmpty ? store.campuses.first?.id ?? "" : real
            }
        }
        .onDisappear { task?.cancel() }
        .fileImporter(isPresented: $picking, allowedContentTypes: DocumentReader.readableTypes.compactMap { UTType(filenameExtension: $0) } + [.item]) { picked in
            if case .success(let url) = picked { fileURL = url; error = nil; sheetText = nil; result = nil }
        }
    }

    // MARK: Choosing a document

    private var modelLine: String {
        if ai.isEnhancedActive { return "Reads on this Mac with the enhanced model (\(ai.choice.title)). Nothing is uploaded." }
        return "Reads on this Mac with Apple Intelligence. Nothing is uploaded. For long or messy documents, turn on the enhanced model in Settings."
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Read a document into the inventory").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Text("Network sheets, integrator device lists, input and patch lists: PDF (scans too), Word, Excel, CSV, text or a photo. You check everything it finds before anything is saved.")
                    .font(.canopyCallout).foregroundStyle(.secondary)
                Label(modelLine, systemImage: "lock.shield").font(.canopyCaption).foregroundStyle(.secondary)
                if let reason = ai.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.canopyCaption).foregroundStyle(Color.canopyRust)
                }
            }
            HStack {
                Button(fileURL == nil ? "Choose a document…" : "Choose another…") { picking = true }.buttonStyle(.canopySecondary)
                if let fileURL { Label(fileURL.lastPathComponent, systemImage: "doc.text").lineLimit(1) }
                Spacer()
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in fileURL = url; error = nil; sheetText = nil } }
                }
                return true
            }
            TextField("What is this document? (optional) e.g. \"Integrator's network sheet; ignore the spare switch rows\"", text: $about, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack {
                if store.campuses.count > 1 {
                    Picker("New equipment goes to", selection: $campus) { ForEach(store.campuses) { Text($0.name).tag($0.id) } }.frame(maxWidth: 320)
                }
                Spacer()
                if let progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 140)
                    Text(progress.total == 0 ? "Getting the text…" : "Reading part \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                        .font(.canopyCaption).foregroundStyle(.secondary).monospacedDigit()
                    Button("Cancel") { task?.cancel() }.buttonStyle(.canopySecondary)
                } else {
                    Button("Read document") { read() }.buttonStyle(.canopyPrimary).disabled(fileURL == nil || ai.unavailableReason != nil)
                }
            }
            if let sheetText {
                HStack {
                    Image(systemName: "tablecells").foregroundStyle(Color.canopySage)
                    Text("This spreadsheet is already in the patch-sheet layout, so it can be imported exactly, without the model.").font(.canopyCallout)
                    Spacer()
                    Button("Import it as a patch sheet") { useSheet(sheetText) }.buttonStyle(.canopySecondary)
                }
            }
            if let error { Text(error).font(.canopyCallout).foregroundStyle(Color.canopyRust) }
        }
        .canopyCard(padding: 14)
    }

    private func read() {
        guard let url = fileURL else { return }
        error = nil; result = nil; progress = (0, 0)
        let known = campusDevices.map(\.name)
        task = Task {
            defer { progress = nil; task = nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try await DocumentReader.text(of: url)
                if ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased()) {
                    let parsed = PatchImport.parse(text)
                    if !parsed.rows.isEmpty && parsed.problems.isEmpty { sheetText = text }
                }
                let r = try await DocumentReader.read(text: text, fileName: url.lastPathComponent, known: known, about: about) { done, total in
                    progress = (done, total)
                }
                guard !r.devices.isEmpty || !r.cables.isEmpty else {
                    error = "Nothing in that document looked like equipment or cables."
                    return
                }
                matches = DocumentImport.matchAll(r.devices, in: campusDevices)
                decisions = r.devices.map { DeviceDecision($0, target: matches[$0.key]?.id) }
                leftOut = []
                reading = r
            } catch is CancellationError {
                error = "Stopped."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Review

    private var kept: [DeviceDecision] { decisions.filter { !leftOut.contains($0.key) } }
    private var keptCables: [ImportRow] {
        let keys = Set(kept.map(\.key))
        return (reading?.cables ?? []).filter { keys.contains($0.fromDevice) && keys.contains($0.toDevice) }
    }

    private var review: some View {
        let r = reading!
        let matched = kept.filter { $0.target != nil }.count
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let shown = decisions.indices.filter { i in
            q.isEmpty || [decisions[i].name, decisions[i].makeModel, decisions[i].room, decisions[i].ipAddress].contains { $0.lowercased().contains(q) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(fileURL?.lastPathComponent ?? "Document").font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                    Spacer()
                    Button("Start over") { reading = nil; result = nil }.buttonStyle(.canopySecondary)
                }
                if !r.summary.isEmpty { Text(r.summary).font(.canopyCallout).foregroundStyle(.secondary) }
                ForEach(r.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.canopyCaption).foregroundStyle(.orange) }
                Text("Found \(r.devices.count) devices and \(r.cables.count) cables. Saving adds \(kept.count - matched) new, fills in blanks on \(matched) already in the inventory (nothing typed there is replaced), and patches \(keptCables.count) cables.")
                    .font(.canopyCallout)
            }
            .canopyCard(padding: 14)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Devices").font(.canopyHeadline)
                    TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    Spacer()
                    Button("Keep all") { leftOut = [] }.buttonStyle(.borderless)
                    Button("Leave all out") { leftOut = Set(decisions.map(\.key)) }.buttonStyle(.borderless)
                    Button("Leave out ones only named in cables") { leftOut.formUnion(r.devices.filter { $0.rows == 0 }.map(\.key)) }
                        .buttonStyle(.borderless).help("Devices the document only mentions as the end of a cable")
                }
                .font(.canopyCaption)
                ForEach(shown, id: \.self) { i in DecisionRow(decision: $decisions[i], match: matches[decisions[i].key], found: r.devices.first { $0.key == decisions[i].key },
                                                             candidates: campusDevices, takenBy: takenBy, leftOut: $leftOut) }
            }
            .canopyCard(padding: 14)

            VStack(alignment: .leading, spacing: 6) {
                DisclosureGroup("Cables · \(keptCables.count)", isExpanded: $showCables) {
                    let names = Dictionary(uniqueKeysWithValues: decisions.map { ($0.key, $0.name) })
                    ForEach(Array(keptCables.prefix(300).enumerated()), id: \.offset) { _, c in
                        HStack(spacing: 4) {
                            Text(names[c.fromDevice] ?? "").fontWeight(.medium)
                            Text([c.fromCard, c.fromChannel.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")).foregroundStyle(.secondary)
                            Text("→")
                            Text(names[c.toDevice] ?? "").fontWeight(.medium)
                            Text([c.toCard, c.toChannel.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")).foregroundStyle(.secondary)
                            Text(c.fromName).foregroundStyle(.secondary)
                        }
                        .font(.canopyCaption)
                    }
                    if keptCables.count > 300 { Text("…and \(keptCables.count - 300) more").font(.canopyCaption).foregroundStyle(.secondary) }
                }
                HStack {
                    Text("Want to fix the cables by hand? Save them as a spreadsheet, edit, and bring it back in as a patch sheet.").font(.canopyCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save cables as CSV…") { saveCSV() }.buttonStyle(.borderless).font(.canopyCaption)
                }
            }
            .canopyCard(padding: 14)

            HStack {
                if let clash = duplicateTarget {
                    Label("\(clash) is matched to two of the document's devices. Pick a different one for one of them.", systemImage: "exclamationmark.triangle")
                        .font(.canopyCaption).foregroundStyle(Color.canopyRust)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save to inventory") {
                    saving = true
                    Task {
                        result = await store.importDocument(kept, cables: keptCables, campus: campus)
                        saving = false
                        if result?.ok == true { reading = nil; fileURL = nil; about = "" }
                    }
                }
                .buttonStyle(.canopyPrimary)
                .disabled(saving || (kept.isEmpty && keptCables.isEmpty) || duplicateTarget != nil)
            }
        }
    }

    /// Which found device has claimed each inventory device, so the pickers can say so.
    private var takenBy: [String: String] {
        Dictionary(kept.compactMap { d in d.target.map { ($0, d.key) } }, uniquingKeysWith: { a, _ in a })
    }

    private var duplicateTarget: String? {
        let targets = kept.compactMap(\.target)
        let counts = Dictionary(targets.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.first { $0.value > 1 }.flatMap { store.byID[$0.key]?.name }
    }

    private func saveCSV() {
        let names = Dictionary(uniqueKeysWithValues: decisions.map { ($0.key, $0.target.flatMap { store.byID[$0]?.name } ?? $0.name) })
        let table = [PatchImport.headers] + keptCables.map { c in
            [names[c.fromDevice] ?? "", c.fromCard, c.fromChannel.map(String.init) ?? "", c.fromName, c.fromKind,
             names[c.toDevice] ?? "", c.toCard, c.toChannel.map(String.init) ?? "", c.toName, c.toKind, c.note]
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\((fileURL?.deletingPathExtension().lastPathComponent ?? "Document")) cables.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PatchImport.csv(table).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct DecisionRow: View {
    @Binding var decision: DeviceDecision
    let match: DeviceMatch?
    let found: FoundDevice?
    let candidates: [Equipment]
    let takenBy: [String: String]
    @Binding var leftOut: Set<String>
    @State private var open = false

    private var included: Bool { !leftOut.contains(decision.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { included }, set: { on in if on { leftOut.remove(decision.key) } else { leftOut.insert(decision.key) } }))
                    .labelsHidden().toggleStyle(.checkbox)
                Image(systemName: decision.role?.symbol ?? "shippingbox").foregroundStyle(.secondary).frame(width: 16)
                TextField("Name", text: $decision.name).textFieldStyle(.roundedBorder).frame(width: 220)
                Text([decision.makeModel, decision.room, decision.ipAddress].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.canopyCaption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Picker("", selection: $decision.target) {
                    Text("Add as new").tag(String?.none)
                    if let match, let hit = candidates.first(where: { $0.id == match.id }) {
                        Text("Same as \(hit.name) (\(match.why))").tag(String?.some(hit.id))
                        Divider()
                    }
                    ForEach(candidates.filter { $0.id != match?.id }) { e in
                        Text(takenBy[e.id].map { $0 != decision.key ? "\(e.name) (taken)" : e.name } ?? e.name).tag(String?.some(e.id))
                    }
                }
                .labelsHidden().frame(width: 260)
                Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }.buttonStyle(.borderless)
            }
            .opacity(included ? 1 : 0.45)
            if open {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        TextField("Make and model", text: $decision.makeModel).textFieldStyle(.roundedBorder)
                        Picker("Type", selection: $decision.role) {
                            Text("Not set").tag(DeviceRole?.none)
                            ForEach(DeviceRole.allCases) { Text($0.label).tag(DeviceRole?.some($0)) }
                        }
                        Picker("Category", selection: $decision.category) {
                            Text("Not set").tag("")
                            ForEach(InventoryCategories.all, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    GridRow {
                        TextField("Room", text: $decision.room).textFieldStyle(.roundedBorder)
                        TextField("Spot in the room", text: $decision.location).textFieldStyle(.roundedBorder)
                        TextField("IP address", text: $decision.ipAddress).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        TextField("MAC address", text: $decision.macAddress).textFieldStyle(.roundedBorder)
                        TextField("Serial", text: $decision.serial).textFieldStyle(.roundedBorder)
                        TextField("Username", text: $decision.username).textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $decision.password).textFieldStyle(.roundedBorder)
                    }
                }
                .font(.canopyCaption)
                TextField("Notes", text: $decision.notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5).font(.canopyCaption)
                if let found, found.rows == 0 { Text("Only named as the end of a cable in the document.").font(.canopyCaption2).foregroundStyle(.secondary) }
                if decision.target != nil { Text("Matched: only the blank fields of the inventory device are filled in.").font(.canopyCaption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
    }
}
