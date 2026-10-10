import Foundation
import AVFoundation

/// Turns a suggested clip into a finished social post: trimmed to the clip,
/// cropped to the target format (following the subject), with captions
/// burned in from the transcript.
nonisolated enum SocialPostExporter {
    struct Options: Sendable {
        var format: SocialFormat = .vertical
        var followSubject = true
        var captions = true
    }

    /// - Parameters:
    ///   - transcript: source of caption words; without one, no captions.
    static func export(
        source: URL,
        clip: ClipCandidate,
        transcript: Transcript?,
        options: Options,
        output: URL
    ) async throws {
        let range = CMTimeRange(
            start: CMTime(seconds: clip.start, preferredTimescale: 600),
            end: CMTime(seconds: clip.end, preferredTimescale: 600)
        )
        var cues: [CaptionCue] = []
        if options.captions, let transcript {
            cues = CaptionBuilder.cues(from: transcript, clipStart: clip.start, clipEnd: clip.end)
        }
        try await ReframeService.reframe(
            input: source, output: output,
            format: options.format, followSubject: options.followSubject,
            range: range, captions: cues
        )
        // Copy that goes with the post, beside it, ready to paste.
        if let copy = clip.copy {
            let text = "\(copy.headline)\n\n\(copy.postText)\n"
            let sidecar = output.deletingPathExtension().appendingPathExtension("txt")
            try? text.write(to: sidecar, atomically: true, encoding: .utf8)
        }
    }

    /// `A001.mov`, clip 2 "Big Idea", vertical → `A001_clip02_Big-Idea_9x16.mp4`.
    static func fileName(base: String, index: Int, title: String, format: SocialFormat) -> String {
        String(format: "%@_clip%02d_%@_%@.mp4", base, index, slug(title), format.fileSuffix)
    }

    static func slug(_ title: String) -> String {
        let words = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let joined = String(words).split(separator: " ").prefix(6).joined(separator: "-")
        return joined.isEmpty ? "clip" : joined
    }
}
