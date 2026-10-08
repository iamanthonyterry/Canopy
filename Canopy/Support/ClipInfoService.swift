import Foundation
import AVFoundation
import CoreMedia

/// Technical details shown on clip tiles and inspectors.
struct ClipInfo: Equatable {
    var duration: Double
    var width: Int
    var height: Int
    var fps: Double
    var codec: String?
    var hasAudio = false

    var durationLabel: String { ClipInfoFormat.duration(duration) }

    /// e.g. "1920×1080 · 24p · ProRes 422 HQ"
    var summary: String {
        var parts: [String] = []
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if fps > 0 { parts.append(ClipInfoFormat.frameRate(fps)) }
        if let codec { parts.append(codec) }
        return parts.joined(separator: " · ")
    }
}

nonisolated enum ClipInfoFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func frameRate(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded))p" : String(format: "%.2fp", rounded)
    }

    static func codecName(fourCC: String) -> String {
        switch fourCC {
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422 LT"
        case "apco": return "ProRes Proxy"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        default: return fourCC.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Reads and caches clip details for files on mounted volumes. Lookups are
/// de-duplicated so a grid of tiles asking at once triggers one read each.
@MainActor
final class ClipInfoService {
    static let shared = ClipInfoService()

    private var cache: [URL: ClipInfo] = [:]
    private var inflight: [URL: Task<ClipInfo?, Never>] = [:]

    func cachedInfo(for url: URL) -> ClipInfo? { cache[url] }

    func info(for url: URL) async -> ClipInfo? {
        if let hit = cache[url] { return hit }
        if let running = inflight[url] { return await running.value }
        let task = Task<ClipInfo?, Never> { await Self.load(url) }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { cache[url] = result }
        return result
    }

    private nonisolated static func load(_ url: URL) async -> ClipInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return nil }
        var info = ClipInfo(duration: duration, width: 0, height: 0, fps: 0, codec: nil)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize) {
                info.width = Int(size.width.rounded()); info.height = Int(size.height.rounded())
            }
            if let rate = try? await track.load(.nominalFrameRate) { info.fps = Double(rate) }
            if let formats = try? await track.load(.formatDescriptions), let first = formats.first {
                let code = CMFormatDescriptionGetMediaSubType(first)
                let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
                info.codec = ClipInfoFormat.codecName(fourCC: String(decoding: bytes, as: UTF8.self))
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty { info.hasAudio = true }
        return info
    }
}
