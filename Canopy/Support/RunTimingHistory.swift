import Foundation

/// What earlier runs taught us about how long things take on this Mac: how
/// fast each device downloads, how long a conversion takes per byte, and how
/// long each workflow step ran last time. `WorkflowRunSession.estimate` falls
/// back on these whenever the current run hasn't produced a measurement of
/// its own yet — at the very start of a run, between files, and for steps
/// (Transcribe, Find Clips, Copy To…) that report no progress at all.
@MainActor
final class RunTimingHistory {
    static let shared = RunTimingHistory()

    struct StepTiming: Codable, Equatable {
        var seconds: Double
        /// Total size of the files that run worked on, so the figure can be
        /// scaled to a run with more or less footage. Zero when unknown.
        var bytes: Int64
        var recordedAt = Date()
    }

    private struct Stored: Codable {
        var downloadSpeeds: [String: Double] = [:]
        var convertSecondsPerByte: [String: Double] = [:]
        var steps: [String: StepTiming] = [:]
    }

    /// Steps are keyed by id, and ids pile up as workflows are edited and
    /// deleted — the oldest are dropped past this.
    private static let maxSteps = 400

    private let defaults: UserDefaults
    private let key: String
    private var stored: Stored

    init(defaults: UserDefaults = .standard, key: String = "runTimingHistory") {
        self.defaults = defaults
        self.key = key
        stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    func downloadSpeed(forDevice name: String) -> Double? { stored.downloadSpeeds[name] }
    func convertSecondsPerByte(for preset: ConversionSettings.FFmpegPreset) -> Double? {
        stored.convertSecondsPerByte[preset.rawValue]
    }
    func timing(forStep id: UUID) -> StepTiming? { stored.steps[id.uuidString] }

    // Speeds and rates are averaged with what was already known rather than
    // replaced, so one unusually slow or fast run doesn't swing the next
    // run's opening estimate.

    func recordDownloadSpeed(_ bytesPerSecond: Double, forDevice name: String) {
        guard bytesPerSecond > 0 else { return }
        stored.downloadSpeeds[name] = Self.blend(stored.downloadSpeeds[name], bytesPerSecond)
        save()
    }

    func recordConvert(secondsPerByte: Double, for preset: ConversionSettings.FFmpegPreset) {
        guard secondsPerByte > 0 else { return }
        stored.convertSecondsPerByte[preset.rawValue] = Self.blend(stored.convertSecondsPerByte[preset.rawValue], secondsPerByte)
        save()
    }

    func recordStep(_ id: UUID, seconds: Double, bytes: Int64) {
        stored.steps[id.uuidString] = StepTiming(seconds: seconds, bytes: bytes)
        if stored.steps.count > Self.maxSteps {
            let oldest = stored.steps.sorted { $0.value.recordedAt < $1.value.recordedAt }
                .prefix(stored.steps.count - Self.maxSteps)
            for (id, _) in oldest { stored.steps[id] = nil }
        }
        save()
    }

    private static func blend(_ old: Double?, _ new: Double) -> Double {
        guard let old else { return new }
        return (old + new) / 2
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }
}
