import Foundation
import AVFoundation
import Combine

/// Drives the batch "export queue": clips selected from a device's file
/// browser (whole files) or queued from the video player with a trim range
/// set, all exported together to one destination folder instead of one at a
/// time through a save panel per clip.
@MainActor
final class ExportQueueManager: ObservableObject {
    static let shared = ExportQueueManager()

    @Published private(set) var items: [ExportQueueItem] = []
    @Published private(set) var isRunning = false

    private var isCancelled = false
    private let maxParallelJobs = 3

    var pendingCount: Int { items.filter { $0.phase == .queued }.count }
    var activeCount: Int { items.filter { $0.phase == .queued || $0.phase == .downloading || $0.phase == .exporting }.count }

    // MARK: - Queue management

    /// Adds a single clip. Whole-file adds (`trimRange == nil`) are
    /// deduplicated against an existing not-yet-finished whole-file entry
    /// for the same source, so re-selecting a file already in the queue is
    /// a no-op rather than a second copy of it.
    func add(node: FileNode, device: DeviceSource, trimRange: CMTimeRange? = nil) {
        if trimRange == nil {
            let alreadyQueued = items.contains {
                $0.node.id == node.id && $0.device.id == device.id && $0.trimRange == nil
                    && $0.phase != .done && $0.phase != .error
            }
            guard !alreadyQueued else { return }
        }
        items.append(ExportQueueItem(node: node, device: device, trimRange: trimRange))
    }

    func addMultiple(_ nodes: [FileNode], device: DeviceSource) {
        for node in nodes where node.isVideo {
            add(node: node, device: device)
        }
    }

    func remove(id: ExportQueueItem.ID) {
        items.removeAll { $0.id == id && $0.phase != .downloading && $0.phase != .exporting }
    }

    func clearCompleted() {
        items.removeAll { $0.phase == .done || $0.phase == .error }
    }

    func clearAll() {
        guard !isRunning else { return }
        items.removeAll()
    }

    // MARK: - Run

    /// Exports every queued item to `destination`, `maxParallelJobs` at a
    /// time. Items already `.done` or `.error` from a previous run are left
    /// untouched, so a retry after fixing an error only reprocesses what's
    /// still `.queued`.
    func start(destination: URL) async {
        guard !isRunning else { return }
        let pendingIDs = items.filter { $0.phase == .queued }.map(\.id)
        guard !pendingIDs.isEmpty else { return }

        isRunning = true
        isCancelled = false

        let batches = stride(from: 0, to: pendingIDs.count, by: maxParallelJobs).map {
            Array(pendingIDs[$0 ..< min($0 + maxParallelJobs, pendingIDs.count)])
        }

        for batch in batches {
            guard !isCancelled else { break }
            await withTaskGroup(of: Void.self) { group in
                for id in batch {
                    group.addTask { await self.export(itemID: id, destination: destination) }
                }
                for await _ in group {}
            }
        }

        isRunning = false
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: - Per-item export

    private func export(itemID: ExportQueueItem.ID, destination: URL) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !isCancelled else { return }

        let item = items[index]
        let node = item.node

        var localURL: URL?
        var downloadedTempURL: URL?

        switch item.device {
        case .cloudStore, .localFolder:
            localURL = node.url

        case .hyperDeck(let deck):
            guard let fileName = node.ftpPath else { break }
            items[index].phase = .downloading
            items[index].progress = 0

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CanopyExportQueue", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appendingPathComponent("\(deck.id.uuidString)-\(fileName)")
            try? FileManager.default.removeItem(at: tempURL)

            let result = await FTPService.downloadFile(named: fileName, from: deck, to: tempURL) { [weak self] pct in
                Task { @MainActor in
                    guard let self, let i = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                    self.items[i].progress = pct
                }
            }

            guard result.success else {
                markError(itemID: itemID, message: result.failureReason ?? "Download failed")
                return
            }
            localURL = tempURL
            downloadedTempURL = tempURL
        }

        guard !isCancelled else { return }
        guard let source = localURL else {
            markError(itemID: itemID, message: "Couldn't locate this file")
            return
        }

        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[i].phase = .exporting
        items[i].progress = 0

        let base = (node.name as NSString).deletingPathExtension
        let ext = (node.name as NSString).pathExtension.isEmpty ? "mov" : (node.name as NSString).pathExtension
        let suggestedName = item.isTrimmed ? "\(base)_clip.\(ext)" : "\(base).\(ext)"
        let outputURL = Self.uniqueURL(for: suggestedName, in: destination)

        let ok = await ConversionService.exportClip(
            input: source, output: outputURL, timeRange: item.trimRange
        ) { [weak self] pct in
            Task { @MainActor in
                guard let self, let i = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                self.items[i].progress = pct
            }
        }

        if let downloadedTempURL {
            try? FileManager.default.removeItem(at: downloadedTempURL)
        }

        if ok {
            if let i = items.firstIndex(where: { $0.id == itemID }) {
                items[i].phase = .done
                items[i].progress = 1
            }
        } else {
            markError(itemID: itemID, message: "Export failed")
        }
    }

    private func markError(itemID: ExportQueueItem.ID, message: String) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[i].phase = .error
        items[i].errorMessage = message
    }

    /// Appends " 2", " 3", … before the extension until the name is free in
    /// `directory`, so exporting the same file twice (or two files that
    /// happen to share a name across devices) doesn't silently overwrite.
    private static func uniqueURL(for fileName: String, in directory: URL) -> URL {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
