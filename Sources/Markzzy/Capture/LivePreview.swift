import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import CoreGraphics
import QuartzCore

/// Low-res SCStream that calls `onFrame` with a throttled CGImage of the
/// selected screen. Used for the UI preview when NOT recording.
final class LivePreview: NSObject, SCStreamOutput, @unchecked Sendable {
    var onFrame: ((CGImage) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "markzzy.preview.sc")
    private let ci = CIContext()
    private var lastEmit: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 1.0 / 20.0
    private let lock = NSLock()

    func start(for source: ScreenSource) async {
        await stop()
        guard let display = source.display else { return }
        // Exclude our own app so the preview never shows an infinite mirror
        // of Markzzy capturing itself capturing itself…
        let selfApps: [SCRunningApplication] = await {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                let myBundle = Bundle.main.bundleIdentifier
                return content.applications.filter {
                    $0.bundleIdentifier == myBundle
                }
            } catch { return [] }
        }()
        let filter = SCContentFilter(display: display,
                                     excludingApplications: selfApps,
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        let maxDim = 720
        let aspect = Double(source.width) / Double(max(source.height, 1))
        if aspect >= 1 {
            config.width = maxDim
            config.height = Int(Double(maxDim) / aspect)
        } else {
            config.height = maxDim
            config.width = Int(Double(maxDim) * aspect)
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
        } catch {
            // best-effort preview
        }
    }

    func stop() async {
        if let s = stream {
            try? await s.stopCapture()
            stream = nil
        }
    }

    /// Forward an already-composited buffer (from the recording pipeline) into the preview.
    func push(_ pixelBuffer: CVPixelBuffer) {
        convert(pixelBuffer)
    }

    private func convert(_ pb: CVPixelBuffer) {
        lock.lock()
        let now = CACurrentMediaTime()
        if now - lastEmit < minInterval { lock.unlock(); return }
        lastEmit = now
        lock.unlock()

        let image = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(image, from: image.extent) else { return }
        onFrame?(cg)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        convert(pb)
    }
}
