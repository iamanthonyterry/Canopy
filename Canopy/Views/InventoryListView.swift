import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Full inventory list
// Every device in one sortable table with what it cost and what it's worth,
// totals at the bottom, and a CSV export for insurance or budgeting.

struct InventoryListView: View {
    @ObservedObject private var store = InventoryStore.shared
    @EnvironmentObject private var nav: InventoryNavigator
    @State private var query = ""
    @State private var statusFilter: EquipmentStatus?
    @State private var sortOrder = [KeyPathComparator(\Row.name)]
    @State private var selection = Set<String>()
    @State private var result: (ok: Bool, message: String)?

    nonisolated struct Row: Identifiable, Sendable {
        var id: String
        var name: String
        var type: String
        var model: String
        var place: String
        var serial: String
        var status: String
        var purchased: String
        var paid: Double
        var value: Double
        var warranty: String
        var hasPaid: Bool
        var hasValue: Bool
    }

    private func row(_ e: Equipment) -> Row {
        Row(id: e.id, name: e.name, type: e.role?.label ?? e.category, model: e.makeModel == e.name ? "" : e.makeModel,
            place: store.place(e), serial: e.serial, status: e.status.label,
            purchased: e.purchaseDate ?? e.yearPurchased.map(String.init) ?? "",
            paid: e.purchasePrice ?? -1, value: e.value ?? -1,
            warranty: e.warrantyExpires ?? "", hasPaid: e.purchasePrice != nil, hasValue: e.value != nil)
    }

    private var shown: [Equipment] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.scoped.filter { e in
            if let statusFilter, e.status != statusFilter { return false }
            guard !q.isEmpty else { return true }
            return [e.name, e.makeModel, e.serial, e.category, e.role?.label ?? "", store.place(e), e.vendor, e.notes]
                .contains { $0.lowercased().contains(q) }
        }
    }

    private var rows: [Row] { shown.map(row).sorted(using: sortOrder) }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search name, model, serial, room…", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("Status", selection: $statusFilter) {
                    Text("Any status").tag(EquipmentStatus?.none)
                    ForEach(EquipmentStatus.allCases) { Text($0.label).tag(EquipmentStatus?.some($0)) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                ResultLine(result: result)
                Button { export(shown) } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.canopySecondary)
            }
            .font(.canopyCaption)
            .padding(10)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { r in Text(r.name).fontWeight(.medium) }.width(min: 140, ideal: 200)
                TableColumn("Type", value: \.type) { r in Text(r.type) }.width(min: 90, ideal: 130)
                TableColumn("Make & model", value: \.model) { r in Text(r.model) }.width(min: 110, ideal: 170)
                TableColumn("Where", value: \.place) { r in Text(r.place) }.width(min: 90, ideal: 140)
                TableColumn("Serial", value: \.serial) { r in Text(r.serial).textSelection(.enabled) }.width(min: 80, ideal: 110)
                TableColumn("Status", value: \.status) { r in Text(r.status) }.width(min: 70, ideal: 90)
                TableColumn("Purchased", value: \.purchased) { r in Text(r.purchased.isEmpty ? "—" : InventoryRules.formatDate(r.purchased.count == 4 ? "\(r.purchased)-01-01" : r.purchased)) }
                    .width(min: 80, ideal: 100)
                TableColumn("Paid", value: \.paid) { r in Text(r.hasPaid ? InventoryRules.money(r.paid) : "—").monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("Value", value: \.value) { r in Text(r.hasValue ? InventoryRules.money(r.value) : "—").monospacedDigit().fontWeight(.medium) }
                    .width(min: 70, ideal: 90)
                TableColumn("Warranty", value: \.warranty) { r in
                    let state = InventoryRules.warrantyState(r.warranty.isEmpty ? nil : r.warranty)
                    Text(r.warranty.isEmpty ? "—" : InventoryRules.formatDate(r.warranty))
                        .foregroundStyle(state == .soon ? .orange : state == .expired ? .secondary : Color.canopyInk)
                }
                .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { nav.open(id) }
            }
            Rectangle().fill(Color.canopyRule).frame(height: 1)
            HStack(spacing: 16) {
                Text("\(rows.count) \(rows.count == 1 ? "device" : "devices")")
                if rows.count != store.scoped.count { Text("of \(store.scoped.count)").foregroundStyle(.secondary) }
                Spacer()
                let missing = shown.filter { $0.value == nil }.count
                if missing > 0 { Text("\(missing) without a value").foregroundStyle(.secondary) }
                Text("Paid \(InventoryRules.money(shown.compactMap(\.purchasePrice).reduce(0, +)))")
                Text("Worth \(InventoryRules.money(shown.compactMap(\.value).reduce(0, +)))").fontWeight(.semibold)
            }
            .font(.canopyCallout).monospacedDigit()
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func export(_ list: [Equipment]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Inventory - \(store.scopeName).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = ["Name", "Type", "Category", "Make & model", "Serial", "Campus", "Where", "Status", "Condition", "Purchased", "Vendor", "Paid", "Value", "Warranty until", "Warranty terms"]
        let lines = list.sorted { InventoryRules.ordered($0.name, $1.name) }.map { e in
            [e.name, e.role?.label ?? "", e.category, e.makeModel, e.serial, store.campusName(e.campus), store.place(e), e.status.label, e.condition?.label ?? "",
             e.purchaseDate ?? e.yearPurchased.map(String.init) ?? "", e.vendor, e.purchasePrice.map { String($0) } ?? "", e.value.map { String($0) } ?? "",
             e.warrantyExpires ?? "", e.warrantyTerms].map(cell).joined(separator: ",")
        }
        do {
            try ([header.map(cell).joined(separator: ",")] + lines).joined(separator: "\r\n").appending("\r\n").write(to: url, atomically: true, encoding: .utf8)
            result = (true, "Saved \(url.lastPathComponent).")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
