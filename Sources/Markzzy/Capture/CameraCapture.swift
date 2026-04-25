import AVFoundation

public enum CameraCapture {

    /// Persistent discovery session shared across the app.
    ///
    /// For `.continuityCamera` to actually surface an iPhone, AVFoundation
    /// needs a long-lived discovery session with `.continuityCamera` in
    /// `deviceTypes` — that's what starts the Bonjour-style scan that
    /// wakes nearby iPhones. We also need
    /// `NSCameraUseContinuityCameraDeviceType=YES` in Info.plist (already
    /// set by `scripts/install-to-desktop.sh`) and granted camera TCC.
    ///
    /// Marked `var` (not `let`) so we can `recreate()` it after events
    /// like the user tapping "Disconnect" on the iPhone — that's the only
    /// reliable way to force AVFoundation to restart its dormant
    /// Continuity scanner within the same process lifetime.
    public private(set) static var sharedDiscovery: AVCaptureDevice.DiscoverySession = makeDiscovery()

    private static func makeDiscovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
    }

    /// Builds a fresh discovery session and primes it with one read of
    /// `.devices`. Call from the recovery path; AppModel re-attaches its
    /// KVO to the new instance after.
    @discardableResult
    public static func recreateDiscovery() -> AVCaptureDevice.DiscoverySession {
        sharedDiscovery = makeDiscovery()
        _ = sharedDiscovery.devices
        return sharedDiscovery
    }

    public static func listDevices(filter: DeviceFilter = DeviceFilter()) -> [AVCaptureDevice] {
        sharedDiscovery.devices.filter { !filter.isHidden($0) }
    }

    /// Unfiltered list — used by Settings to manage the hidden set.
    public static func listAllDevices() -> [AVCaptureDevice] {
        sharedDiscovery.devices
    }

    public static func makeInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        try AVCaptureDeviceInput(device: device)
    }
}
