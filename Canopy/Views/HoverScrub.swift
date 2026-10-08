import SwiftUI
import AVFoundation
import AppKit

// MARK: - Thumbnail cache
// Memory-only cache so scrolling a large grid doesn't regenerate thumbnails.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 600 }

    func image(forKey key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func set(_ image: NSImage, forKey key: String) { cache.setObject(image, forKey: key as NSString) }
}

// MARK: - Hover scrub
// Move the mouse across a video tile to skim through it: x position maps to
// a time in the clip, and the frame at that time replaces the poster. Local
// files only (needs random access); the poster returns when the mouse leaves.

private struct HoverScrubModifier: ViewModifier {
    let url: URL
    let size: CGFloat

    @State private var frame: NSImage?
    @State private var fraction: Double?
    @State private var generator: AVAssetImageGenerator?
    @State private var duration: Double = 0
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    if let frame {
                        Image(nsImage: frame)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let fraction, frame != nil {
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: max(2, size * fraction), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    scrub(to: min(max(location.x / size, 0), 1))
                case .ended:
                    reset()
                }
            }
            .onDisappear { reset() }
    }

    private func scrub(to newFraction: Double) {
        fraction = newFraction
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            if generator == nil {
                guard let info = await ClipInfoService.shared.info(for: url), info.duration > 0 else { return }
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: size * 2, height: size * 2)
                gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator = gen
                duration = info.duration
            }
            guard let generator, !Task.isCancelled else { return }
            let time = CMTime(seconds: duration * newFraction, preferredTimescale: 600)
            // Only the latest requested frame matters while the mouse moves.
            generator.cancelAllCGImageGeneration()
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, _ in
                guard result == .succeeded, let image else { return }
                let nsImage = NSImage(cgImage: image, size: .zero)
                Task { @MainActor in frame = nsImage }
            }
        }
    }

    private func reset() {
        pending?.cancel()
        pending = nil
        generator?.cancelAllCGImageGeneration()
        generator = nil
        frame = nil
        fraction = nil
    }
}

extension View {
    @ViewBuilder
    func hoverScrub(node: FileNode, size: CGFloat) -> some View {
        if node.isVideo, let url = node.url {
            modifier(HoverScrubModifier(url: url, size: size))
        } else {
            self
        }
    }
}
