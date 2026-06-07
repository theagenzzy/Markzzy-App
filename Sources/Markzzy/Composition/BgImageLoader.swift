import Foundation
import CoreVideo
import CoreImage
import AppKit

/// Loads a user-picked background image file into a BGRA `CVPixelBuffer` (scaled
/// down to a sane size) for the compositors to aspect-fill behind the person.
enum BgImageLoader {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func pixelBuffer(from url: URL, maxWidth: Int = 1920) -> CVPixelBuffer? {
        guard let ns = NSImage(contentsOf: url),
              let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let ci = CIImage(bitmapImageRep: rep) else { return nil }
        let ext = ci.extent
        guard ext.width > 0, ext.height > 0 else { return nil }
        let scale = min(1.0, CGFloat(maxWidth) / ext.width)
        let w = max(16, Int(ext.width * scale))
        let h = max(16, Int(ext.height * scale))
        let scaled = ci
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let out = pb else { return nil }
        let origin = scaled.extent.origin
        ciContext.render(scaled.transformed(by: CGAffineTransform(translationX: -origin.x,
                                                                  y: -origin.y)),
                         to: out)
        return out
    }
}
