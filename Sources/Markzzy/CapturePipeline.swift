import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage
import CoreVideo

public final class CapturePipeline: NSObject, @unchecked Sendable {
    private let source: ScreenSource
    private let camera: AVCaptureDevice?
    private let microphone: AVCaptureDevice?
    private let compositor: PIPCompositor
    private let recorder: Recorder
    private let queue = DispatchQueue(label: "markzzy.pipeline.sc")
    private let camQueue = DispatchQueue(label: "markzzy.pipeline.cam")
    private let audioQueue = DispatchQueue(label: "markzzy.pipeline.audio")

    private var scStream: SCStream?
    private let camSession = AVCaptureSession()
    private let camOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var currentCamBuffer: CVPixelBuffer?
    private var camBufferLock = NSLock()

    private var outputPool: CVPixelBufferPool?
    private var handler: SCHandler?
    private var camDelegate: CamDelegate?
    private var audioDelegate: AudioDelegate?

    /// Invoked on each composited output frame (recording resolution). Throttle downstream.
    public var onComposedFrame: ((CVPixelBuffer) -> Void)?

    public init(screen: ScreenSource,
                camera: AVCaptureDevice?,
                microphone: AVCaptureDevice?,
                pipPosition: CGPoint,
                pipSize: CGFloat,
                pipShape: PIPShape,
                pipBorder: PIPBorder,
                output: URL,
                bitrate: Int = 8_000_000) throws {
        self.source = screen
        self.camera = camera
        self.microphone = microphone
        self.compositor = PIPCompositor(
            position: pipPosition, size: pipSize,
            shape: pipShape, border: pipBorder
        )
        self.recorder = Recorder(config: .init(
            width: screen.width, height: screen.height, fps: 30,
            bitrate: bitrate,
            output: output, includesAudio: microphone != nil
        ))
        super.init()
    }

    public func start() async throws {
        try recorder.start()
        outputPool = Self.makePool(width: source.width, height: source.height)

        camSession.beginConfiguration()
        camSession.sessionPreset = .high
        if let cam = camera {
            try configureCameraIO(cam: cam)
        }
        if let mic = microphone {
            try configureMicIO(mic: mic)
        }
        camSession.commitConfiguration()
        camSession.startRunning()

        let handler = SCHandler(owner: self)
        self.handler = handler
        let stream = try ScreenCapture.makeStream(for: source, output: handler, queue: queue)
        self.scStream = stream
        try await stream.startCapture()
    }

    public func stop() async throws -> URL {
        if let s = scStream { try? await s.stopCapture() }
        camSession.stopRunning()
        return try await recorder.stop()
    }

    public func updatePIP(position: CGPoint, size: CGFloat,
                          shape: PIPShape, border: PIPBorder) {
        compositor.update(position: position, size: size, shape: shape, border: border)
    }

    public var frameCount: Int { recorder.writtenFrames }

    fileprivate func handleScreenSample(_ sample: CMSampleBuffer) {
        guard let base = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)

        camBufferLock.lock()
        let overlay = currentCamBuffer
        camBufferLock.unlock()

        guard let pool = outputPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        compositor.render(base: base, overlay: overlay, into: out)
        recorder.appendVideo(out, pts: pts)
        onComposedFrame?(out)
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
    }

    private func configureMicIO(mic: AVCaptureDevice) throws {
        let input = try AudioCapture.makeInput(for: mic)
        if camSession.canAddInput(input) { camSession.addInput(input) }
        let delegate = AudioDelegate(owner: self)
        self.audioDelegate = delegate
        audioOut.setSampleBufferDelegate(delegate, queue: audioQueue)
        if camSession.canAddOutput(audioOut) { camSession.addOutput(audioOut) }
    }

    fileprivate func handleCamSample(_ sample: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        camBufferLock.lock()
        currentCamBuffer = pb
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
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
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
