import AVFoundation
import CoreGraphics

public final class Permissions {
    public init() {}

    public func requestAll() async {
        _ = await requestCamera()
        _ = await requestMicrophone()
        _ = requestScreen()
    }

    public func requestCamera() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
        }
    }

    public func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    @discardableResult
    public func requestScreen() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
