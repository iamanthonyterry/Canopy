import Foundation
import AVFoundation
import Speech

/// A speech-to-text engine. `SpeechAnalyzerBackend` ships with macOS; a
/// WhisperKit backend can be added later behind the same interface.
protocol TranscriptionBackend: Sendable {
    func transcribe(audioFile: URL, locale: Locale) async throws -> [TranscriptSegment]
}

enum TranscriptionError: LocalizedError {
    case noAudioTrack
    case unsupportedLocale(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:               return "The file has no audio track"
        case .unsupportedLocale(let id):  return "Speech recognition isn't available for \(id) on this Mac"
        case .exportFailed(let reason):   return "Couldn't extract audio: \(reason)"
        }
    }
}

enum TranscriptionService {
    static var backend: TranscriptionBackend = SpeechAnalyzerBackend()

    /// Transcribes a video's audio track. Extracts audio to a temporary file
    /// first because recognition wants plain audio, not a ProRes/H.264 container.
    static func transcribe(video: URL, localeID: String) async throws -> Transcript {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw TranscriptionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("canopy-transcribe-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.exportFailed("no audio export preset")
        }
        do {
            try await export.export(to: audioURL, as: .m4a)
        } catch {
            throw TranscriptionError.exportFailed(error.localizedDescription)
        }

        let locale = Locale(identifier: localeID)
        let segments = try await backend.transcribe(audioFile: audioURL, locale: locale)
        return Transcript(
            sourceFileName: video.lastPathComponent,
            locale: localeID,
            duration: duration,
            segments: segments
        )
    }
}

// MARK: - Apple SpeechAnalyzer (on-device, macOS 26+)

struct SpeechAnalyzerBackend: TranscriptionBackend {
    func transcribe(audioFile: URL, locale: Locale) async throws -> [TranscriptSegment] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // First use of a language downloads its model (once, managed by the OS).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audioFile)

        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                if let segment = Self.segment(from: result.text) { segments.append(segment) }
            }
            return segments
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch {
            collector.cancel()
            throw error
        }
    }

    /// Turns one recognition result into a segment with per-word timings,
    /// read from the `audioTimeRange` attribute on each run of text.
    private static func segment(from text: AttributedString) -> TranscriptSegment? {
        var words: [TranscriptWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let range = run.audioTimeRange else { continue }
            words.append(TranscriptWord(text: piece, start: range.start.seconds, end: range.end.seconds))
        }
        guard let first = words.first, let last = words.last else { return nil }
        let joined = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptSegment(text: joined, start: first.start, end: last.end, words: words)
    }
}
