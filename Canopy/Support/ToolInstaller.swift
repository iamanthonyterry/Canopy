import Foundation
import Combine

/// No-op — video conversion now uses AVFoundation (built into macOS).
/// No external tools, Homebrew, or ffmpeg required.
@MainActor
final class ToolInstaller: ObservableObject {

    static let shared = ToolInstaller()

    enum Phase: Equatable {
        case idle, done
    }

    @Published var phase: Phase = .done
    @Published var log: [String] = []

    var ffmpegReady: Bool { true }  // AVFoundation is always available

    /// Nothing to install — conversion is handled natively.
    func installIfNeeded() { phase = .done }
}
