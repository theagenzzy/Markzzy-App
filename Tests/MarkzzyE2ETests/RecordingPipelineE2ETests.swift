import XCTest
import AVFoundation
import CoreImage
import CoreVideo
@testable import Markzzy

/// End-to-end test:
/// Genera 60 frames sintéticos de "pantalla" + 60 de "cámara" + 1 segundo de
/// audio sintético, los empuja por PIPCompositor → Recorder → .mp4, y luego
/// reabre el archivo con AVAsset para verificar:
///   - el archivo existe y es legible
///   - tiene pista de video con las dimensiones esperadas
///   - tiene pista de audio
///   - duración ≈ 2 segundos
final class RecordingPipelineE2ETests: XCTestCase {

    func testFullPipelineProducesValidMP4() async throws {
        let width = 640
        let height = 360
        let fps = 30
        let totalFrames = 60
        let pipSize = 160

        let out = tempURL(name: "markzzy-e2e.mp4")
        let recorder = Recorder(config: .init(
            width: width, height: height, fps: fps, output: out, includesAudio: true
        ))
        try recorder.start()

        let compositor = PIPCompositor(position: CGPoint(x: 0.88, y: 0.88),
                                       size: 0.25, shape: .rectangle, border: .white)
        let outputPool = CapturePipeline.makePool(width: width, height: height)!

        for i in 0..<totalFrames {
            let hue = Float(i) / Float(totalFrames)
            let screen = makeSolid(width: width, height: height,
                                   r: UInt8(255 * hue), g: 80, b: UInt8(255 * (1 - hue)))
            let cam = makeSolid(width: pipSize, height: pipSize, r: 0, g: 200, b: 50)

            var outBuf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &outBuf)
            XCTAssertNotNil(outBuf)
            compositor.render(base: screen, overlay: cam, into: outBuf!)

            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            recorder.appendVideo(outBuf!, pts: pts)
        }

        appendSyntheticAudio(to: recorder, seconds: 2.0)

        let savedURL = try await recorder.stop()
        XCTAssertEqual(savedURL, out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        try await assertValidMP4(url: out,
                                 expectedWidth: width,
                                 expectedHeight: height,
                                 expectedMinDuration: 1.8,
                                 expectedMaxDuration: 2.5,
                                 expectsAudio: true)
    }

    func testPipelineWithoutAudioStillWorks() async throws {
        let width = 320, height = 240, frames = 30, fps = 30
        let out = tempURL(name: "markzzy-e2e-noaudio.mp4")
        let recorder = Recorder(config: .init(
            width: width, height: height, fps: fps, output: out, includesAudio: false
        ))
        try recorder.start()

        for i in 0..<frames {
            let buf = makeSolid(width: width, height: height, r: 10, g: UInt8(8 * i), b: 10)
            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            recorder.appendVideo(buf, pts: pts)
        }
        _ = try await recorder.stop()
        try await assertValidMP4(url: out,
                                 expectedWidth: width,
                                 expectedHeight: height,
                                 expectedMinDuration: 0.8,
                                 expectedMaxDuration: 1.2,
                                 expectsAudio: false)
    }

    // MARK: - Helpers

    private func assertValidMP4(url: URL,
                                expectedWidth: Int,
                                expectedHeight: Int,
                                expectedMinDuration: Double,
                                expectedMaxDuration: Double,
                                expectsAudio: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertEqual(videoTracks.count, 1, "should have exactly one video track")
        XCTAssertEqual(audioTracks.isEmpty, !expectsAudio, "audio presence mismatch")
        XCTAssertGreaterThanOrEqual(duration, expectedMinDuration, "duration too short: \(duration)s")
        XCTAssertLessThanOrEqual(duration, expectedMaxDuration, "duration too long: \(duration)s")

        if let video = videoTracks.first {
            let size = try await video.load(.naturalSize)
            XCTAssertEqual(Int(size.width), expectedWidth)
            XCTAssertEqual(Int(size.height), expectedHeight)
        }
    }

    private func appendSyntheticAudio(to recorder: Recorder, seconds: Double) {
        let sampleRate: Double = 44_100
        let channels: UInt32 = 2
        let samplesPerBuffer: Int = 1024
        let totalSamples = Int(sampleRate * seconds)
        var written = 0

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       asbd: &asbd,
                                       layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        guard let formatDesc = format else { return }

        while written < totalSamples {
            let thisBatch = min(samplesPerBuffer, totalSamples - written)
            let byteCount = thisBatch * Int(channels) * 4
            let bytes = UnsafeMutablePointer<Float>.allocate(capacity: thisBatch * Int(channels))
            defer { bytes.deallocate() }
            for s in 0..<thisBatch {
                let t = Double(written + s) / sampleRate
                let v = Float(sin(2 * .pi * 440 * t)) * 0.2
                bytes[s * 2] = v
                bytes[s * 2 + 1] = v
            }

            var blockBuffer: CMBlockBuffer?
            let raw = UnsafeMutableRawPointer(bytes)
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer)
            guard let bb = blockBuffer else { return }
            CMBlockBufferReplaceDataBytes(with: raw, blockBuffer: bb, offsetIntoDestination: 0, dataLength: byteCount)

            let pts = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate))
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: CMTimeValue(thisBatch), timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )
            var sample: CMSampleBuffer?
            var sampleSize: Int = Int(asbd.mBytesPerFrame)
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleCount: CMItemCount(thisBatch),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample)
            if let s = sample { recorder.appendAudio(s) }
            written += thisBatch
        }
    }

    private func makeSolid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                base[i] = b; base[i + 1] = g; base[i + 2] = r; base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func tempURL(name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("markzzy-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
