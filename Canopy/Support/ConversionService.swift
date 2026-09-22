import Foundation
import AVFoundation

/// Result of a conversion/export attempt. Distinguishes a destination
/// running out of space from an ordinary codec/asset failure so callers can
/// warn the user and abort the rest of the run instead of just logging
/// "conversion failed" and grinding on into more of the same.
enum ConversionOutcome: Equatable {
    case success
    case failure
    case diskFull
}

/// Thread-safe flag set by the progress-watching task and read back on the
/// caller's side once `session.export` returns/throws.
private actor DiskFullFlag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}

/// Converts video files (MOV, MXF, etc.) to MP4 using Apple's built-in AVFoundation.
/// No external tools or Homebrew required — uses hardware-accelerated encoding on-device.
struct ConversionService {

    /// Below this much free space on the destination volume, a write is
    /// considered "about to fail" and gets cancelled proactively. AVFoundation
    /// can stall for a long time waiting on a write that's hitting ENOSPC
    /// rather than failing fast, so this needs to trip before the volume
    /// actually hits zero — hence a multi-hundred-MB margin, not a few KB.
    private static let lowSpaceThresholdBytes: Int64 = 300 * 1024 * 1024

    /// True once free space on `path`'s volume has dropped below the
    /// low-space threshold (or can't be determined at all, which is treated
    /// as "assume the worst" rather than silently exporting on unknown space).
    private static func isDestinationLowOnSpace(forPath path: String) -> Bool {
        guard let available = try? StorageCapacityService.availableBytes(forPath: path) else { return true }
        return available < lowSpaceThresholdBytes
    }

    // MARK: - Convert

    /// Convert a video file to MP4 (H.264 + AAC).
    /// - Parameters:
    ///   - input: Source video URL
    ///   - output: Destination .mp4 URL
    ///   - settings: Quality/preset preferences
    ///   - progress: Called on main actor with 0.0–1.0 as encoding progresses
    /// - Returns: `true` on success
    static func convert(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        timeRange: CMTimeRange? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> ConversionOutcome {
        // Create destination directory if needed
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Remove any existing file at the output path
        try? FileManager.default.removeItem(at: output)

        // Don't even start if the destination is already nearly full.
        if isDestinationLowOnSpace(forPath: output.deletingLastPathComponent().path) {
            return .diskFull
        }

        let asset = AVURLAsset(url: input)

        // Verify the asset is readable
        guard (try? await asset.load(.isReadable)) == true else { return .failure }

        // Pick the right export preset based on ConversionSettings
        let preset = exportPreset(for: settings)

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            return .failure
        }
        if let timeRange { session.timeRange = timeRange }

        session.shouldOptimizeForNetworkUse = true  // faststart equivalent

        // Poll progress on a background task. Also watches destination free
        // space each tick and cancels the export the moment it runs low,
        // rather than letting the write stall waiting on ENOSPC.
        let diskFullBox = DiskFullFlag()
        let progressTask = Task {
            while !Task.isCancelled {
                let pct = Double(session.progress)
                await MainActor.run { progress(pct) }
                if pct >= 1.0 { break }
                if isDestinationLowOnSpace(forPath: output.deletingLastPathComponent().path) {
                    await diskFullBox.set(true)
                    session.cancelExport()
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        var outcome: ConversionOutcome
        do {
            try await session.export(to: output, as: .mp4)
            outcome = .success
        } catch {
            outcome = .failure
        }
        progressTask.cancel()
        if await diskFullBox.value {
            outcome = .diskFull
        }
        if outcome != .success {
            try? FileManager.default.removeItem(at: output)
        }

        if outcome == .success {
            await MainActor.run { progress(1.0) }
        }
        return outcome
    }

    // MARK: - Trim / Export Clip

    /// Exports `input` to `output`, preserving the original codec (no
    /// re-encode) so it's fast and lossless. Used by the video preview's
    /// in/out point export feature and by the batch export queue.
    /// - Parameters:
    ///   - input: Source video URL (local file — already downloaded for HyperDeck clips)
    ///   - output: Destination URL for the exported clip
    ///   - timeRange: The in/out range to keep, or nil to export the whole asset
    ///   - progress: Called on main actor with 0.0–1.0 as the export proceeds
    /// - Returns: `true` on success
    static func exportClip(
        input: URL,
        output: URL,
        timeRange: CMTimeRange? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> ConversionOutcome {
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: output)

        if isDestinationLowOnSpace(forPath: output.deletingLastPathComponent().path) {
            return .diskFull
        }

        let asset = AVURLAsset(url: input)
        guard (try? await asset.load(.isReadable)) == true else { return .failure }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return .failure
        }
        if let timeRange { session.timeRange = timeRange }

        let outputType: AVFileType = output.pathExtension.lowercased() == "mp4" ? .mp4 : .mov

        let diskFullBox = DiskFullFlag()
        let progressTask = Task {
            while !Task.isCancelled {
                let pct = Double(session.progress)
                await MainActor.run { progress(pct) }
                if pct >= 1.0 { break }
                if isDestinationLowOnSpace(forPath: output.deletingLastPathComponent().path) {
                    await diskFullBox.set(true)
                    session.cancelExport()
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        var outcome: ConversionOutcome
        do {
            try await session.export(to: output, as: outputType)
            outcome = .success
        } catch {
            outcome = .failure
        }
        progressTask.cancel()
        if await diskFullBox.value {
            outcome = .diskFull
        }
        if outcome != .success {
            try? FileManager.default.removeItem(at: output)
        }

        if outcome == .success {
            await MainActor.run { progress(1.0) }
        }
        return outcome
    }

    // MARK: - Copy (non-video files, e.g. photos)

    /// Copies `input` to `output` verbatim — used for file types (photos)
    /// that AVFoundation can't process, so the export queue and image
    /// preview's Save can share the same disk-space-aware destination
    /// handling as the video export paths.
    static func copyFile(input: URL, output: URL) -> ConversionOutcome {
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: output)

        if isDestinationLowOnSpace(forPath: output.deletingLastPathComponent().path) {
            return .diskFull
        }

        do {
            try FileManager.default.copyItem(at: input, to: output)
            return .success
        } catch {
            return .failure
        }
    }

    // MARK: - Supported Input Check

    /// File extensions AVFoundation can read as video.
    static let convertibleExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "m2ts", "mts", "ts"]

    /// Returns true if AVFoundation can read this file type.
    static func canConvert(url: URL) -> Bool {
        convertibleExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Export Preset Selection

    private static func exportPreset(for settings: ConversionSettings) -> String {
        // Map quality tiers to AVFoundation presets.
        // These use hardware H.264 encoding automatically on Apple Silicon / Intel Macs.
        switch settings.preset {
        case .ultrafast, .superfast, .veryfast, .faster, .fast:
            return AVAssetExportPreset1920x1080       // 1080p — fast, broadcast-safe
        case .medium:
            return AVAssetExportPresetHighestQuality  // matches source resolution
        case .slow, .slower, .veryslow:
            return AVAssetExportPresetHighestQuality
        }
    }
}
