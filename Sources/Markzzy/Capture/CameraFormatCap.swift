import AVFoundation
import CoreMedia

/// Caps the resolution of EXTERNAL cameras (iPhone Continuity, USB webcams).
///
/// `AVCaptureSession.sessionPreset` is only a hint and external cameras ignore
/// it — a Continuity Camera happily delivers 1920×1440+ frames, which makes the
/// whole pipeline (Vision segmentation + Metal refine + compose) 3–4× heavier
/// and the Mac feels laggy. The built-in FaceTime camera respects the preset and
/// stays light, which is why only the iPhone lags.
///
/// We pin the device's `activeFormat` to the best one under a width cap. Since
/// `activeFormat` belongs to the DEVICE (shared by the preview + recording
/// sessions, which never run at the same time) we use a SMALL cap for the live
/// preview (smooth, no lag) and a LARGER one while recording (keep quality).
enum CameraFormatCap {

    /// True for Continuity Camera / external / USB cams (not the built-in).
    static func isExternal(_ device: AVCaptureDevice) -> Bool {
        if device.deviceType == .continuityCamera || device.deviceType == .external {
            return true
        }
        return device.deviceType != .builtInWideAngleCamera
    }

    /// Pick the best `activeFormat` whose width ≤ `maxWidth` (prefer ~16:9 and the
    /// largest under the cap) AND cap the frame rate to `maxFps` (the iPhone often
    /// runs at 60fps, doubling the per-frame work). No-op for built-in cameras.
    static func apply(to device: AVCaptureDevice, maxWidth: Int, maxFps: Int = 30) {
        guard isExternal(device) else { return }

        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        // Prefer formats that can run AT or below maxFps (so the cap actually
        // sticks), width ≤ maxWidth, ~16:9, largest under the cap.
        func maxRate(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        }
        let under = device.formats.filter { Int(dims($0).width) <= maxWidth }
        let pool = under.isEmpty ? device.formats : under

        func aspectErr(_ f: AVCaptureDevice.Format) -> Double {
            let d = dims(f)
            return abs(Double(d.width) / Double(max(d.height, 1)) - 16.0 / 9.0)
        }
        func area(_ f: AVCaptureDevice.Format) -> Int {
            let d = dims(f); return Int(d.width) * Int(d.height)
        }
        let best = pool.sorted { a, b in
            if abs(aspectErr(a) - aspectErr(b)) > 0.05 { return aspectErr(a) < aspectErr(b) }
            return area(a) > area(b)
        }.first
        guard let best else { return }
        do {
            try device.lockForConfiguration()
            if best !== device.activeFormat { device.activeFormat = best }
            // Cap fps: clamp the min/max frame duration to maxFps if the active
            // format supports it.
            let target = CMTime(value: 1, timescale: Int32(maxFps))
            if best.videoSupportedFrameRateRanges.contains(where: {
                CMTimeCompare($0.minFrameDuration, target) <= 0
                    && CMTimeCompare(target, $0.maxFrameDuration) <= 0
            }) {
                device.activeVideoMinFrameDuration = target
                device.activeVideoMaxFrameDuration = target
            }
            device.unlockForConfiguration()
            let d = dims(best)
            PerfLog.log("CAM-CAP: \(device.localizedName) → \(d.width)x\(d.height) @≤\(maxFps)fps (cap \(maxWidth)w)")
        } catch {
            PerfLog.log("CAM-CAP: lockForConfiguration failed for \(device.localizedName)")
        }
    }
}
