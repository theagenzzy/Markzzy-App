import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

public struct ScreenSource: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let width: Int
    public let height: Int
    let display: SCDisplay?
    let window: SCWindow?

    public func hash(into h: inout Hasher) { h.combine(id) }
    public static func == (a: ScreenSource, b: ScreenSource) -> Bool { a.id == b.id }

    /// Title without the trailing "(2880×1800)" dims — e.g. "Display 1".
    /// The picker names *which* display; the capture badge states *what* is
    /// captured, so the resolution lives in one place, not two.
    public var shortTitle: String {
        title.replacingOccurrences(of: #"\s*\(\d+×\d+\)$"#,
                                   with: "", options: .regularExpression)
    }
}

public enum ScreenCapture {
    public static func listSources() async -> [ScreenSource] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displays = content.displays.map { d in
                // SCDisplay.width/height are LOGICAL POINTS, not pixels.
                // On a Retina display (2× backing scale) a 1440×900
                // screen has a 2880×1800 framebuffer. Capturing at the
                // point size means SCStream renders the screen at half
                // resolution → icons/text are blurry once composed onto
                // the canvas. Use the real framebuffer pixel size so
                // the capture is pixel-faithful to what's on screen.
                let (pxW, pxH) = nativePixelSize(displayID: d.displayID,
                                                 fallback: (d.width, d.height))
                return ScreenSource(
                    id: "display-\(d.displayID)",
                    title: "Display \(d.displayID) (\(pxW)×\(pxH))",
                    width: pxW, height: pxH,
                    display: d, window: nil
                )
            }
            return displays
        } catch {
            return []
        }
    }

    /// True framebuffer pixel resolution for a display. `CGDisplayMode`
    /// pixel width/height reflect the actual backing store (Retina 2×,
    /// scaled HiDPI modes, etc.), unlike SCDisplay's logical points.
    static func nativePixelSize(displayID: CGDirectDisplayID,
                                fallback: (Int, Int)) -> (Int, Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return fallback }
        let w = mode.pixelWidth
        let h = mode.pixelHeight
        guard w > 0, h > 0 else { return fallback }
        return (w, h)
    }

    public static func makeStream(for source: ScreenSource,
                                  output: SCStreamOutput,
                                  queue: DispatchQueue,
                                  canvasSize: CGSize? = nil,
                                  fps: Int = 24,
                                  excludeWindowID: CGWindowID? = nil) async throws -> SCStream {
        guard let display = source.display else {
            throw NSError(domain: "Markzzy.ScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Only display sources supported in MVP"])
        }
        // Exclude the floating camera bubble from OUR recording only (so it's
        // never duplicated in the file), while keeping it visible to normal
        // macOS screenshots — that's why we use SCContentFilter exclusion here
        // instead of NSWindow.sharingType = .none (which hides it everywhere).
        var excluded: [SCWindow] = []
        if let id = excludeWindowID {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let w = content.windows.first(where: { $0.windowID == id }) {
                excluded = [w]
                PerfLog.log("CAPTURE: excluding floating-cam window \(id) from recording")
            } else {
                PerfLog.log("CAPTURE: ⚠️ floating-cam window \(id) NOT found to exclude")
            }
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        // Cap at min(source, canvas) so we NEVER ask SCStream to
        // upscale at the OS level — that's wasted WindowServer
        // bandwidth and the single biggest contributor to "VSCode
        // lags while recording".
        let (capW, capH) = streamDimensions(for: source, canvasSize: canvasSize)
        config.width = capW
        config.height = capH
        let cv = canvasSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        PerfLog.log("CAPTURE: nativePx=\(source.width)x\(source.height)  canvas=\(cv)  scStreamCapture=\(capW)x\(capH)")
        // OBS trick: request slightly faster than target FPS (×0.9) so
        // SCStream doesn't fall short of the rate at boundaries — it
        // tends to deliver at MOST our requested rate, never above.
        // Asking for 27fps when we want 24 ensures we hit 24 reliably.
        let intervalNanos = Int64(1_000_000_000.0 * 0.9 / Double(fps))
        config.minimumFrameInterval = CMTime(value: intervalNanos, timescale: 1_000_000_000)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Force a consistent sRGB capture. Mac displays are wide-gamut
        // (Display P3); without this SCStream hands us P3-encoded pixels
        // that, written to an untagged H.264 file, get read back as
        // Rec.709 → washed-out / desaturated video. Pinning sRGB here +
        // tagging the file Rec.709 (Recorder) makes colors match the
        // screen on every player (QuickTime, browsers, TikTok/YouTube).
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        // queueDepth = 3. The compose pipeline is now clock-driven and
        // holds the latest screen buffer across ticks; SCStream needs
        // free surfaces to write into while we hold one (depth 2 risked
        // a stall / surface reuse → torn or black screen). Depth no
        // longer adds latency to our OUTPUT — the render clock always
        // reads the NEWEST buffer regardless of how deep the queue is —
        // so the old "deep queue = input lag" tradeoff doesn't apply.
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        return stream
    }

    /// Picks SCStream capture dimensions.
    ///
    /// Capture at the resolution we actually encode (driven by the
    /// user's resolution picker via `canvasSize`), capped at the
    /// source display's native resolution — asking SCStream to upscale
    /// is pure wasted WindowServer bandwidth for zero quality gain.
    ///
    /// The old hard 1280 (720p) cap was a workaround for the typing
    /// lag, which is now fixed architecturally (featherweight SC
    /// handler, ~1.3ms Metal compose, clock-driven output). Performance
    /// Mode remains the escape hatch: it forces the `.hd720` tier
    /// upstream, so weak machines / maximum responsiveness still get a
    /// light 720p capture.
    static func streamDimensions(for source: ScreenSource,
                                 canvasSize: CGSize?) -> (Int, Int) {
        let srcAspect = CGFloat(source.width) / CGFloat(max(source.height, 1))

        // Target long side = what we'll encode (canvas), falling back to
        // the source if no canvas was provided.
        let canvasLong: CGFloat
        if let c = canvasSize {
            canvasLong = max(c.width, c.height)
        } else {
            canvasLong = CGFloat(max(source.width, source.height))
        }
        let srcLong = CGFloat(max(source.width, source.height))
        // Never upscale at the OS level — cap at native source res.
        let targetLong = Int(min(canvasLong, srcLong).rounded())

        var w: Int, h: Int
        if source.width >= source.height {
            w = min(source.width, targetLong)
            h = Int(CGFloat(w) / srcAspect)
        } else {
            h = min(source.height, targetLong)
            w = Int(CGFloat(h) * srcAspect)
        }
        // Even dims for H.264 encoder.
        return (max(2, w & ~1), max(2, h & ~1))
    }
}
