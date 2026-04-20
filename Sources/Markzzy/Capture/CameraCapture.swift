import AVFoundation

public enum CameraCapture {
    public static func listDevices() -> [AVCaptureDevice] {
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
        return session.devices
    }

    public static func makeInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        try AVCaptureDeviceInput(device: device)
    }
}
