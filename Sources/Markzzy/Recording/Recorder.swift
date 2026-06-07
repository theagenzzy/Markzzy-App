import AVFoundation
import CoreVideo
import CoreImage

public final class Recorder {
    public struct Config {
        public let width: Int
        public let height: Int
        public let fps: Int
        public let bitrate: Int
        public let output: URL
        public let includesAudio: Bool

        public init(width: Int, height: Int, fps: Int = 30,
                    bitrate: Int = 8_000_000, output: URL, includesAudio: Bool = true) {
            self.width = width; self.height = height; self.fps = fps
            self.bitrate = bitrate; self.output = output; self.includesAudio = includesAudio
        }
    }

    public enum Err: Error { case alreadyStarted, notStarted, writerFail(String) }

    private let config: Config
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private let queue = DispatchQueue(label: "markzzy.recorder")
    private var frameCount: Int = 0

    /// Single lock that serializes ALL writer access — appends, startSession,
    /// markAsFinished, etc. This is the only correct way to avoid the
    /// "appendSampleBuffer in non-writing state" abort on macOS, because
    /// AVAssetWriterInput throws an NSException (uncatchable from Swift) if the
    /// state changes mid-call. Hold this lock around every interaction with
    /// the writer/inputs and the lock guarantees the state is consistent.
    private let writerLock = NSLock()
    private var stopped: Bool = false

    /// Pause/resume implementation. While paused, all incoming samples are
    /// dropped. On resume, `pausedDuration` accumulates so we can shift the PTS
    /// of subsequent samples — this avoids a black/silent gap in the output and
    /// keeps audio/video in sync. Uses the same writerLock for consistency.
    private var paused: Bool = false
    private var pausedAt: CMTime = .invalid
    private var pausedDuration: CMTime = .zero

    public var isPaused: Bool {
        writerLock.lock(); defer { writerLock.unlock() }
        return paused
    }

    public func pause() {
        writerLock.lock(); defer { writerLock.unlock() }
        guard !paused else { return }
        paused = true
        pausedAt = CMClockGetTime(CMClockGetHostTimeClock())
    }

    public func resume() {
        writerLock.lock(); defer { writerLock.unlock() }
        guard paused else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let delta = CMTimeSubtract(now, pausedAt)
        pausedDuration = CMTimeAdd(pausedDuration, delta)
        pausedAt = .invalid
        paused = false
    }

    public init(config: Config) { self.config = config }

    public func start() throws {
        guard writer == nil else { throw Err.alreadyStarted }
        try? FileManager.default.removeItem(at: config.output)

        let w = try AVAssetWriter(outputURL: config.output, fileType: .mp4)

        // Bitrate = professional "master" level, derived from
        // resolution + fps, NOT a flat tier. A screen recording is
        // high-detail (text, scrolling) and gets re-compressed again by
        // YouTube/TikTok — the local file must be generously
        // over-provisioned or it looks soft/blocky vs a native upload.
        // The old flat 8 Mbps (medium @1080p) was the root of "doesn't
        // look like the quality it says".
        //
        // Reference: 24 Mbps for 1080p30 (medium). Scales linearly with
        // pixel area and fps; the low/medium/high tier becomes a
        // multiplier (≈0.6 / 1.0 / 1.6) inferred from the tier's legacy
        // bitrate. Targets: 720p≈11 · 1080p≈24 · 1440p≈43 · 4K≈80 Mbps.
        let pixels = Double(config.width * config.height)
        let refPixels = Double(1920 * 1080)
        let areaFactor = pixels / refPixels
        let fpsFactor = Double(max(config.fps, 1)) / 30.0
        let tierFactor: Double = config.bitrate <= 5_000_000 ? 0.6
                               : config.bitrate <= 11_000_000 ? 1.0
                               : 1.6
        let base1080p30 = 24_000_000.0
        let target = base1080p30 * areaFactor * fpsFactor * tierFactor
        let scaledBitrate = min(max(Int(target), 6_000_000), 80_000_000)

        // Tag the file Rec.709 so the sRGB pixels SCStream gives us are
        // interpreted correctly by every player (otherwise wide-gamut
        // screens record washed-out / desaturated).
        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: scaledBitrate,
                AVVideoMaxKeyFrameIntervalKey: config.fps * 2
            ]
        ]
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        v.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: v,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: config.width,
                kCVPixelBufferHeightKey as String: config.height
            ]
        )
        guard w.canAdd(v) else { throw Err.writerFail("cannot add video") }
        w.add(v)

        if config.includesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); self.audioInput = a }
        }

        guard w.startWriting() else {
            throw Err.writerFail(w.error?.localizedDescription ?? "startWriting failed")
        }

        self.writer = w
        self.videoInput = v
        self.pixelAdaptor = adaptor
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        writerLock.lock()
        defer { writerLock.unlock() }
        if stopped { return }
        guard let writer, writer.status == .writing,
              let videoInput, let adaptor = pixelAdaptor else { return }
        if paused { return }
        let adjustedPts = pausedDuration == .zero ? pts : CMTimeSubtract(pts, pausedDuration)
        if startTime == nil {
            // startSession MUST happen before publishing startTime to other
            // threads, otherwise audio sees startTime != nil and tries to
            // append before the session is open → NSException.
            writer.startSession(atSourceTime: adjustedPts)
            startTime = adjustedPts
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: adjustedPts)
        frameCount += 1
    }

    public func appendAudio(_ sample: CMSampleBuffer) {
        writerLock.lock()
        defer { writerLock.unlock() }
        if stopped { return }
        guard let writer, writer.status == .writing,
              let audioInput,
              let start = startTime else { return }
        if paused { return }
        guard audioInput.isReadyForMoreMediaData else { return }

        let rawPts = CMSampleBufferGetPresentationTimeStamp(sample)
        // Common case (never paused): no rewrite. Avoids unnecessary work AND
        // sidesteps the format/DTS hazards of CMSampleBufferCreateCopyWithNewTiming
        // for audio buffers (which historically caused -[AVAssetWriterInput
        // appendSampleBuffer:] to throw).
        if pausedDuration == .zero {
            if CMTimeCompare(rawPts, start) < 0 { return }
            audioInput.append(sample)
            return
        }

        let adjustedPts = CMTimeSubtract(rawPts, pausedDuration)
        if CMTimeCompare(adjustedPts, start) < 0 { return }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: adjustedPts,
            decodeTimeStamp: .invalid
        )
        var adjustedSample: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjustedSample
        )
        guard status == noErr, let out = adjustedSample else { return }
        audioInput.append(out)
    }

    public func stop() async throws -> URL {
        // Capture the writer + flip the stopped flag under the writer lock
        // so any in-flight append on another queue sees `stopped` before we
        // call markAsFinished + finishWriting. This is what makes the
        // "audio sample arrives after stop" race safe.
        writerLock.lock()
        guard let writer else {
            writerLock.unlock()
            throw Err.notStarted
        }
        stopped = true
        let wroteFrames = (startTime != nil) && frameCount > 0
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writerLock.unlock()

        await writer.finishWriting()
        let status = writer.status
        let werr = writer.error
        let url = config.output
        writerLock.lock()
        self.writer = nil
        writerLock.unlock()

        // Surface a clear failure instead of returning a path to a broken/empty
        // file (e.g. stopped during the camera warm-up before any frame was
        // written). The caller always restores the camera regardless.
        if status == .failed {
            throw Err.writerFail(werr?.localizedDescription ?? "finishWriting failed")
        }
        guard wroteFrames else {
            throw Err.writerFail("no frames recorded")
        }
        return url
    }

    public var writtenFrames: Int { frameCount }
}
