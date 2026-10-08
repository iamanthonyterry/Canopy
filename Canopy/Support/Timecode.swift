import Foundation

/// Frame-accurate timecode formatting for the player.
enum Timecode {
    /// `HH:MM:SS:FF` using the nearest whole frame rate (non-drop-frame).
    static func string(seconds: Double, fps: Double) -> String {
        guard seconds.isFinite, seconds >= 0, fps > 0 else { return "00:00:00:00" }
        let base = max(1, Int(fps.rounded()))
        let totalFrames = Int((seconds * fps).rounded())
        let frames = totalFrames % base
        let totalSeconds = totalFrames / base
        return String(format: "%02d:%02d:%02d:%02d",
                      totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60, frames)
    }
}
