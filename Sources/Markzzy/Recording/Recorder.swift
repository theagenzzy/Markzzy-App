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

    public init(config: Config) { self.config = config }

    public func start() throws {
        guard writer == nil else { throw Err.alreadyStarted }
        try? FileManager.default.removeItem(at: config.output)

        let w = try AVAssetWriter(outputURL: config.output, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.bitrate,
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
        guard let writer, let videoInput, let adaptor = pixelAdaptor else { return }
        if startTime == nil {
            startTime = pts
            writer.startSession(atSourceTime: pts)
        }
        if videoInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: pts)
            frameCount += 1
        }
    }

    public func appendAudio(_ sample: CMSampleBuffer) {
        // Drop samples that arrive before the video session has started —
        // AVAssetWriter will abort if we append before startSession(atSourceTime:).
        guard startTime != nil else { return }
        // Also drop samples whose PTS is before the session start (pre-roll).
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if let start = startTime, CMTimeCompare(pts, start) < 0 { return }
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    public func stop() async throws -> URL {
        guard let writer else { throw Err.notStarted }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        let url = config.output
        self.writer = nil
        return url
    }

    public var writtenFrames: Int { frameCount }
}
