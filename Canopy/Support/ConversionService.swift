import Foundation
import AVFoundation

/// Converts video files (MOV, MXF, etc.) to MP4 using Apple's built-in AVFoundation.
/// No external tools or Homebrew required — uses hardware-accelerated encoding on-device.
struct ConversionService {

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
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        // Create destination directory if needed
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Remove any existing file at the output path
        try? FileManager.default.removeItem(at: output)

        let asset = AVURLAsset(url: input)

        // Verify the asset is readable
        guard (try? await asset.load(.isReadable)) == true else { return false }

        // Pick the right export preset based on ConversionSettings
        let preset = exportPreset(for: settings)

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            return false
        }

        session.shouldOptimizeForNetworkUse = true  // faststart equivalent

        // Poll progress on a background task
        let progressTask = Task {
            while !Task.isCancelled {
                let pct = Double(session.progress)
                await MainActor.run { progress(pct) }
                if pct >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        let success: Bool
        do {
            try await session.export(to: output, as: .mp4)
            success = true
        } catch {
            success = false
        }
        progressTask.cancel()

        if success {
            await MainActor.run { progress(1.0) }
        }
        return success
    }

    // MARK: - Trim / Export Clip

    /// Exports a sub-range of `input` to `output`, preserving the original
    /// codec (no re-encode) so trimming is fast and lossless. Used by the
    /// video preview's in/out point export feature.
    /// - Parameters:
    ///   - input: Source video URL (local file — already downloaded for HyperDeck clips)
    ///   - output: Destination URL for the trimmed clip
    ///   - timeRange: The in/out range to keep
    ///   - progress: Called on main actor with 0.0–1.0 as the export proceeds
    /// - Returns: `true` on success
    static func exportClip(
        input: URL,
        output: URL,
        timeRange: CMTimeRange,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: output)

        let asset = AVURLAsset(url: input)
        guard (try? await asset.load(.isReadable)) == true else { return false }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        session.timeRange = timeRange

        let outputType: AVFileType = output.pathExtension.lowercased() == "mp4" ? .mp4 : .mov

        let progressTask = Task {
            while !Task.isCancelled {
                let pct = Double(session.progress)
                await MainActor.run { progress(pct) }
                if pct >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        let success: Bool
        do {
            try await session.export(to: output, as: outputType)
            success = true
        } catch {
            success = false
        }
        progressTask.cancel()

        if success {
            await MainActor.run { progress(1.0) }
        }
        return success
    }

    // MARK: - Supported Input Check

    /// Returns true if AVFoundation can read this file type.
    static func canConvert(url: URL) -> Bool {
        let readable: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "m2ts", "mts", "ts"]
        return readable.contains(url.pathExtension.lowercased())
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
