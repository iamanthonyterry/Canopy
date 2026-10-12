import Foundation
import AVFoundation
import Vision
import CoreImage
import QuartzCore

enum ReframeError: LocalizedError {
    case noVideoTrack
    case unreadable
    case diskFull
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:          return "The file has no video track"
        case .unreadable:            return "The file couldn't be read"
        case .diskFull:              return "The destination drive is nearly full"
        case .exportFailed(let why): return "Export failed: \(why)"
        }
    }
}

// MARK: - Geometry

/// Pure crop math, kept free of AVFoundation so it can be unit-tested.
nonisolated enum ReframeGeometry {
    /// The largest rect with `targetAspect` (width / height) that fits inside
    /// `source`, centered on `center` (normalized 0...1, origin top-left) and
    /// clamped to stay inside the frame. Only the axis with slack can move.
    static func cropRect(source: CGSize, targetAspect: CGFloat, center: CGPoint) -> CGRect {
        let sourceAspect = source.width / source.height
        let size: CGSize
        if sourceAspect > targetAspect {
            size = CGSize(width: source.height * targetAspect, height: source.height)
        } else {
            size = CGSize(width: source.width, height: source.width / targetAspect)
        }
        let x = min(max(center.x * source.width - size.width / 2, 0), source.width - size.width)
        let y = min(max(center.y * source.height - size.height / 2, 0), source.height - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The crop's size as a fraction of the source on each axis.
    static func cropFraction(source: CGSize, targetAspect: CGFloat) -> CGSize {
        let rect = cropRect(source: source, targetAspect: targetAspect, center: CGPoint(x: 0.5, y: 0.5))
        return CGSize(width: rect.width / source.width, height: rect.height / source.height)
    }
}

/// Turns noisy per-frame subject positions into a calm virtual-camera path.
nonisolated enum CameraPath {
    /// - Parameters:
    ///   - raw: subject center per sample (normalized, top-left origin);
    ///     nil where nothing was detected.
    ///   - cropFraction: crop size as a fraction of the source, per axis. The
    ///     camera only starts to pan once the subject drifts outside a small
    ///     dead zone of the crop, so a mostly-still subject gets a still shot.
    static func smooth(_ raw: [CGPoint?], cropFraction: CGSize) -> [CGPoint] {
        guard !raw.isEmpty else { return [] }

        // Fill gaps: hold the last known position, and back-fill the start.
        let known = raw.compactMap { $0 }
        guard let first = known.first else {
            return raw.map { _ in CGPoint(x: 0.5, y: 0.5) }
        }
        var filled: [CGPoint] = []
        var last = first
        for point in raw {
            if let point { last = point }
            filled.append(last)
        }

        // A short median filter drops one-frame misdetections. Indices are
        // clamped at the ends so the window stays full there.
        let radius = 2
        func clamped(_ i: Int) -> CGPoint { filled[min(max(i, 0), filled.count - 1)] }
        let median: [CGPoint] = filled.indices.map { i in
            let window = (i - radius ... i + radius).map(clamped)
            return CGPoint(
                x: window.map(\.x).sorted()[radius],
                y: window.map(\.y).sorted()[radius]
            )
        }

        // Dead-zone follow: the camera only moves once the subject nears the
        // edge of the dead zone.
        let deadX = cropFraction.width * 0.12
        let deadY = cropFraction.height * 0.12
        var camera = median[0]
        var followed: [CGPoint] = []
        for target in median {
            camera.x = follow(camera.x, target.x, deadZone: deadX)
            camera.y = follow(camera.y, target.y, deadZone: deadY)
            followed.append(camera)
        }

        // Round off the corners with a centered kernel. The whole clip is
        // known up front, so (unlike a live camera) this adds no lag: the
        // crop never trails a moving subject toward the edge of frame.
        return blurred(blurred(followed))
    }

    private static let kernel: [CGFloat] = [1, 4, 6, 4, 1].map { $0 / 16 }

    private static func blurred(_ points: [CGPoint]) -> [CGPoint] {
        let reach = kernel.count / 2
        return points.indices.map { i in
            var x: CGFloat = 0, y: CGFloat = 0
            for (k, weight) in kernel.enumerated() {
                let p = points[min(max(i + k - reach, 0), points.count - 1)]
                x += p.x * weight
                y += p.y * weight
            }
            return CGPoint(x: x, y: y)
        }
    }

    private static func follow(_ camera: CGFloat, _ target: CGFloat, deadZone: CGFloat) -> CGFloat {
        let delta = target - camera
        if abs(delta) <= deadZone { return camera }
        return target - (delta > 0 ? deadZone : -deadZone)
    }
}

// MARK: - Service

/// Re-crops a clip to a social-media aspect ratio. When asked to follow the
/// subject, it samples the clip, finds the person (or the most eye-catching
/// object) in each sample with Vision, smooths those positions into a camera
/// path, and bakes the moving crop into an AVFoundation export.
nonisolated enum ReframeService {
    /// Seconds between subject samples. Widened for very long clips so the
    /// number of samples (and layer instructions) stays bounded.
    private static let sampleInterval = 0.5
    private static let maxSamples = 1200
    private static let lowSpaceThresholdBytes: Int64 = 300 * 1024 * 1024

    /// Caps how many reframe renders run at once. Each holds a decoded
    /// composition, an export session and (when following a subject) a pile
    /// of Vision work, so several at once can exhaust memory. A separate
    /// instance from the Convert step's limiter, so a render can't deadlock
    /// against a conversion that is waiting on its own slot.
    private static let renderLimiter = ConversionSlotLimiter()

    @concurrent
    static func reframe(
        input: URL,
        output: URL,
        format: SocialFormat,
        followSubject: Bool,
        /// Only this part of `input` is exported (nil = the whole file).
        range: CMTimeRange? = nil,
        /// Burned into the picture; times are relative to the start of the export.
        captions: [CaptionCue] = [],
        detector: @escaping @Sendable (CGImage) -> CGPoint? = ReframeService.subjectCenter
    ) async throws {
        await renderLimiter.acquire()
        do {
            try await render(
                input: input, output: output, format: format, followSubject: followSubject,
                range: range, captions: captions, detector: detector
            )
        } catch {
            await renderLimiter.release()
            throw error
        }
        await renderLimiter.release()
    }

    private static func render(
        input: URL,
        output: URL,
        format: SocialFormat,
        followSubject: Bool,
        /// Only this part of `input` is exported (nil = the whole file).
        range: CMTimeRange? = nil,
        /// Burned into the picture; times are relative to the start of the export.
        captions: [CaptionCue] = [],
        detector: @escaping @Sendable (CGImage) -> CGPoint? = ReframeService.subjectCenter
    ) async throws {
        let outDir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)

        if let free = try? outDir.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(free) < lowSpaceThresholdBytes {
            throw ReframeError.diskFull
        }

        let source = AVURLAsset(url: input)
        guard try await source.load(.isReadable) else { throw ReframeError.unreadable }
        guard let sourceTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw ReframeError.noVideoTrack
        }
        let (naturalSize, preferredTransform, frameRate) = try await sourceTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )

        // For a sub-range, work on a composition holding just that stretch,
        // so everything below (sampling, camera path, captions) runs on a
        // timeline that starts at zero.
        var asset: AVAsset = source
        var track = sourceTrack
        var duration = try await source.load(.duration)
        if let range {
            let clip = AVMutableComposition()
            guard let video = clip.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ReframeError.exportFailed("couldn't build the clip")
            }
            try video.insertTimeRange(range, of: sourceTrack, at: .zero)
            video.preferredTransform = preferredTransform
            for audio in try await source.loadTracks(withMediaType: .audio) {
                let target = clip.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try? target?.insertTimeRange(range, of: audio, at: .zero)
            }
            asset = clip
            track = video
            duration = range.duration
        }

        // Work in the upright (rotation-applied) frame, so phone footage
        // shot in portrait is handled the same as anything else.
        let upright = naturalSize.applying(preferredTransform)
        let sourceSize = CGSize(width: abs(upright.width), height: abs(upright.height))
        let aspect = format.aspectRatio

        // Subject path: one normalized center per sample time.
        var times: [CMTime] = [.zero]
        var centers: [CGPoint] = [CGPoint(x: 0.5, y: 0.5)]
        if followSubject, duration.seconds > 0 {
            let step = max(sampleInterval, duration.seconds / Double(maxSamples))
            // Include a sample just before the end so the path doesn't go
            // stale over the last fraction of a step.
            var seconds = Array(stride(from: 0.0, to: duration.seconds, by: step))
            let tail = duration.seconds - 0.1
            if let last = seconds.last, tail - last > 0.1 { seconds.append(tail) }
            let sampleTimes = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
            let raw = try await detectSubjects(in: asset, at: sampleTimes, detector: detector)
            let path = CameraPath.smooth(
                raw, cropFraction: ReframeGeometry.cropFraction(source: sourceSize, targetAspect: aspect)
            )
            times = sampleTimes
            centers = path
        }
        // Close the last segment on the clip's end.
        times.append(duration)
        centers.append(centers.last ?? CGPoint(x: 0.5, y: 0.5))

        // One transform per keyframe: upright → crop origin → output scale.
        let outputSize = format.outputSize
        let transforms: [CGAffineTransform] = centers.map { center in
            let crop = ReframeGeometry.cropRect(source: sourceSize, targetAspect: aspect, center: center)
            let scale = outputSize.width / crop.width
            return preferredTransform
                .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        }

        var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        for i in 0..<(times.count - 1) {
            let range = CMTimeRange(start: times[i], end: times[i + 1])
            guard range.duration > .zero else { continue }
            layerConfig.addTransformRamp(.init(timeRange: range, start: transforms[i], end: transforms[i + 1]))
        }
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerConfig)],
            timeRange: CMTimeRange(start: .zero, duration: duration)
        ))

        var compositionConfig = AVVideoComposition.Configuration(
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate > 0 ? min(frameRate, 60).rounded() : 30)),
            instructions: [instruction],
            renderSize: outputSize
        )

        if !captions.isEmpty {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: outputSize)
            let videoLayer = CALayer()
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            for layer in CaptionLayers.layers(for: captions, canvas: outputSize) { parent.addSublayer(layer) }
            compositionConfig.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parent
            )
        }
        let composition = AVVideoComposition(configuration: compositionConfig)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ReframeError.exportFailed("no export session")
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ReframeError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: Subject detection

    private static func detectSubjects(
        in asset: AVAsset, at times: [CMTime], detector: @Sendable (CGImage) -> CGPoint?
    ) async throws -> [CGPoint?] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var results: [CGPoint?] = []
        for await item in generator.images(for: times) {
            try Task.checkCancellation()
            if case .success(_, let image, _) = item {
                // Vision and CoreImage hand back autoreleased objects, and a
                // Swift concurrency thread doesn't drain a pool between
                // iterations, so without this they pile up across the clip.
                results.append(autoreleasepool { detector(image) })
            } else {
                results.append(nil)
            }
        }
        return results
    }

    /// Where the subject is in `image`, normalized with a top-left origin.
    /// People win; failing that, whatever Vision finds most salient.
    static func subjectCenter(in image: CGImage) -> CGPoint? {
        let handler = VNImageRequestHandler(cgImage: image)

        let people = VNDetectHumanRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([people, faces])

        var boxes = (people.results ?? []).map(\.boundingBox)
        boxes += (faces.results ?? []).map(\.boundingBox)
        if let box = dominantUnion(of: boxes) { return topLeftCenter(of: box) }

        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([saliency])
        let objects = (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox)
        if let box = dominantUnion(of: objects) { return topLeftCenter(of: box) }

        return nil
    }

    /// Union of the boxes that are a meaningful size next to the largest one,
    /// so a small figure in the background doesn't drag the crop away from
    /// the main subject.
    private static func dominantUnion(of boxes: [CGRect]) -> CGRect? {
        guard let largest = boxes.map({ $0.width * $0.height }).max(), largest > 0 else { return nil }
        let kept = boxes.filter { $0.width * $0.height >= largest * 0.4 }
        return kept.dropFirst().reduce(kept[0]) { $0.union($1) }
    }

    /// Vision uses a bottom-left origin; the crop math uses top-left.
    private static func topLeftCenter(of box: CGRect) -> CGPoint {
        CGPoint(x: box.midX, y: 1 - box.midY)
    }
}
