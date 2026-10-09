import Foundation
import AppKit
import QuartzCore
import AVFoundation

/// One on-screen caption: a short run of words shown between two times,
/// measured from the start of the exported clip.
nonisolated struct CaptionCue: Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

// MARK: - Building cues from a transcript

nonisolated enum CaptionBuilder {
    private static let sentenceEnders: Set<Character> = [".", "?", "!", "…"]

    /// Short-form captions: a few words at a time, broken at sentence ends
    /// and pauses, timed relative to `clipStart`.
    static func cues(
        from transcript: Transcript,
        clipStart: TimeInterval,
        clipEnd: TimeInterval,
        maxWords: Int = 4,
        maxCharacters: Int = 24,
        pauseBreak: TimeInterval = 0.5
    ) -> [CaptionCue] {
        let words = transcript.segments.flatMap(\.words).filter {
            $0.end > clipStart && $0.start < clipEnd
        }
        guard !words.isEmpty else { return [] }

        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []

        func characters(_ ws: [TranscriptWord]) -> Int {
            ws.map(\.text.count).reduce(0, +) + max(ws.count - 1, 0)
        }

        for (i, word) in words.enumerated() {
            if let prev = current.last {
                let endedSentence = prev.text.last.map(sentenceEnders.contains) ?? false
                let paused = word.start - prev.end > pauseBreak
                let full = current.count >= maxWords || characters(current + [word]) > maxCharacters
                if endedSentence || paused || full {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
            if i == words.count - 1 { groups.append(current) }
        }

        var cues: [CaptionCue] = groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let start = max(first.start - clipStart, 0)
            let end = min(last.end, clipEnd) - clipStart
            guard end > start else { return nil }
            return CaptionCue(text: group.map(\.text).joined(separator: " "), start: start, end: end)
        }

        // Hold each caption until the next one when the gap is small, so
        // captions don't flicker off between words; otherwise linger briefly.
        for i in cues.indices {
            let minimumEnd = cues[i].start + 0.3
            cues[i].end = max(cues[i].end, minimumEnd)
            if i + 1 < cues.count {
                let gap = cues[i + 1].start - cues[i].end
                // Stop just short of the next cue so two never overlap on a boundary frame.
                if gap < 0.35 { cues[i].end = cues[i + 1].start - 0.03 }
                else { cues[i].end += 0.2 }
            } else {
                cues[i].end += 0.2
            }
        }
        return cues
    }
}

// MARK: - Rendering

/// Builds the Core Animation layers that burn captions into an export.
///
/// Each caption is drawn into a bitmap up front and used as the layer's
/// contents. `CATextLayer` text isn't reliably drawn when the layers are
/// built off the main thread for an export, but plain image contents are.
nonisolated enum CaptionLayers {
    /// Layers positioned for a canvas of `canvas` points, bottom-left origin.
    /// Each one is invisible except during its cue.
    static func layers(for cues: [CaptionCue], canvas: CGSize) -> [CALayer] {
        let fontSize = canvas.width * 0.075
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = fontSize * 0.12
        shadow.shadowOffset = .zero

        // Two passes: a thick black outline (with the shadow), then a clean
        // white fill on top. Stroking and filling in one pass lets glyph
        // contour overlaps show through as specks.
        let outline: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .strokeColor: NSColor.black,
            .strokeWidth: 14,           // positive: stroke only, % of font size
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ]
        let fill: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]

        let width = canvas.width * 0.86
        let x = (canvas.width - width) / 2
        // Sits above the zone platform UI (captions, buttons) covers.
        let baseY = canvas.height * 0.2
        let padding = fontSize * 0.25

        return cues.compactMap { cue in
            let string = NSAttributedString(string: cue.text, attributes: fill)
            let outlineString = NSAttributedString(string: cue.text, attributes: outline)
            let measured = string.boundingRect(
                with: CGSize(width: width, height: canvas.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let size = CGSize(width: width, height: ceil(measured.height) + padding * 2)
            guard let image = bitmap(passes: [outlineString, string], size: size, padding: padding) else { return nil }

            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            layer.frame = CGRect(origin: CGPoint(x: x, y: baseY), size: size)
            layer.opacity = 0

            // Visible only while its animation is active.
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + cue.start
            show.duration = max(cue.end - cue.start, 0.05)
            show.fillMode = .removed
            show.isRemovedOnCompletion = false
            layer.add(show, forKey: "show")
            return layer
        }
    }

    private static func bitmap(passes: [NSAttributedString], size: CGSize, padding: CGFloat) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = CGRect(x: 0, y: padding, width: size.width, height: size.height - padding * 2)
        for pass in passes {
            pass.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
