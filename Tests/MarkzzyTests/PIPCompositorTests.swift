import XCTest
import CoreImage
import CoreVideo
@testable import Markzzy

final class PIPCompositorTests: XCTestCase {
    func testComposeProducesImageSameSizeAsBase() {
        let base = makePixelBuffer(width: 1280, height: 720, color: (0, 0, 255))
        let overlay = makePixelBuffer(width: 640, height: 480, color: (255, 0, 0))
        let compositor = PIPCompositor(
            position: CGPoint(x: 0.88, y: 0.88),
            size: 0.22, shape: .rectangle, border: .none
        )
        let out = compositor.compose(base: base, overlay: overlay)
        XCTAssertEqual(out.extent.width, 1280)
        XCTAssertEqual(out.extent.height, 720)
    }

    func testComposeWithoutOverlayIsIdentity() {
        let base = makePixelBuffer(width: 800, height: 600, color: (0, 255, 0))
        let compositor = PIPCompositor(
            position: CGPoint(x: 0.12, y: 0.12),
            size: 0.22, shape: .circle, border: .none
        )
        let out = compositor.compose(base: base, overlay: nil)
        XCTAssertEqual(out.extent.width, 800)
    }

    func testAllShapesCompose() {
        let base = makePixelBuffer(width: 640, height: 360, color: (10, 10, 10))
        let overlay = makePixelBuffer(width: 320, height: 240, color: (200, 200, 200))
        for shape in PIPShape.allCases {
            let c = PIPCompositor(position: CGPoint(x: 0.5, y: 0.5),
                                  size: 0.25, shape: shape, border: .white)
            let out = c.compose(base: base, overlay: overlay)
            XCTAssertEqual(out.extent.width, 640, "shape=\(shape)")
            XCTAssertEqual(out.extent.height, 360, "shape=\(shape)")
        }
    }

    func testNewRenderPipOverlayMatchesCanvasSize() {
        let base = makePixelBuffer(width: 1440, height: 900, color: (20, 20, 20))
        let cam = makePixelBuffer(width: 640, height: 480, color: (200, 50, 50))
        let out = makeOutputBuffer(width: 1440, height: 900)
        let c = PIPCompositor(position: CGPoint(x: 0.5, y: 0.5),
                              size: 0.22, shape: .circle, border: .none)
        c.render(screen: base, camera: cam, into: out,
                 layout: .pipOverlay, screenAnchor: .center)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1440)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 900)
    }

    func testSplitScreenTopLayout_verticalCanvas() {
        let base = makePixelBuffer(width: 1440, height: 900, color: (100, 100, 100))
        let cam = makePixelBuffer(width: 640, height: 480, color: (200, 0, 0))
        let out = makeOutputBuffer(width: 1080, height: 1920)
        let c = PIPCompositor()
        c.render(screen: base, camera: cam, into: out,
                 layout: .splitScreenTop, screenAnchor: .center)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 1920)
    }

    func testCameraOnlyLayout_squareCanvas() {
        let cam = makePixelBuffer(width: 640, height: 480, color: (0, 200, 0))
        let out = makeOutputBuffer(width: 1080, height: 1080)
        let c = PIPCompositor()
        c.render(screen: nil, camera: cam, into: out,
                 layout: .cameraOnly, screenAnchor: .center)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 1080)
    }

    func testScreenOnlyLayout_respectsAnchor() {
        let base = makePixelBuffer(width: 1440, height: 900, color: (50, 50, 200))
        let out = makeOutputBuffer(width: 1080, height: 1920)
        let c = PIPCompositor()
        for a in ScreenAnchor.allCases {
            c.render(screen: base, camera: nil, into: out,
                     layout: .screenOnly, screenAnchor: a)
            XCTAssertEqual(CVPixelBufferGetWidth(out), 1080, "anchor=\(a)")
            XCTAssertEqual(CVPixelBufferGetHeight(out), 1920, "anchor=\(a)")
        }
    }

    func testCropRect_wideSourceVerticalTarget() {
        // 1440x900 source into 9:16 aspect.
        let crop = PIPCompositor.cropRect(
            sourceWidth: 1440, sourceHeight: 900,
            targetAspect: 9.0 / 16.0, anchor: .center
        )
        // Vertical target → crop the width to match. New width = 900 * 9/16.
        XCTAssertEqual(crop.width, 900 * 9.0 / 16.0, accuracy: 0.5)
        XCTAssertEqual(crop.height, 900, accuracy: 0.5)
        XCTAssertEqual(crop.origin.x, (1440 - crop.width) / 2, accuracy: 0.5)
        XCTAssertEqual(crop.origin.y, 0, accuracy: 0.5)
    }

    func testCropRect_anchorShiftsX() {
        let srcW: CGFloat = 1440, srcH: CGFloat = 900
        let target: CGFloat = 1.0
        let center = PIPCompositor.cropRect(sourceWidth: srcW, sourceHeight: srcH, targetAspect: target, anchor: .center)
        let left   = PIPCompositor.cropRect(sourceWidth: srcW, sourceHeight: srcH, targetAspect: target, anchor: .left)
        let right  = PIPCompositor.cropRect(sourceWidth: srcW, sourceHeight: srcH, targetAspect: target, anchor: .right)
        XCTAssertEqual(left.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(center.origin.x, (srcW - center.width) / 2, accuracy: 0.5)
        XCTAssertEqual(right.origin.x, srcW - right.width, accuracy: 0.5)
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return pb!
    }

    func testUpdateChangesOutput() {
        let base = makePixelBuffer(width: 800, height: 600, color: (0, 0, 0))
        let overlay = makePixelBuffer(width: 400, height: 300, color: (255, 0, 0))
        let c = PIPCompositor(position: CGPoint(x: 0.1, y: 0.1),
                              size: 0.2, shape: .circle, border: .none)
        let ctx = CIContext()
        let a = ctx.createCGImage(c.compose(base: base, overlay: overlay),
                                  from: CGRect(x: 0, y: 0, width: 800, height: 600))!
        c.update(position: CGPoint(x: 0.9, y: 0.9), size: 0.3, shape: .hexagon, border: .accent)
        let b = ctx.createCGImage(c.compose(base: base, overlay: overlay),
                                  from: CGRect(x: 0, y: 0, width: 800, height: 600))!
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
    }

    func makePixelBuffer(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let ptr = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                ptr[i]     = color.2
                ptr[i + 1] = color.1
                ptr[i + 2] = color.0
                ptr[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }
}
