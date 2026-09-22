import Foundation

// MARK: - Export Preset
// A named, reusable export destination + quality, so exporting the queue
// doesn't mean picking a folder from a panel every time. "Original" keeps
// today's passthrough-copy behavior (no re-encode); "Compressed" transcodes
// through ConversionService.convert using an existing quality preset.
struct ExportPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var destinationPath: String
    var mode: Mode = .original

    enum Mode: Codable, Hashable {
        case original
        case compressed(ConversionSettings.FFmpegPreset)
    }

    var destinationURL: URL { URL(fileURLWithPath: destinationPath) }
}
