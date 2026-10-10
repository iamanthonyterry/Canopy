import Foundation
import Combine
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Choices

/// The opt-in downloadable models, both open-weight instruct models run
/// locally through MLX. Neither "thinks" out loud, so output stays short and
/// is grammar-constrained to each @Generable type's schema.
enum EnhancedModelChoice: String, CaseIterable, Identifiable {
    case balanced, best

    var id: String { rawValue }

    var repoID: String {
        switch self {
        case .balanced: return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        case .best:     return "mlx-community/Qwen2.5-7B-Instruct-4bit"
        }
    }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .best:     return "Best quality"
        }
    }

    var detail: String {
        switch self {
        case .balanced: return "Qwen3 4B · about 2.3 GB · needs roughly 4 GB of free memory"
        case .best:     return "Qwen2.5 7B · about 4.3 GB · needs roughly 8 GB of free memory"
        }
    }

    var configuration: ModelConfiguration { ModelConfiguration(id: repoID) }
}

// MARK: - Manager

/// Owns the optional enhanced model: whether it's turned on, which one, its
/// download, and the one place every feature goes through to run a prompt.
///
/// Apple's built-in model stays the default. When the enhanced model is on and
/// downloaded, it handles requests instead; if it ever fails, the request
/// falls back to Apple's model so a feature never just stops working.
@MainActor
final class AIModels: ObservableObject {
    static let shared = AIModels()

    enum DownloadState: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    @Published private(set) var downloadState: DownloadState = .idle
    @Published private(set) var downloaded: Set<String>

    @Published var useEnhanced: Bool {
        didSet { defaults.set(useEnhanced, forKey: Keys.useEnhanced); loadedModel = nil }
    }
    @Published var choice: EnhancedModelChoice {
        didSet { defaults.set(choice.rawValue, forKey: Keys.choice); loadedModel = nil }
    }

    private enum Keys {
        static let useEnhanced = "ai.useEnhancedModel"
        static let choice = "ai.enhancedModelChoice"
        static let downloaded = "ai.downloadedModels"
    }

    private let defaults = UserDefaults.standard
    private var downloadTask: Task<Void, Never>?
    /// The built `MLXLanguageModel` (macOS 27+), kept so the weights stay
    /// loaded between requests instead of reloading each time.
    private var loadedModel: Any?

    private init() {
        useEnhanced = defaults.bool(forKey: Keys.useEnhanced)
        choice = defaults.string(forKey: Keys.choice).flatMap(EnhancedModelChoice.init(rawValue:)) ?? .balanced
        downloaded = Set(defaults.stringArray(forKey: Keys.downloaded) ?? [])
    }

    // MARK: Status

    /// The enhanced model needs the macOS 27 FoundationModels bridge.
    var isSupported: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }

    var isDownloaded: Bool { downloaded.contains(choice.repoID) }

    /// True when requests will be answered by the enhanced model.
    var isEnhancedActive: Bool { useEnhanced && isDownloaded && isSupported }

    /// Why no model can answer right now, or nil when one can.
    var unavailableReason: String? {
        if isEnhancedActive { return nil }
        return Self.appleUnavailableReason
    }

    static var appleUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence. You can download an enhanced model in Settings instead."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings, or download an enhanced model in Settings."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable:
            return "The on-device model isn't available right now."
        }
    }

    // MARK: Download

    func download() {
        guard downloadTask == nil, isSupported else { return }
        let target = choice
        downloadState = .downloading(0)
        downloadTask = Task { [weak self] in
            guard #available(macOS 27.0, *) else { return }
            do {
                // Loading the container fetches the weights into the shared
                // Hugging Face cache and proves the model actually loads.
                _ = try await loadModelContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: target.configuration,
                    progressHandler: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            AIModels.shared.downloadState = .downloading(fraction)
                        }
                    }
                )
                self?.finishDownload(target)
            } catch is CancellationError {
                self?.downloadState = .idle
            } catch {
                self?.downloadState = .failed(error.localizedDescription)
            }
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = .idle
    }

    private func finishDownload(_ target: EnhancedModelChoice) {
        downloaded.insert(target.repoID)
        defaults.set(Array(downloaded), forKey: Keys.downloaded)
        downloadState = .idle
    }

    /// Removes the downloaded weights for the selected model from disk.
    func deleteDownload() {
        let target = choice
        if let repo = Repo.ID(rawValue: target.repoID) {
            try? FileManager.default.removeItem(at: HubCache.default.repoDirectory(repo: repo, kind: .model))
        }
        downloaded.remove(target.repoID)
        defaults.set(Array(downloaded), forKey: Keys.downloaded)
        loadedModel = nil
    }

    // MARK: Generation

    /// Runs a prompt and returns the model's answer as `type`, constrained to
    /// its schema. Uses the enhanced model when it's on, falling back to
    /// Apple's if that fails and Apple's is available.
    func generate<T: Generable>(
        _ type: T.Type, instructions: String, prompt: String
    ) async throws -> T {
        let options = GenerationOptions(samplingMode: .greedy)

        if isEnhancedActive, #available(macOS 27.0, *) {
            do {
                let session = LanguageModelSession(model: enhancedModel(), instructions: instructions)
                return try await session.respond(to: prompt, generating: type, options: options).content
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Nothing to fall back to: report what went wrong.
                if Self.appleUnavailableReason != nil { throw error }
            }
        }

        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt, generating: type, options: options).content
    }

    @available(macOS 27.0, *)
    private func enhancedModel() -> MLXLanguageModel {
        if let model = loadedModel as? MLXLanguageModel { return model }
        let model = #huggingFaceLanguageModel(configuration: choice.configuration)
        loadedModel = model
        return model
    }
}
