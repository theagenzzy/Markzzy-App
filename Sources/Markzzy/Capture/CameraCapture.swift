import AVFoundation

public enum CameraCapture {
    public static func listDevices(filter: DeviceFilter = DeviceFilter()) -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.filter { !filter.isHidden($0) }
    }

    /// Unfiltered list — used by Settings to manage the hidden set.
    public static func listAllDevices() -> [AVCaptureDevice] {
        listDevices(filter: DeviceFilter(hideVirtualDevices: false, hiddenDeviceIDs: []))
    }

    public static func makeInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        try AVCaptureDeviceInput(device: device)
    }
}
