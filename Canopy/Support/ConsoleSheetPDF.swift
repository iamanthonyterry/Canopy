import AppKit
import UniformTypeIdentifiers

// MARK: - Console patch sheet (PDF)
// A console's patch as a page you can print and tape to the desk: every input
// channel with its name, the socket it takes its signal from and what feeds
// that socket, then every mix and where it goes. One console starts on a new
// page; a long list carries its column headings onto each page.

nonisolated struct ConsoleSheet: Sendable {
    struct Section: Sendable {
        var title: String
        var columns: [String]
        var rows: [[String]]
        /// Each column's share of the page width.
        var widths: [Double] = [0.08, 0.24, 0.36, 0.32]
    }
    var title: String
    var subtitle: String
    var sections: [Section]
}

extension InventoryStore {
    /// The sheet for one console: inputs, then mixes. Unpatched channels stay on it, so the page is the whole desk.
    func consoleSheet(for console: Equipment) -> ConsoleSheet {
        func rows(_ kind: ChannelKind) -> [[String]] {
            channels(of: console, kind).map { c in
                let sockets = self.sockets(of: c)
                let source = sockets.map { $0.device.id == console.id ? $0.device.portName($0.port) : "\($0.device.name) · \($0.device.portName($0.port))" }
                let beyond = sockets.compactMap { kind == .input ? upstream(of: $0.port.id) : downstream(of: $0.port.id) }
                return ["\(c.number)", c.label.isEmpty ? "—" : c.label, source.isEmpty ? "—" : source.joined(separator: "; "), beyond.joined(separator: "; ")]
            }
        }
        let inputs = channels(of: console, .input), outputs = channels(of: console, .output)
        let patched = Set(consolePatch.map(\.channelId))
        var sections: [ConsoleSheet.Section] = []
        if !inputs.isEmpty { sections.append(.init(title: "Input channels · \(inputs.count)", columns: ["Ch", "Name", "Source", "Fed by"], rows: rows(.input))) }
        if !outputs.isEmpty { sections.append(.init(title: "Mixes and outputs · \(outputs.count)", columns: ["Mix", "Name", "Goes to", "Then"], rows: rows(.output))) }
        var bits = [place(console)].filter { !$0.isEmpty }
        if !inputs.isEmpty { bits.append("\(inputs.filter { patched.contains($0.id) }.count) of \(inputs.count) inputs patched") }
        return ConsoleSheet(title: console.name, subtitle: bits.joined(separator: " · "), sections: sections)
    }
}

enum ConsoleSheetPDF {
    private static let page = CGSize(width: 612, height: 792)
    private static let margin = (left: CGFloat(40), right: CGFloat(40), top: CGFloat(48), bottom: CGFloat(46))
    private static let rowHeight: CGFloat = 17

    /// PDF data for the sheets, each console starting on a fresh page.
    static func render(_ sheets: [ConsoleSheet], date: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: sheets.first?.title ?? "Patch sheet"] as CFDictionary) else { return Data() }
        var pageNumber = 0
        var y: CGFloat = 0
        var running = ""

        func begin() {
            if pageNumber > 0 { ctx.endPDFPage() }
            pageNumber += 1
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            text("\(running)", at: CGPoint(x: margin.left, y: page.height - 30), width: 400, size: 8, color: .gray)
            text("Page \(pageNumber)", at: CGPoint(x: page.width - margin.right - 60, y: page.height - 30), width: 60, size: 8, color: .gray, align: .right)
            text(date, at: CGPoint(x: page.width - margin.right - 200, y: page.height - 30), width: 130, size: 8, color: .gray, align: .right)
            y = margin.top
        }
        func heading(_ sheet: ConsoleSheet, continued: Bool) {
            text(sheet.title + (continued ? " (continued)" : ""), at: CGPoint(x: margin.left, y: y), width: page.width - margin.left - margin.right, size: continued ? 11 : 20, bold: true)
            y += continued ? 18 : 28
            if !continued {
                text(sheet.subtitle, at: CGPoint(x: margin.left, y: y), width: page.width - margin.left - margin.right, size: 9.5, color: .darkGray)
                y += 22
            }
        }
        func columnRow(_ cells: [String], widths: [Double], bold: Bool, shaded: Bool) {
            let total = page.width - margin.left - margin.right
            if shaded { NSColor(white: 0.94, alpha: 1).setFill(); CGRect(x: margin.left, y: y - 1, width: total, height: rowHeight).fill() }
            var x = margin.left
            for (cell, w) in zip(cells, widths) {
                let width = total * w
                text(cell, at: CGPoint(x: x + 4, y: y + 2), width: width - 8, size: 9, bold: bold)
                x += width
            }
            y += rowHeight
        }

        for sheet in sheets {
            running = sheet.title
            begin()
            heading(sheet, continued: false)
            for section in sheet.sections {
                if y + rowHeight * 5 > page.height - margin.bottom { begin(); heading(sheet, continued: true) }
                text(section.title, at: CGPoint(x: margin.left, y: y), width: 300, size: 12, bold: true)
                y += 20
                func header() {
                    columnRow(section.columns, widths: section.widths, bold: true, shaded: false)
                    NSColor.black.setStroke()
                    let rule = NSBezierPath(); rule.lineWidth = 0.75
                    rule.move(to: CGPoint(x: margin.left, y: y)); rule.line(to: CGPoint(x: page.width - margin.right, y: y)); rule.stroke()
                    y += 2
                }
                header()
                for (i, row) in section.rows.enumerated() {
                    if y + rowHeight > page.height - margin.bottom { begin(); heading(sheet, continued: true); header() }
                    columnRow(row, widths: section.widths, bold: false, shaded: i % 2 == 1)
                }
                y += 14
            }
        }
        if pageNumber > 0 { ctx.endPDFPage() }
        ctx.closePDF()
        return data as Data
    }

    private static func text(_ s: String, at p: CGPoint, width: CGFloat, size: CGFloat, bold: Bool = false, color: NSColor = .black, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = align
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        (s as NSString).draw(in: CGRect(x: p.x, y: p.y, width: width, height: size * 1.4),
                             withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// Asks where to save, writes the sheets, and opens the file so it can be printed.
    @MainActor static func save(_ sheets: [ConsoleSheet], suggestedName: String) {
        guard !sheets.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = render(sheets, date: Date().formatted(date: .abbreviated, time: .omitted))
        do { try data.write(to: url); NSWorkspace.shared.open(url) } catch { NSSound.beep() }
    }
}
