import Foundation
import AVFoundation

// MARK: - Export Queue Item
// One clip queued for batch export: either the whole file as-is, or a
// trimmed sub-range (set via the video player's in/out points before
// choosing "Add to Queue" instead of exporting immediately).
struct ExportQueueItem: Identifiable {
    enum Phase {
        case queued, downloading, exporting, done, error

        var label: String {
            switch self {
            case .queued:      return "Queued"
            case .downloading: return "Downloading"
            case .exporting:   return "Exporting"
            case .done:        return "Done"
            case .error:       return "Error"
            }
        }

        var icon: String {
            switch self {
            case .queued:      return "clock"
            case .downloading: return "arrow.down.circle.fill"
            case .exporting:   return "square.and.arrow.up.circle.fill"
            case .done:        return "checkmark.circle.fill"
            case .error:       return "xmark.circle.fill"
            }
        }
    }

    let id = UUID()
    let node: FileNode
    let device: DeviceSource
    /// nil = export the whole file; set = export just this sub-range.
    let trimRange: CMTimeRange?

    var phase: Phase = .queued
    var progress: Double = 0
    var errorMessage: String?

    var deviceName: String {
        switch device {
        case .hyperDeck(let d):   return d.name
        case .cloudStore(let s):  return s.name
        case .localFolder(let f): return f.name
        }
    }

    var isTrimmed: Bool { trimRange != nil }
}
