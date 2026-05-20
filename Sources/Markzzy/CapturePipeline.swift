import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage
import CoreVideo
import IOSurface

public final class CapturePipeline: NSObject, @unchecked Sendable {
    private let source: ScreenSource
    private let camera: AVCaptureDevice?
    private let microphone: AVCaptureDevice?
    private let compositor: PIPCompositor
    /// Optional Metal-based compositor. When non-nil, used in place of
    /// the CIImage `compositor` for the per-frame render. ~5-10× faster
    /// per frame on Apple Silicon, eliminates the GPU contention that
    /// causes typing lag in other apps during recording.
    private let metalCompositor: MetalCompositor?
    private let recorder: Recorder
    private let format: OutputFormat
    private let layout: Layout
    private let screenAnchor: ScreenAnchor
    private let canvasSize: CGSize
    private let queue = DispatchQueue(label: "markzzy.pipeline.sc")
    private let camQueue = DispatchQueue(label: "markzzy.pipeline.cam")
    private let audioQueue = DispatchQueue(label: "markzzy.pipeline.audio")
    /// Compose + encode happen here, not on the SC handler queue.
    /// Decoupling means the OS-owned SC sample queue never blocks on
    /// our GPU compose work — that's what was making VSCode lag.
    private let composeQueue = DispatchQueue(label: "markzzy.pipeline.compose",
                                             qos: .userInitiated)
    /// Encoder hand-off runs on its own queue so AVAssetWriter's
    /// internal sync (waiting for hardware encoder) doesn't block
    /// the next compose. Pulls another step out of the per-frame hot
    /// path that the SC handler depends on.
    private let encoderQueue = DispatchQueue(label: "markzzy.pipeline.encoder",
                                             qos: .userInitiated)
    /// Backpressure: drop frames at the SC handler if compose is more
    /// than this many frames behind. Same approach OBS/Loom use.
    private var framesInFlight: Int = 0
    private let inFlightLock = NSLock()
    /// 2 frames in flight: one composing, one queued. 1 was too
    /// aggressive — it dropped frames during fast camera motion
    /// (abrupt head/hand movement looked laggy). 2 keeps motion
    /// smooth while still bounding the backlog so the system stays
    /// responsive.
    private static let maxFramesInFlight = 2

    /// Last IOSurface ID we processed. SCStream redelivers the SAME
    /// IOSurface back-to-back when the screen content hasn't changed
    /// (e.g. typing in a small region, idle screen). OBS exploits this
    /// to skip compose+encode entirely on identical frames — for typing
    /// that means ~zero GPU work most frames, eliminating contention
    /// with WindowServer that causes input lag.
    private var lastScreenSurfaceID: IOSurfaceID = 0

    private var scStream: SCStream?
    private let camSession = AVCaptureSession()
    private let camOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var currentCamBuffer: CVPixelBuffer?
    private var camBufferLock = NSLock()
    private var camFrameCount: Int = 0

    // ---- OBS-style fixed-rate compose clock ----
    // ScreenCaptureKit only delivers a frame when the screen content
    // CHANGES. Compositing on those callbacks means the whole output
    // (camera included) is sampled at the screen's change rate — which
    // collapses to 4-10 fps when the screen is relatively static (user
    // talking to camera, reading, thinking). That is THE reason
    // recordings looked like a slideshow while OBS didn't: OBS renders
    // off a fixed clock, pulling the latest screen+camera buffers every
    // tick regardless of screen changes. We do the same here.
    private var currentScreenBuffer: CVPixelBuffer?
    private var screenBufferLock = NSLock()
    private var composeTimer: DispatchSourceTimer?
    private let composeTimerQueue = DispatchQueue(label: "markzzy.pipeline.clock",
                                                  qos: .userInteractive)
    private var targetComposeFps: Int { performanceMode ? 24 : 30 }
    /// Screen-only optimization: when there's no camera and the screen
    /// hasn't changed, skip re-encoding an identical frame (keeps the
    /// typing-lag win — no needless GPU/encoder work while idle).
    private var lastTickScreenSurfaceID: IOSurfaceID = 0

    // ---- Perf diagnostics (written to /tmp/markzzy-perf.log) ----
    private var perfLoggedCamDims = false
    private var perfComposeCount: Int = 0
    private var perfComposeTotalMs: Double = 0
    private var perfDroppedBackpressure: Int = 0
    private var perfScreenFrames: Int = 0
    private var perfScreenDelivered: Int = 0
    private var perfWindowStart = Date()
    private let perfLock = NSLock()

    private var outputPool: CVPixelBufferPool?
    private var handler: SCHandler?
    private var camDelegate: CamDelegate?
    private var audioDelegate: AudioDelegate?

    /// Invoked on each composited output frame (recording resolution). Throttle downstream.
    public var onComposedFrame: ((CVPixelBuffer) -> Void)?

    /// Performance Mode: when true, the pipeline applies aggressive
    /// resource caps — camera locked at 10 fps (vs 15), live preview
    /// frozen during recording (caller skips onComposedFrame). Trade-off
    /// for users on entry-level hardware.
    public let performanceMode: Bool

    public init(screen: ScreenSource,
                camera: AVCaptureDevice?,
                microphone: AVCaptureDevice?,
                pipPosition: CGPoint,
                pipSize: CGFloat,
                pipShape: PIPShape,
                pipBorder: PIPBorder,
                output: URL,
                bitrate: Int = 8_000_000,
                format: OutputFormat = .youtube,
                layout: Layout = .pipOverlay,
                screenAnchor: ScreenAnchor = .center,
                resolution: OutputResolution = .fullHd,
                performanceMode: Bool = false) throws {
        self.performanceMode = performanceMode
        self.source = screen
        self.camera = camera
        self.microphone = microphone
        self.format = format
        self.layout = layout
        self.screenAnchor = screenAnchor
        let size = format.canvasSize(for: screen, resolution: resolution)
        self.canvasSize = size
        // begin() truncates the perf log — must run BEFORE MetalCompositor
        // init so its own METAL-INIT-FAIL diagnostics aren't wiped.
        PerfLog.begin("recording start  layout=\(layout)  canvas=\(Int(size.width))x\(Int(size.height))  camera=\(camera?.localizedName ?? "none")  perfMode=\(performanceMode)")
        self.compositor = PIPCompositor(
            position: pipPosition, size: pipSize,
            shape: pipShape, border: pipBorder
        )
        // Init Metal compositor (returns nil if Metal unavailable, in
        // which case we fall through to the CIImage path).
        self.metalCompositor = MetalCompositor(
            position: pipPosition, size: pipSize,
            shape: pipShape, border: pipBorder
        )
        if metalCompositor == nil {
            print("CapturePipeline: ⚠️ Metal compositor failed to init — falling back to CIImage (5-10× slower per-frame compose)")
            PerfLog.log("COMPOSITOR: ⚠️ Metal FAILED — using CIImage fallback (5-10× slower)")
        } else {
            print("CapturePipeline: ✅ Metal compositor active")
            PerfLog.log("COMPOSITOR: ✅ Metal active")
        }
        self.recorder = Recorder(config: .init(
            width: Int(size.width), height: Int(size.height), fps: 24,
            bitrate: bitrate,
            output: output, includesAudio: microphone != nil
        ))
        super.init()
    }

    public func start() async throws {
        try recorder.start()
        outputPool = Self.makePool(width: Int(canvasSize.width),
                                   height: Int(canvasSize.height))

        camSession.beginConfiguration()
        // .medium (480p) for layouts where camera ends up at a fraction
        // of the canvas (PIP, splits) — 1080p source is wasted there
        // and just adds encoder load. cameraOnly fills the canvas so
        // it gets .high for crisp closeups.
        camSession.sessionPreset = (layout == .cameraOnly) ? .high : .medium
        if let cam = camera {
            try configureCameraIO(cam: cam)
        }
        if let mic = microphone {
            try configureMicIO(mic: mic)
        }
        camSession.commitConfiguration()
        camSession.startRunning()

        // Brief camera warm-up before kicking off SCStream. The very first
        // frames are sometimes dark while AE/AWB converge, but waiting ≥20
        // frames (660ms) felt laggy. 6 frames (~200ms @ 30fps) hits the sweet
        // spot: snappy start with negligible darkness in the mp4. Hard cap 1s.
        if camera != nil {
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                if camFrameSeen() >= 6 { break }
                try? await Task.sleep(nanoseconds: 15_000_000)  // 15 ms
            }
        }

        let handler = SCHandler(owner: self)
        self.handler = handler
        // Pass canvasSize so SCStream caps capture dims to what we'll
        // actually use (no OS-side upscale). Major win for typing lag:
        // smaller framebuffer to copy per frame = less WindowServer
        // pressure = VSCode stays responsive.
        // Let SCStream deliver up to the compose clock rate so fast
        // screen motion (scrolling code, video) is as smooth as the
        // camera. Static screens still cost nothing (SCStream only
        // sends on change; the clock reuses the last buffer).
        let stream = try ScreenCapture.makeStream(for: source, output: handler,
                                                  queue: queue, canvasSize: canvasSize,
                                                  fps: targetComposeFps)
        self.scStream = stream
        try await stream.startCapture()

        // Start the fixed-rate render clock only AFTER the stream is
        // running so the first ticks have a screen buffer to compose.
        startComposeClock()
        PerfLog.log("CLOCK: compose timer started @ \(targetComposeFps) fps")
    }

    public func stop() async throws -> URL {
        stopComposeClock()
        if let s = scStream { try? await s.stopCapture() }
        camSession.stopRunning()
        return try await recorder.stop()
    }

    public func pause() { recorder.pause() }
    public func resume() { recorder.resume() }
    public var isPaused: Bool { recorder.isPaused }

    public func updatePIP(position: CGPoint, size: CGFloat,
                          shape: PIPShape, border: PIPBorder) {
        compositor.update(position: position, size: size, shape: shape, border: border)
        metalCompositor?.update(position: position, size: size, shape: shape, border: border)
    }

    public var frameCount: Int { recorder.writtenFrames }

    /// SC handler is now featherweight: it ONLY caches the latest
    /// screen buffer. Zero compose, zero encode, zero GPU on this path
    /// — so it never competes with WindowServer and typing stays
    /// instant. The actual compositing happens off the fixed-rate
    /// `composeTimer` (see `tickCompose`), OBS-style.
    fileprivate func handleScreenSample(_ sample: CMSampleBuffer) {
        guard let base = CMSampleBufferGetImageBuffer(sample) else { return }
        screenBufferLock.lock()
        currentScreenBuffer = base
        screenBufferLock.unlock()
        perfLock.lock(); perfScreenDelivered += 1; perfLock.unlock()
    }

    private func startComposeClock() {
        let timer = DispatchSource.makeTimerSource(queue: composeTimerQueue)
        let interval = 1.0 / Double(targetComposeFps)
        timer.schedule(deadline: .now() + interval,
                       repeating: interval,
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tickCompose() }
        composeTimer = timer
        timer.resume()
    }

    private func stopComposeClock() {
        composeTimer?.cancel()
        composeTimer = nil
    }

    /// Fixed-rate compose tick (the render clock). Pulls the LATEST
    /// screen + camera buffers — whatever they are right now — and
    /// emits one composited frame. Output fps is constant and
    /// independent of how often the screen changes. This is the OBS
    /// model and the fix for the "everything is a slideshow" problem.
    private func tickCompose() {
        screenBufferLock.lock()
        let screen = currentScreenBuffer
        screenBufferLock.unlock()
        guard let base = screen else { return }  // no screen frame yet

        camBufferLock.lock()
        let overlay = currentCamBuffer
        camBufferLock.unlock()

        let cameraActive = (camera != nil) && (layout != .screenOnly)

        // Screen-only idle optimization: if there's no camera and the
        // screen IOSurface is unchanged since the last tick, the frame
        // would be byte-identical — skip the encode. Keeps idle/typing
        // CPU+GPU near zero. With a camera we always tick (the camera
        // is essentially always moving; that's the whole point).
        if !cameraActive,
           let surface = CVPixelBufferGetIOSurface(base)?.takeUnretainedValue() {
            let id = IOSurfaceGetID(surface)
            if id == lastTickScreenSurfaceID { return }
            lastTickScreenSurfaceID = id
        }

        // Backpressure: skip this tick if compose is still behind.
        perfLock.lock(); perfScreenFrames += 1; perfLock.unlock()
        inFlightLock.lock()
        if framesInFlight >= Self.maxFramesInFlight {
            inFlightLock.unlock()
            perfLock.lock(); perfDroppedBackpressure += 1; perfLock.unlock()
            return
        }
        framesInFlight += 1
        inFlightLock.unlock()

        guard let pool = outputPool else { decrementInFlight(); return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let outBuffer = out else { decrementInFlight(); return }

        // PTS on the host-time clock — the SAME clock AVCapture audio
        // samples use — so A/V stays in sync even though video is now
        // clock-driven instead of screen-sample-driven.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())

        let recorderRef = self.recorder
        let compositorRef = self.compositor
        let metalRef = self.metalCompositor
        let layoutCopy = self.layout
        let anchorCopy = self.screenAnchor
        let onComposed = self.onComposedFrame
        let encoderQ = self.encoderQueue
        composeQueue.async { [weak self] in
            defer { self?.decrementInFlight() }
            let t0 = DispatchTime.now()
            if let metal = metalRef {
                metal.render(screen: base, camera: overlay, into: outBuffer,
                             layout: layoutCopy, screenAnchor: anchorCopy)
            } else {
                compositorRef.render(screen: base, camera: overlay, into: outBuffer,
                                     layout: layoutCopy, screenAnchor: anchorCopy)
            }
            self?.recordComposeTiming(t0)
            encoderQ.async {
                recorderRef.appendVideo(outBuffer, pts: pts)
                onComposed?(outBuffer)
            }
        }
    }

    private func recordComposeTiming(_ start: DispatchTime) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        perfLock.lock()
        perfComposeCount += 1
        perfComposeTotalMs += ms
        let elapsed = Date().timeIntervalSince(perfWindowStart)
        if elapsed >= 2.0 {
            let n = perfComposeCount
            let avg = n > 0 ? perfComposeTotalMs / Double(n) : 0
            let composedFps = Double(n) / elapsed
            let tickFps = Double(perfScreenFrames) / elapsed
            let scDeliveredFps = Double(perfScreenDelivered) / elapsed
            let dropped = perfDroppedBackpressure
            perfComposeCount = 0; perfComposeTotalMs = 0
            perfScreenFrames = 0; perfDroppedBackpressure = 0
            perfScreenDelivered = 0
            perfWindowStart = Date()
            perfLock.unlock()
            PerfLog.log(String(format:
                "PERF: compose avg=%.1fms  outputFps=%.1f  tickFps=%.1f  scStreamDeliveredFps=%.1f  droppedBackpressure=%d",
                avg, composedFps, tickFps, scDeliveredFps, dropped))
        } else {
            perfLock.unlock()
        }
    }

    private func decrementInFlight() {
        inFlightLock.lock()
        framesInFlight = max(0, framesInFlight - 1)
        inFlightLock.unlock()
    }

    private func configureCameraIO(cam: AVCaptureDevice) throws {
        let input = try CameraCapture.makeInput(for: cam)
        if camSession.canAddInput(input) { camSession.addInput(input) }
        camOut.alwaysDiscardsLateVideoFrames = true
        camOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let delegate = CamDelegate(owner: self)
        self.camDelegate = delegate
        camOut.setSampleBufferDelegate(delegate, queue: camQueue)
        if camSession.canAddOutput(camOut) { camSession.addOutput(camOut) }

        // Camera fps: 30 default, 24 in Performance Mode. An earlier
        // 15/10 fps lock made talking-head footage visibly choppy
        // (especially Reel splits where the camera fills half the
        // canvas) — that degraded the CORE face-cam feature for a
        // marginal perf gain (camera capture is cheap vs screen
        // capture). The real perf wins are Metal compose +
        // frame-change-detection, not throttling the camera.
        do {
            try cam.lockForConfiguration()
            let targetFps: Int32 = performanceMode ? 24 : 30
            let target = CMTime(value: 1, timescale: targetFps)
            let ranges = cam.activeFormat.videoSupportedFrameRateRanges
            if ranges.contains(where: { CMTimeCompare($0.minFrameDuration, target) <= 0
                                       && CMTimeCompare(target, $0.maxFrameDuration) <= 0 }) {
                cam.activeVideoMinFrameDuration = target
                cam.activeVideoMaxFrameDuration = target
            }
            cam.unlockForConfiguration()
        } catch {
            // Best-effort; camera continues at default rate if it fails.
        }
    }

    private func configureMicIO(mic: AVCaptureDevice) throws {
        let input = try AudioCapture.makeInput(for: mic)
        if camSession.canAddInput(input) { camSession.addInput(input) }
        let delegate = AudioDelegate(owner: self)
        self.audioDelegate = delegate
        audioOut.setSampleBufferDelegate(delegate, queue: audioQueue)
        if camSession.canAddOutput(audioOut) { camSession.addOutput(audioOut) }
    }

    private func camFrameSeen() -> Int {
        camBufferLock.lock()
        defer { camBufferLock.unlock() }
        return camFrameCount
    }

    fileprivate func handleCamSample(_ sample: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        if !perfLoggedCamDims {
            perfLoggedCamDims = true
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            let fcc = String(format: "%c%c%c%c",
                             (fmt >> 24) & 0xff, (fmt >> 16) & 0xff,
                             (fmt >> 8) & 0xff, fmt & 0xff)
            PerfLog.log("CAMERA: first buffer \(w)x\(h) fmt=\(fcc)")
        }
        camBufferLock.lock()
        currentCamBuffer = pb
        camFrameCount += 1
        camBufferLock.unlock()
    }

    fileprivate func handleAudioSample(_ sample: CMSampleBuffer) {
        recorder.appendAudio(sample)
    }

    static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            // Tag composited buffers sRGB so the H.264 encoder does the
            // RGB→YCbCr conversion against the right color space — keeps
            // the file's colors matching the screen end-to-end.
            kCVImageBufferCGColorSpaceKey as String:
                CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        return pool
    }
}

private final class SCHandler: NSObject, SCStreamOutput {
    weak var owner: CapturePipeline?
    init(owner: CapturePipeline) { self.owner = owner }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        owner?.handleScreenSample(sampleBuffer)
    }
}

private final class CamDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: CapturePipeline?
    init(owner: CapturePipeline) { self.owner = owner }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        owner?.handleCamSample(sampleBuffer)
    }
}

private final class AudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var owner: CapturePipeline?
    init(owner: CapturePipeline) { self.owner = owner }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        owner?.handleAudioSample(sampleBuffer)
    }
}
