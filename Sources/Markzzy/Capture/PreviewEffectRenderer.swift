import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

/// Produces the live face-cam background-removal effect for the IDLE preview
/// (before recording). The recording path has its own segmenter+compositor in
/// `CapturePipeline`; this is the lightweight mirror so the user sees the real
/// circular/cutout effect in the preview.
///
/// Attached as a delegate to an `AVCaptureVideoDataOutput` on the preview
/// session ONLY while a camera style is active. Throttled and single-flight so
/// it never backs up (same philosophy as `LivePreview`).
public final class PreviewEffectRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// Emitted on the main queue with the composited camera image + its aspect
    /// (W/H) so the slot can size to a tight silhouette. nil clears the effect.
    public var onFrame: ((CGImage?, CGFloat) -> Void)?

    private let segmenter = PersonSegmenter()
    private let compositor = PIPCompositor()
    private let lock = NSLock()

    // Params (updated from the model).
    private var shape: PIPShape = .circle
    private var freeform = false
    private var split = false
    private var bgMode = 0   // 0=transparent 1=color 2=blur 3=image
    private var bgColor = CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
    private var blurRadius: CGFloat = 0
    private var bgImage: CVPixelBuffer?

    // Throttle ~20fps. `lastEmit` is ONLY advanced after a real image is
    // produced — so while Vision is still warming up (mask nil) every frame
    // retries instead of being gated out. That starvation was the bug that
    // left the preview on the raw-camera fallback.
    private var lastEmit: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 1.0 / 20.0

    public func updateParams(shape: PIPShape, freeform: Bool, bgMode: Int,
                             color: CGColor, blurRadius: CGFloat,
                             image: CVPixelBuffer?, split: Bool) {
        lock.lock()
        self.shape = shape; self.freeform = freeform; self.split = split
        self.bgMode = bgMode; self.bgColor = color
        self.blurRadius = blurRadius; self.bgImage = image
        lock.unlock()
    }

    /// Clear cached state when the effect is turned off.
    public func reset() {
        segmenter.reset()
        lock.lock(); lastEmit = 0; lock.unlock()
        onFrame?(nil, 1)
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Always feed the segmenter (it self-throttles via drop-don't-queue).
        segmenter.submit(pb)

        // Throttle by time only. Critically, do NOT mutate lastEmit before we
        // know there's a usable mask — otherwise warm-up frames burn the budget.
        let now = CACurrentMediaTime()
        lock.lock()
        if now - lastEmit < minInterval { lock.unlock(); return }
        let sh = shape; let ff = freeform; let sp = split
        let mode = bgMode; let color = bgColor; let blurR = blurRadius; let img = bgImage
        lock.unlock()

        // Mask not ready yet (Vision is async). Return WITHOUT advancing the
        // throttle so the next frame retries immediately.
        // Use the matte PAIRED with the frame it was computed from (not `pb`,
        // the latest live frame) so the matte and pixels stay aligned → no
        // background flash on fast motion.
        guard let pair = segmenter.currentMatte() else { return }

        guard let result = compositor.composeCameraOnly(
            camera: pair.frame, mask: pair.mask, shape: sh, freeform: ff, split: sp,
            bgMode: mode, color: color, blurRadius: blurR, image: img
        ) else { return }

        lock.lock(); lastEmit = now; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(result.cgImage, result.aspect)
        }
    }
}
