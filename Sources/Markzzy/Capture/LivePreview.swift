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
    /// Off-thread queue for the per-frame CGImage build. Without this,
    /// every push() during recording does a full canvas render on the
    /// caller's thread (the recording pipeline's compose queue), adding
    /// GPU work per frame on top of the encoder.
    private let convertQueue = DispatchQueue(label: "markzzy.preview.convert",
                                             qos: .userInitiated)
    private let ci = CIContext()
    private var lastEmit: CFTimeInterval = 0
    /// Soft 20 fps cap when capturing directly (idle preview).
    private let captureMinInterval: CFTimeInterval = 1.0 / 20.0
    /// Tighter 10 fps cap while recording. The MP4 keeps its 24 fps;
    /// this cap is only the small in-app preview window. Halves the
    /// CGImage churn / SwiftUI re-renders during recording — the user
    /// still sees a live updating preview, just at 10 fps instead of
    /// 20-30. Imperceptibly less smooth, much lighter on the system.
    private let recordingMinInterval: CFTimeInterval = 1.0 / 10.0
    /// Single-flight guard. Drops the new frame if a previous CGImage
    /// build is still in progress on convertQueue — keeps preview
    /// latency at ~one frame instead of growing under load.
    private var converting = false
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

    /// Forward a composed buffer from the recording pipeline. Drops if
    /// a previous build is in flight or we're under the 10 fps cap.
    /// CGImage build is dispatched off-thread so the caller (compose
    /// queue) returns immediately.
    func push(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let now = CACurrentMediaTime()
        if converting || now - lastEmit < recordingMinInterval {
            lock.unlock(); return
        }
        converting = true
        lastEmit = now
        lock.unlock()
        // Anchor buffer lifetime via CIImage on caller's thread (CIImage
        // retains the CVPixelBuffer) before the dispatch hop.
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        convertQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.converting = false
                self.lock.unlock()
            }
            guard let cg = self.ci.createCGImage(image, from: image.extent) else { return }
            self.onFrame?(cg)
        }
    }

    private func convert(_ pb: CVPixelBuffer) {
        lock.lock()
        let now = CACurrentMediaTime()
        if now - lastEmit < captureMinInterval { lock.unlock(); return }
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
