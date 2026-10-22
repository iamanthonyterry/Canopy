import Foundation

nonisolated let sampleRate = 16_000
nonisolated let frameSize = 480  // 30 ms

/// Energy-based speech detector that cuts audio into phrases.
/// The noise floor adapts, so it copes with different mixers and rooms. A phrase ends after a short
/// pause; run-on speech is cut at the next small pause once it passes a few seconds, so text and
/// translations appear without waiting for a full sentence.
nonisolated final class Segmenter {
    /// A phrase, and how much audio had been heard after it by the time it was cut (so it can be timed).
    struct Cut {
        let audio: [Float]
        let after: Double
    }

    private let minDb: Float
    private let endPause: Float
    private let marginDb: Float = 9
    private var floor: Float
    private var preroll: [[Float]] = []  // 300 ms before speech starts
    private var buf: [[Float]] = []
    private var quiet: [Bool] = []  // whether each frame of `buf` was below speech level, for placing a forced cut
    private var speaking = false
    private var silentFrames = 0
    private var speechFrames = 0
    private var pending: [Float] = []

    /// `endPause` is how long a silence ends a phrase: shorter reacts sooner but splits slow talkers.
    init(minDb: Double, endPause: Float = 0.5) {
        self.endPause = endPause
        self.minDb = Float(minDb)
        floor = Float(minDb) - 6
    }

    /// Accepts any amount of audio; returns every phrase completed by it.
    func feed(samples: [Float]) -> [Cut] {
        pending.append(contentsOf: samples)
        var phrases: [Cut] = []
        var i = 0
        while pending.count - i >= frameSize {
            if let p = feed(frame: Array(pending[i..<i + frameSize])) { phrases.append(p) }
            i += frameSize
        }
        pending.removeFirst(i)
        return phrases
    }

    private func levelDb(_ f: [Float]) -> Float {
        var sum: Float = 0
        for x in f { sum += x * x }
        return 20 * log10(sqrt(sum / Float(f.count)) + 1e-9)
    }

    private func feed(frame: [Float]) -> Cut? {
        let db = levelDb(frame)
        let loud = db > max(minDb, floor + marginDb)
        if !loud { floor = 0.98 * floor + 0.02 * db }  // track the noise floor only while it is quiet

        if !speaking {
            preroll.append(frame)
            if preroll.count > 10 { preroll.removeFirst() }
            if loud {
                speechFrames += 1
                if speechFrames >= 3 {  // ~90 ms of sound, ignore clicks
                    speaking = true
                    buf = preroll
                    quiet = [Bool](repeating: false, count: preroll.count)
                    silentFrames = 0
                }
            } else {
                speechFrames = 0
            }
            return nil
        }

        buf.append(frame)
        quiet.append(!loud)
        silentFrames = loud ? 0 : silentFrames + 1
        let seconds = Float(buf.count * frameSize) / Float(sampleRate)
        let pause = Float(silentFrames * frameSize) / Float(sampleRate)
        if pause >= endPause || (seconds >= 5 && pause >= 0.25) {
            // The closing pause stays in: a sentence often trails off below speech level, and trimming the
            // pause cut those last words off ("for the rest of their lives" lost "their lives").
            let audio = buf.flatMap { $0 }
            reset()
            return seconds - pause >= 0.4 ? Cut(audio: audio, after: 0) : nil  // drop blips
        }
        guard seconds >= 15 else { return nil }
        // Speech with no real pause: rather than cutting wherever it has got to (Whisper invents the rest of a
        // word cut in half), cut in the longest gap of the last 2 s and keep what follows for the next phrase.
        // Never in the last 300 ms, so the next phrase starts with something to go on. A gap under 120 ms is
        // as likely to be an "s" or a "t" inside a word as a space between two, so then it is cut here after all.
        var gap = 0..<0, start = buf.count - 67
        for i in buf.count - 67..<buf.count - 10 {
            if !quiet[i] { start = i + 1 } else if i + 1 - start > gap.count { gap = start..<i + 1 }
        }
        guard gap.count >= 4 else {
            let audio = buf.flatMap { $0 }
            reset()
            return Cut(audio: audio, after: 0)
        }
        let cut = gap.lowerBound + gap.count / 2
        let audio = buf[..<cut].flatMap { $0 }
        buf.removeFirst(cut)
        quiet.removeFirst(cut)
        return Cut(audio: audio, after: Self.duration(frames: buf.count))
    }

    private static func duration(frames: Int) -> Double { Double(frames * frameSize) / Double(sampleRate) }

    /// The audio of the phrase being spoken so far (at most the last `maxSeconds`), once it is `minSeconds` long.
    func inProgress(minSeconds: Double, maxSeconds: Double) -> [Float]? {
        guard speaking, Double(buf.count * frameSize) / Double(sampleRate) >= minSeconds else { return nil }
        return buf.suffix(Int(maxSeconds * Double(sampleRate)) / frameSize).flatMap { $0 }
    }

    func flush() -> [Float]? {
        guard speaking, !buf.isEmpty else { return nil }
        let audio = buf.flatMap { $0 }
        reset()
        return audio
    }

    private func reset() {
        buf = []
        quiet = []
        speaking = false
        silentFrames = 0
        speechFrames = 0
        preroll = []
    }
}
