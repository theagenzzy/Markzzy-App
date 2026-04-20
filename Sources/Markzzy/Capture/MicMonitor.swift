import AVFoundation
import CoreMedia

/// Lightweight audio level monitor: runs its own AVCaptureSession when a mic is
/// selected (and the app isn't recording), computes an RMS amplitude from each
/// sample buffer and reports it via `onLevel`. The caller pauses this before
/// starting the real recording pipeline so we don't contend for the device.
final class MicMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onLevel: ((Float) -> Void)?

    private let session = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "markzzy.micmonitor")
    private var wired = false

    func start(with device: AVCaptureDevice) {
        stop()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {}
        if !wired {
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
                wired = true
            }
        }
        session.commitConfiguration()
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        if let i = currentInput {
            session.removeInput(i)
            currentInput = nil
        }
        session.commitConfiguration()
        onLevel?(0)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee
        else { return }

        var length: Int = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0,
                                    lengthAtOffsetOut: nil,
                                    totalLengthOut: &length,
                                    dataPointerOut: &ptr)
        guard let raw = ptr, length > 0 else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var sum: Double = 0
        var count = 0
        if isFloat {
            let n = length / MemoryLayout<Float>.size
            raw.withMemoryRebound(to: Float.self, capacity: n) { fp in
                for i in 0..<n { sum += Double(fp[i]) * Double(fp[i]) }
            }
            count = n
        } else {
            let n = length / MemoryLayout<Int16>.size
            raw.withMemoryRebound(to: Int16.self, capacity: n) { ip in
                for i in 0..<n {
                    let s = Double(ip[i]) / 32768.0
                    sum += s * s
                }
            }
            count = n
        }
        guard count > 0 else { return }
        let rms = sqrt(sum / Double(count))
        // A small amplification + cap so small voices still register visibly.
        let level = Float(min(max(rms * 2.5, 0), 1))
        onLevel?(level)
    }
}
