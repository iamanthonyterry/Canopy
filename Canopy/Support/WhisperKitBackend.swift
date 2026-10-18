import Foundation
import Combine
import WhisperKit

// MARK: - Choices

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case apple, whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:   return "Apple"
        case .whisper: return "Whisper"
        }
    }
}

nonisolated enum WhisperVariant: String, CaseIterable, Identifiable {
    case accurate = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case light = "openai_whisper-base.en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accurate: return "Accurate"
        case .light:    return "Light"
        }
    }

    var detail: String {
        switch self {
        case .accurate: return "Whisper large-v3 turbo · about 630 MB · same model Transcriber uses"
        case .light:    return "Whisper base, English only · about 150 MB · faster, less accurate"
        }
    }

    static let repo = "argmaxinc/whisperkit-coreml"
}

// MARK: - Download state and settings

/// Which engine transcribes, which Whisper model it uses, and whether that
/// model is on disk. Files live in `SharedModelFolder`, so a model Transcriber
/// already downloaded shows up as ready.
@MainActor
final class WhisperModels: ObservableObject {
    static let shared = WhisperModels()

    enum DownloadState: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    @Published var engine: TranscriptionEngine { didSet { defaults.set(engine.rawValue, forKey: Keys.engine) } }
    @Published var variant: WhisperVariant {
        didSet { defaults.set(variant.rawValue, forKey: Keys.variant); refresh() }
    }
    @Published private(set) var downloadState: DownloadState = .idle
    @Published private(set) var isDownloaded = false

    private let defaults = UserDefaults.standard
    private var downloadTask: Task<Void, Never>?

    private enum Keys {
        static let engine = "transcriptionEngine"
        static let variant = "whisperVariant"
    }

    private init() {
        engine = defaults.string(forKey: Keys.engine).flatMap(TranscriptionEngine.init) ?? .apple
        variant = defaults.string(forKey: Keys.variant).flatMap(WhisperVariant.init) ?? .accurate
        refresh()
    }

    /// Whisper is in use only when chosen and its model is on disk. Until then Apple's engine answers.
    var isWhisperActive: Bool { engine == .whisper && isDownloaded }

    func refresh() {
        isDownloaded = SharedModelFolder.whisperModel(variant: variant.rawValue, repo: WhisperVariant.repo) != nil
    }

    func download() {
        guard downloadTask == nil else { return }
        let target = variant
        downloadState = .downloading(0)
        downloadTask = Task { [weak self] in
            do {
                try await SharedModelFolder.withDownloadLock("whisper-\(target.rawValue)") {
                    // The helper may have finished the same download while we waited.
                    if SharedModelFolder.whisperModel(variant: target.rawValue, repo: WhisperVariant.repo) != nil { return }
                    try FileManager.default.createDirectory(at: SharedModelFolder.whisper, withIntermediateDirectories: true)
                    let report: @Sendable (Progress) -> Void = { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in WhisperModels.shared.downloadState = .downloading(fraction) }
                    }
                    _ = try await WhisperKit.download(
                        variant: target.rawValue, downloadBase: SharedModelFolder.whisper,
                        from: WhisperVariant.repo, progressCallback: report)
                }
                self?.downloadState = .idle
            } catch is CancellationError {
                self?.downloadState = .idle
            } catch {
                self?.downloadState = .failed(error.localizedDescription)
            }
            self?.refresh()
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = .idle
    }

    /// Deletes the copy in the shared folder. A model found only in Transcriber's
    /// own folder is left alone, since the helper still uses it.
    func deleteDownload() {
        let folder = SharedModelFolder.whisper.appendingPathComponent("models/\(WhisperVariant.repo)/\(variant.rawValue)")
        try? FileManager.default.removeItem(at: folder)
        refresh()
    }
}

// MARK: - Backend

/// Keeps the loaded model between files, since loading and preparing it for the
/// Neural Engine is the slow part. WhisperKit isn't Sendable, so it never
/// leaves this actor: transcription runs here and only segments come out.
private actor WhisperKitHolder {
    private var loaded: (variant: String, kit: WhisperKit)?

    private func kit(for variant: String) async throws -> WhisperKit {
        if let loaded, loaded.variant == variant { return loaded.kit }
        guard let found = SharedModelFolder.whisperModel(variant: variant, repo: WhisperVariant.repo) else {
            throw TranscriptionError.modelMissing("Whisper")
        }
        let kit = try await WhisperKit(WhisperKitConfig(
            downloadBase: found.base, modelFolder: found.folder.path,
            verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
        loaded = (variant, kit)
        return kit
    }

    func transcribe(audioPath: String, variant: String, languageCode: String?) async throws -> [TranscriptSegment] {
        // Safe to hand to WhisperKit's nonisolated async call: the model is only ever used from here.
        nonisolated(unsafe) let kit = try await kit(for: variant)
        // The .en model rejects any other language, so only pass one to multilingual models.
        let language = variant.hasSuffix(".en") ? "en" : languageCode
        let options = DecodingOptions(
            task: .transcribe, language: language, temperature: 0, temperatureFallbackCount: 2,
            skipSpecialTokens: true, wordTimestamps: true, suppressBlank: true,
            compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6)
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)

        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper writes this for stretches it can't make out.
            guard text.contains(where: { $0.isLetter || $0.isNumber }),
                  !Self.hallucinations.contains(text.lowercased()) else { return nil }
            let words = (segment.words ?? []).compactMap { w -> TranscriptWord? in
                let piece = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                return piece.isEmpty ? nil : TranscriptWord(text: piece, start: Double(w.start), end: Double(w.end))
            }
            return TranscriptSegment(text: text, start: Double(segment.start), end: Double(segment.end), words: words)
        }
    }

    private static let hallucinations: Set<String> = ["thanks for watching", "thanks for watching!"]
}

struct WhisperKitBackend: TranscriptionBackend {
    private static let holder = WhisperKitHolder()
    let variant: String

    func transcribe(audioFile: URL, locale: Locale) async throws -> [TranscriptSegment] {
        try await Self.holder.transcribe(
            audioPath: audioFile.path, variant: variant, languageCode: locale.language.languageCode?.identifier)
    }
}
