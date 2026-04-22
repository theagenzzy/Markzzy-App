import AVFoundation
import Foundation

/// Knobs that decide which capture devices show up in the UI pickers.
/// Owned by AppModel; persisted in UserDefaults.
public struct DeviceFilter: Equatable {
    /// When false (default) we hide common third-party "virtual cameras" and
    /// audio loopbacks because they clutter the picker for users who never
    /// touch them. Power users can flip this in Settings.
    public var hideVirtualDevices: Bool
    /// User-curated set of device IDs to hide regardless of the toggle above.
    public var hiddenDeviceIDs: Set<String>

    public init(hideVirtualDevices: Bool = true,
                hiddenDeviceIDs: Set<String> = []) {
        self.hideVirtualDevices = hideVirtualDevices
        self.hiddenDeviceIDs = hiddenDeviceIDs
    }

    /// Substrings (case-insensitive) we consider "virtual". These are by far
    /// the noisiest offenders for screen-recorder users — virtual cams from
    /// streaming/conferencing apps and audio loopback drivers.
    static let virtualKeywords: [String] = [
        "obs", "manycam", "epoccam", "camo", "snap camera", "snapchat",
        "ndi", "mmhmm", "loopback", "blackhole", "soundflower",
        "aggregate device", "multi-output device", "virtual"
    ]

    public func isHidden(_ device: AVCaptureDevice) -> Bool {
        if hiddenDeviceIDs.contains(device.uniqueID) { return true }
        if hideVirtualDevices, Self.looksVirtual(device) { return true }
        return false
    }

    public static func looksVirtual(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return virtualKeywords.contains(where: { name.contains($0) })
    }
}
