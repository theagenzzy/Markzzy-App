import AVFoundation

public enum AudioCapture {
    public static func listDevices(filter: DeviceFilter = DeviceFilter()) -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.filter { !filter.isHidden($0) }
    }

    public static func listAllDevices() -> [AVCaptureDevice] {
        listDevices(filter: DeviceFilter(hideVirtualDevices: false, hiddenDeviceIDs: []))
    }

    public static func makeInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        try AVCaptureDeviceInput(device: device)
    }
}
