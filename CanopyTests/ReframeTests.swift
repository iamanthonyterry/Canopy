import Testing
import CoreGraphics
import Foundation
@testable import Canopy

struct ReframeTests {
    private let hd = CGSize(width: 1920, height: 1080)

    @Test func verticalCropIsFullHeightAndFollowsCenter() {
        let rect = ReframeGeometry.cropRect(source: hd, targetAspect: 9.0 / 16.0, center: CGPoint(x: 0.25, y: 0.5))
        #expect(rect.height == 1080)
        #expect(abs(rect.width - 607.5) < 0.01)
        #expect(abs(rect.midX - 480) < 0.01)
    }

    @Test func cropIsClampedInsideTheFrame() {
        let left = ReframeGeometry.cropRect(source: hd, targetAspect: 9.0 / 16.0, center: CGPoint(x: 0, y: 0.5))
        let right = ReframeGeometry.cropRect(source: hd, targetAspect: 9.0 / 16.0, center: CGPoint(x: 1, y: 0.5))
        #expect(left.minX == 0)
        #expect(abs(right.maxX - 1920) < 0.01)
    }

    @Test func landscapeTargetFromPortraitSourceMovesVertically() {
        let portrait = CGSize(width: 1080, height: 1920)
        let rect = ReframeGeometry.cropRect(source: portrait, targetAspect: 16.0 / 9.0, center: CGPoint(x: 0.5, y: 0.2))
        #expect(rect.width == 1080)
        #expect(abs(rect.midY - 384) < 0.01)
    }

    @Test func missingDetectionsHoldTheLastKnownPosition() {
        let fraction = ReframeGeometry.cropFraction(source: hd, targetAspect: 9.0 / 16.0)
        let path = CameraPath.smooth([CGPoint(x: 0.3, y: 0.5), nil, nil, nil], cropFraction: fraction)
        #expect(path.count == 4)
        #expect(path.allSatisfy { abs($0.x - 0.3) < 0.001 })
    }

    @Test func smallJitterInsideDeadZoneDoesNotMoveTheCamera() {
        let fraction = ReframeGeometry.cropFraction(source: hd, targetAspect: 9.0 / 16.0)
        let raw: [CGPoint?] = (0..<20).map { CGPoint(x: 0.5 + ($0 % 2 == 0 ? 0.01 : -0.01), y: 0.5) }
        let path = CameraPath.smooth(raw, cropFraction: fraction)
        #expect(path.allSatisfy { abs($0.x - 0.5) < 0.02 })
    }

    @Test func cameraFollowsASubjectThatMovesAcrossTheFrame() {
        let fraction = ReframeGeometry.cropFraction(source: hd, targetAspect: 9.0 / 16.0)
        // Subject walks steadily from x = 0.2 to x = 0.8.
        let raw: [CGPoint?] = (0..<13).map { CGPoint(x: 0.2 + 0.05 * Double($0), y: 0.5) }
        let path = CameraPath.smooth(raw, cropFraction: fraction)
        let halfCrop = fraction.width / 2
        for (camera, subject) in zip(path, raw) {
            // The subject stays well inside the crop window the whole way.
            #expect(abs(camera.x - subject!.x) < halfCrop * 0.5)
        }
        #expect(path.last!.x > 0.7)
    }

    @Test func stepActionRoundTripsThroughCodable() throws {
        let action = StepAction.reframe(format: .square, followSubject: false)
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(StepAction.self, from: data) == action)
    }
}
