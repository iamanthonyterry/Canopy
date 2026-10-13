import Foundation
import AVFoundation
import Accelerate
import SoundAnalysis

// MARK: - Music detection
// Listens to a video's audio for stretches of music, so Find Clips can suggest
// songs even when there are no words to go on. Uses the sound classifier that
// ships with macOS; nothing leaves this Mac.

/// One classifier reading: what a few seconds of audio sounded like, 0...1 each.
nonisolated struct MusicSample: Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var music: Double
    var singing: Double
    var speech: Double
}

/// A continuous stretch of music.
nonisolated struct MusicRange: Hashable {
    var start: TimeInterval
    var end: TimeInterval
    /// Mean classifier confidence across the stretch, 0...1.
    var confidence: Double

    var duration: TimeInterval { end - start }
}

nonisolated struct MusicAnalysis: Hashable {
    var ranges: [MusicRange]
    /// RMS level of each second of audio, from the start of the file.
    var loudness: [Float]
}

// MARK: - Merging (pure — no audio involved)

nonisolated enum MusicRanges {
    /// Joins the classifier's readings into stretches of music.
    /// - Parameters:
    ///   - threshold: how confident a reading must be to count as music.
    ///   - bridge: the longest gap joined over, so a breath between verses or
    ///     a spoken line mid-song doesn't split one song in two.
    ///   - minLength: shorter stretches (a sting, a ringtone) are dropped.
    static func merge(_ samples: [MusicSample], threshold: Double = 0.5,
                      bridge: TimeInterval = 6, minLength: TimeInterval = 10) -> [MusicRange] {
        var ranges: [MusicRange] = []
        var readings: [Int] = []
        for sample in samples.sorted(by: { $0.start < $1.start }) where isMusic(sample, threshold: threshold) {
            let level = max(sample.music, sample.singing)
            if let last = ranges.last, sample.start - last.end <= bridge {
                let n = Double(readings[readings.count - 1])
                ranges[ranges.count - 1].confidence = (last.confidence * n + level) / (n + 1)
                ranges[ranges.count - 1].end = max(last.end, sample.end)
                readings[readings.count - 1] += 1
            } else {
                ranges.append(MusicRange(start: sample.start, end: sample.end, confidence: level))
                readings.append(1)
            }
        }
        return ranges.filter { $0.duration >= minLength }
    }

    /// Someone talking over background music isn't a song: unless there's
    /// singing, the music has to be at least as prominent as the speech.
    private static func isMusic(_ sample: MusicSample, threshold: Double) -> Bool {
        guard max(sample.music, sample.singing) >= threshold else { return false }
        return sample.singing >= 0.3 || sample.music >= sample.speech
    }
}

// MARK: - Detector

nonisolated enum MusicDetector {
    /// Finds the music in a video and measures how loud each second is.
    @concurrent
    static func analyze(video: URL) async throws -> MusicAnalysis {
        let audio = try await TranscriptionService.extractAudio(from: AVURLAsset(url: video))
        defer { try? FileManager.default.removeItem(at: audio) }
        let samples = try await classify(audio)
        try Task.checkCancellation()
        return MusicAnalysis(ranges: MusicRanges.merge(samples), loudness: try loudness(of: audio))
    }

    private static func classify(_ audioFile: URL) async throws -> [MusicSample] {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        nonisolated(unsafe) let analyzer = try SNAudioFileAnalyzer(url: audioFile)
        let observer = Observer()
        try analyzer.add(request, withObserver: observer)
        await withTaskCancellationHandler {
            _ = await analyzer.analyze()
        } onCancel: {
            analyzer.cancelAnalysis()
        }
        try Task.checkCancellation()
        if let error = observer.error { throw error }
        return observer.samples
    }

    private static func loudness(of audioFile: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: audioFile)
        let perSecond = AVAudioFrameCount(file.processingFormat.sampleRate.rounded())
        guard perSecond > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: perSecond) else { return [] }
        var levels: [Float] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: perSecond)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
            levels.append(rms)
        }
        return levels
    }

    /// Collects readings as the analyzer delivers them on its own queue.
    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [MusicSample] = []
        private var failure: Error?

        var samples: [MusicSample] { lock.withLock { collected } }
        var error: Error? { lock.withLock { failure } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            func confidence(_ id: String) -> Double { result.classification(forIdentifier: id)?.confidence ?? 0 }
            let sample = MusicSample(
                start: result.timeRange.start.seconds, end: result.timeRange.end.seconds,
                music: confidence("music"),
                singing: max(confidence("singing"), confidence("choir_singing")),
                speech: confidence("speech"))
            lock.withLock { collected.append(sample) }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.withLock { failure = error }
        }
    }
}
