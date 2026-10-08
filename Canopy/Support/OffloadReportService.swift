import Foundation
import AVFoundation
import AppKit

/// Builds a shareable shoot-day summary of a finished workflow run: what was
/// offloaded, how much, whether each file's checksum was verified, and what
/// went wrong. Output is a single self-contained HTML file (thumbnails
/// embedded), which opens anywhere and prints cleanly to PDF.
enum OffloadReportBuilder {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `thumbnails` maps `RunFileRecord.id` to a base64 JPEG.
    static func html(for run: WorkflowRun, thumbnails: [UUID: String] = [:]) -> String {
        let records = run.fileRecords ?? []
        let ok = records.filter(\.succeeded)
        let failed = records.filter { !$0.succeeded }
        let verified = records.filter { $0.verification == "verified" }
        let mismatched = records.filter { $0.verification == "mismatch" }
        let totalBytes = ok.reduce(Int64(0)) { $0 + $1.sizeBytes }

        let date = run.startedAt.formatted(date: .complete, time: .shortened)
        var h = """
        <!doctype html><html><head><meta charset="utf-8">
        <title>Offload Report — \(escape(run.workflowName))</title>
        <style>
        body{font:14px -apple-system,Helvetica,sans-serif;color:#2b2a26;background:#faf7f0;margin:0;padding:40px;}
        h1{font:600 28px 'New York',Georgia,serif;margin:0 0 4px} .sub{color:#7a766b;margin-bottom:28px}
        .stats{display:flex;gap:14px;margin-bottom:28px;flex-wrap:wrap}
        .stat{background:#fff;border:1px solid #e4dfd2;border-radius:12px;padding:14px 18px;min-width:120px}
        .stat b{display:block;font:600 24px 'New York',Georgia,serif}
        .stat span{color:#7a766b;font-size:12px}
        table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e4dfd2;border-radius:12px;overflow:hidden}
        th,td{text-align:left;padding:8px 12px;border-bottom:1px solid #eee9dc;vertical-align:middle}
        th{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:#7a766b;background:#f3efe4}
        img{width:96px;height:54px;object-fit:cover;border-radius:6px;display:block}
        .ph{width:96px;height:54px;border-radius:6px;background:#eee9dc}
        .ok{color:#4f7a5a;font-weight:600} .bad{color:#b4553a;font-weight:600} .mute{color:#7a766b}
        code{font:11px ui-monospace,Menlo,monospace;color:#7a766b}
        h2{font:600 18px 'New York',Georgia,serif;margin:28px 0 10px}
        @media print{body{background:#fff;padding:0}}
        </style></head><body>
        <h1>\(escape(run.workflowName))</h1>
        <div class="sub">\(escape(date)) · \(escape(run.durationFormatted)) · \(escape(run.decksProcessed.joined(separator: ", ")))</div>
        <div class="stats">
          <div class="stat"><b>\(ok.count)</b><span>clips offloaded</span></div>
          <div class="stat"><b>\(escape(formatBytes(totalBytes)))</b><span>total</span></div>
          <div class="stat"><b>\(verified.count)/\(records.count)</b><span>checksum verified</span></div>
          <div class="stat"><b class="\(failed.isEmpty && mismatched.isEmpty ? "ok" : "bad")">\(failed.count)</b><span>problems</span></div>
        </div>
        """

        if records.isEmpty {
            h += "<p class=\"mute\">No per-file details were recorded for this run.</p>"
        } else {
            h += "<table><tr><th></th><th>Clip</th><th>Device</th><th>Size</th><th>Status</th><th>SHA-256</th></tr>"
            for r in records {
                let thumb = thumbnails[r.id].map { "<img src=\"data:image/jpeg;base64,\($0)\">" } ?? "<div class=\"ph\"></div>"
                let status: String
                switch (r.succeeded, r.verification) {
                case (true, "verified"): status = "<span class=\"ok\">Verified</span>"
                case (true, _):          status = "<span class=\"mute\">Copied (not verified)</span>"
                default:
                    status = "<span class=\"bad\">\(escape(r.errorMessage ?? "Failed"))</span>"
                }
                let hash = r.sha256.map { "<code>\(escape(String($0.prefix(16))))…</code>" } ?? "<span class=\"mute\">—</span>"
                h += "<tr><td>\(thumb)</td><td>\(escape(r.fileName))</td><td>\(escape(r.deviceName))</td><td>\(escape(r.sizeBytes > 0 ? formatBytes(r.sizeBytes) : "—"))</td><td>\(status)</td><td>\(hash)</td></tr>"
            }
            h += "</table>"
        }

        if run.errors > 0 {
            h += "<h2>Run notes</h2><p class=\"bad\">\(run.errors) error\(run.errors == 1 ? "" : "s") were logged during this run.</p>"
        }
        h += "<p class=\"mute\" style=\"margin-top:32px\">Generated by Canopy · \(escape(Date().formatted(date: .abbreviated, time: .shortened)))</p></body></html>"
        return h
    }
}

enum OffloadReportService {
    /// Poster frames for each record whose file still exists (the original,
    /// or its converted .mp4 when the original was removed after conversion).
    static func thumbnails(for run: WorkflowRun) async -> [UUID: String] {
        var result: [UUID: String] = [:]
        for record in run.fileRecords ?? [] {
            let folder = URL(fileURLWithPath: record.folderPath)
            let base = (record.fileName as NSString).deletingPathExtension
            let candidates = [
                folder.appendingPathComponent(record.fileName),
                folder.appendingPathComponent(base + ".mp4"),
                folder.appendingPathComponent("Converted").appendingPathComponent(base + ".mp4")
            ]
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            if let jpeg = await posterJPEG(for: url) { result[record.id] = jpeg.base64EncodedString() }
        }
        return result
    }

    private static func posterJPEG(for url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 288, height: 162)
        guard let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
