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
                 layout: .pipOverlay, screenFit: .fit)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1440)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 900)
    }

    func testSplitScreenTopLayout_verticalCanvas() {
        let base = makePixelBuffer(width: 1440, height: 900, color: (100, 100, 100))
        let cam = makePixelBuffer(width: 640, height: 480, color: (200, 0, 0))
        let out = makeOutputBuffer(width: 1080, height: 1920)
        let c = PIPCompositor()
        c.render(screen: base, camera: cam, into: out,
                 layout: .splitScreenTop, screenFit: .fill)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 1920)
    }

    func testCameraOnlyLayout_squareCanvas() {
        let cam = makePixelBuffer(width: 640, height: 480, color: (0, 200, 0))
        let out = makeOutputBuffer(width: 1080, height: 1080)
        let c = PIPCompositor()
        c.render(screen: nil, camera: cam, into: out,
                 layout: .cameraOnly, screenFit: .fit)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 1080)
    }

    func testScreenOnlyLayout_respectsScreenFit() {
        let base = makePixelBuffer(width: 1440, height: 900, color: (50, 50, 200))
        let out = makeOutputBuffer(width: 1080, height: 1920)
        let c = PIPCompositor()
        for fit in ScreenFit.allCases {
            c.render(screen: base, camera: nil, into: out,
                     layout: .screenOnly, screenFit: fit)
            XCTAssertEqual(CVPixelBufferGetWidth(out), 1080, "fit=\(fit)")
            XCTAssertEqual(CVPixelBufferGetHeight(out), 1920, "fit=\(fit)")
        }
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
