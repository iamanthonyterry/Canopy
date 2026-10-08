import Foundation

/// A clip prepared for hand-off to an editing app: where the media lives,
/// its technical details, and the review metadata added in Canopy.
struct NLEClip: Equatable {
    var name: String
    var url: URL
    var info: ClipInfo
    var markers: [ClipMarker] = []
    var keywords: [String] = []
    var note: String = ""
    var label: ClipLabel? = nil

    var durationSeconds: Double { info.duration }
}

// MARK: - Frame math

/// Rational time helpers so every timestamp in the export lands exactly on
/// a frame boundary, as FCPXML requires.
nonisolated enum FrameTiming {
    /// (numerator, denominator) of one frame, e.g. 23.976 → (1001, 24000).
    static func frameDuration(fps: Double) -> (num: Int, den: Int) {
        let f = fps > 0 ? fps : 24
        for (nominal, den) in [(24.0, 24000), (30.0, 30000), (60.0, 60000), (48.0, 48000)] {
            if abs(f - nominal * 1000 / 1001) < 0.01 { return (1001, den) }
        }
        return (1, max(1, Int(f.rounded())))
    }

    static func frames(seconds: Double, fps: Double) -> Int {
        max(0, Int((seconds * fps).rounded()))
    }

    /// FCPXML rational string for a frame count, e.g. "1001/24000s".
    static func rational(frames: Int, fps: Double) -> String {
        if frames == 0 { return "0s" }
        let d = frameDuration(fps: fps)
        return "\(frames * d.num)/\(d.den)s"
    }

    static func rational(seconds: Double, fps: Double) -> String {
        rational(frames: frames(seconds: seconds, fps: fps), fps: fps)
    }

    /// Non-drop-frame timecode for a frame count at a nominal rate.
    static func timecode(frames: Int, fps: Double) -> String {
        let base = max(1, Int(fps.rounded()))
        let f = frames % base
        let total = frames / base
        return String(format: "%02d:%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60, f)
    }
}

// MARK: - FCPXML (DaVinci Resolve: File ▸ Import ▸ Timeline)

enum FCPXMLBuilder {
    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Clips are laid end to end on one timeline starting at 01:00:00:00.
    static func xml(projectName: String, clips: [NLEClip]) -> String {
        guard let first = clips.first else { return "" }

        // One <format> per distinct frame size / rate.
        struct FormatKey: Hashable { var w: Int; var h: Int; var fps: Double }
        var formatIDs: [FormatKey: String] = [:]
        var formatXML = ""
        func formatID(for info: ClipInfo) -> String {
            let key = FormatKey(w: info.width, h: info.height, fps: info.fps > 0 ? info.fps : 24)
            if let id = formatIDs[key] { return id }
            let id = "r\(formatIDs.count + 1)"
            formatIDs[key] = id
            let d = FrameTiming.frameDuration(fps: key.fps)
            formatXML += "    <format id=\"\(id)\" frameDuration=\"\(d.num)/\(d.den)s\" width=\"\(key.w)\" height=\"\(key.h)\"/>\n"
            return id
        }
        let sequenceFormat = formatID(for: first.info)
        let seqFPS = first.info.fps > 0 ? first.info.fps : 24

        var assetXML = ""
        var spine = ""
        var offsetFrames = 3600 * Int(seqFPS.rounded())   // 01:00:00:00

        for (index, clip) in clips.enumerated() {
            let fps = clip.info.fps > 0 ? clip.info.fps : 24
            let fid = formatID(for: clip.info)
            let assetID = "a\(index + 1)"
            let durFrames = FrameTiming.frames(seconds: clip.durationSeconds, fps: fps)
            let duration = FrameTiming.rational(frames: durFrames, fps: fps)

            assetXML += "    <asset id=\"\(assetID)\" name=\"\(xmlEscape(clip.name))\" start=\"0s\" duration=\"\(duration)\" hasVideo=\"1\"\(clip.info.hasAudio ? " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"" : "") format=\"\(fid)\" src=\"\(xmlEscape(clip.url.absoluteString))\"/>\n"

            // Sequence offsets are in the sequence's own timebase.
            let offset = FrameTiming.rational(frames: offsetFrames, fps: seqFPS)
            var inner = ""
            var notes = clip.note
            if let label = clip.label {
                notes += (notes.isEmpty ? "" : "\n") + "Label: \(label.title)"
            }
            if !notes.isEmpty { inner += "            <note>\(xmlEscape(notes))</note>\n" }
            var keywords = clip.keywords
            if let label = clip.label { keywords.append("Label \(label.title)") }
            for keyword in keywords {
                inner += "            <keyword start=\"0s\" duration=\"\(duration)\" value=\"\(xmlEscape(keyword))\"/>\n"
            }
            let oneFrame = FrameTiming.rational(frames: 1, fps: fps)
            for marker in clip.markers.sorted(by: { $0.time < $1.time }) where marker.time >= 0 && marker.time < clip.durationSeconds {
                inner += "            <marker start=\"\(FrameTiming.rational(seconds: marker.time, fps: fps))\" duration=\"\(oneFrame)\" value=\"\(xmlEscape(marker.label))\"/>\n"
            }

            spine += "          <asset-clip ref=\"\(assetID)\" offset=\"\(offset)\" name=\"\(xmlEscape(clip.name))\" start=\"0s\" duration=\"\(duration)\" format=\"\(fid)\" tcFormat=\"NDF\">\n\(inner)          </asset-clip>\n"

            // Advance in the sequence timebase (clips at other rates are
            // placed by their real duration, rounded to a sequence frame).
            offsetFrames += FrameTiming.frames(seconds: clip.durationSeconds, fps: seqFPS)
        }

        let totalFrames = offsetFrames - 3600 * Int(seqFPS.rounded())
        let totalDuration = FrameTiming.rational(frames: totalFrames, fps: seqFPS)
        let tcStart = FrameTiming.rational(frames: 3600 * Int(seqFPS.rounded()), fps: seqFPS)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.9">
          <resources>
        \(formatXML)\(assetXML)  </resources>
          <library>
            <event name="\(xmlEscape(projectName))">
              <project name="\(xmlEscape(projectName))">
                <sequence format="\(sequenceFormat)" duration="\(totalDuration)" tcStart="\(tcStart)" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                  <spine>
        \(spine)          </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """
    }
}

// MARK: - EDL (CMX 3600)

enum EDLBuilder {
    /// Marker colors Resolve understands in `* LOC:` lines.
    private static func locColor(_ label: ClipLabel?) -> String {
        switch label {
        case .red: return "RED"
        case .orange, .yellow: return "YELLOW"
        case .green: return "GREEN"
        case .blue: return "BLUE"
        case .purple: return "PURPLE"
        default: return "BLUE"
        }
    }

    static func edl(title: String, clips: [NLEClip]) -> String {
        guard let first = clips.first else { return "" }
        let fps = first.info.fps > 0 ? first.info.fps : 24
        var out = "TITLE: \(title)\nFCM: NON-DROP FRAME\n\n"
        var recordFrame = 3600 * Int(fps.rounded())

        for (i, clip) in clips.enumerated() {
            let frames = max(1, FrameTiming.frames(seconds: clip.durationSeconds, fps: fps))
            let srcIn = FrameTiming.timecode(frames: 0, fps: fps)
            let srcOut = FrameTiming.timecode(frames: frames, fps: fps)
            let recIn = FrameTiming.timecode(frames: recordFrame, fps: fps)
            let recOut = FrameTiming.timecode(frames: recordFrame + frames, fps: fps)
            out += String(format: "%03d  AX       %@     C        %@ %@ %@ %@\n",
                          i + 1, clip.info.hasAudio ? "AA/V" : "V   ", srcIn, srcOut, recIn, recOut)
            out += "* FROM CLIP NAME: \(clip.name)\n"
            for marker in clip.markers.sorted(by: { $0.time < $1.time }) where marker.time < clip.durationSeconds {
                let at = FrameTiming.timecode(frames: recordFrame + FrameTiming.frames(seconds: marker.time, fps: fps), fps: fps)
                out += "* LOC: \(at) \(locColor(clip.label)) \(marker.label)\n"
            }
            out += "\n"
            recordFrame += frames
        }
        return out
    }
}

// MARK: - Gathering

@MainActor
enum NLEExportService {
    struct Gathered {
        var clips: [NLEClip]
        /// Clips left out because their media isn't on a mounted volume.
        var skipped: [String]
    }

    /// Builds export clips from Canopy's saved metadata. Only clips on a
    /// mounted volume can be handed over, since the editing app needs a real
    /// file path and the clip's frame rate/duration.
    static func gather(_ entries: [(id: String, metadata: ClipMetadata)]) async -> Gathered {
        var clips: [NLEClip] = []
        var skipped: [String] = []
        for entry in entries where entry.metadata.isVideo {
            let m = entry.metadata
            guard let url = m.localURL, FileManager.default.fileExists(atPath: url.path),
                  let info = await ClipInfoService.shared.info(for: url) else {
                skipped.append(m.clipName)
                continue
            }
            clips.append(NLEClip(name: m.clipName, url: url, info: info, markers: m.markers,
                                 keywords: m.keywords, note: m.note, label: m.label))
        }
        clips.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Gathered(clips: clips, skipped: skipped)
    }
}
