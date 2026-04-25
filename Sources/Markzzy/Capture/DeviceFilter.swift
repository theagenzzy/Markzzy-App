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
    /// When true, the iPhone-slot binding logic also accepts generic bridge
    /// cameras (Camo Camera, EpocCam HD, …) — useful for users who run a
    /// bridge intentionally and want Markzzy to use the bridge's virtual
    /// camera as the iPhone source. Off by default; surfaced in Settings.
    public var allowVirtualCameras: Bool

    public init(hideVirtualDevices: Bool = true,
                hiddenDeviceIDs: Set<String> = [],
                allowVirtualCameras: Bool = false) {
        self.hideVirtualDevices = hideVirtualDevices
        self.hiddenDeviceIDs = hiddenDeviceIDs
        self.allowVirtualCameras = allowVirtualCameras
    }

    /// Minimum `iPhoneAffinity` score that `bestRealIPhone` should accept,
    /// derived from this filter's `allowVirtualCameras` setting.
    public var minIPhoneAffinity: Int { allowVirtualCameras ? 1 : 2 }

    /// Substrings (case-insensitive) we consider "virtual". These are by far
    /// the noisiest offenders for screen-recorder users — virtual cams from
    /// streaming/conferencing apps and audio loopback drivers.
    /// NOTE: iPhone bridges like Camo / EpocCam are intentionally NOT here —
    /// they ARE the user's iPhone when native Continuity isn't advertising.
    static let virtualKeywords: [String] = [
        "obs", "manycam", "snap camera", "snapchat",
        "ndi", "mmhmm", "loopback", "blackhole", "soundflower",
        "aggregate device", "multi-output device", "virtual"
    ]

    /// Names (case-insensitive) we treat as "this is the user's iPhone" even
    /// when the device type isn't `.continuityCamera`. Lets the sticky iPhone
    /// slot bind to Camo / EpocCam / etc. when native Continuity is off.
    static let iPhoneBridgeKeywords: [String] = [
        "iphone", "camo", "epoccam"
    ]

    public func isHidden(_ device: AVCaptureDevice) -> Bool {
        if Self.looksLikeIPhone(device) { return false }
        if hiddenDeviceIDs.contains(device.uniqueID) { return true }
        if hideVirtualDevices, Self.looksVirtual(device) { return true }
        return false
    }

    public static func looksVirtual(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return virtualKeywords.contains(where: { name.contains($0) })
    }

    /// True for native Continuity Camera devices AND for known iPhone-as-webcam
    /// bridges (Camo, EpocCam). Used to drive the sticky "iPhone" picker slot.
    public static func looksLikeIPhone(_ device: AVCaptureDevice) -> Bool {
        if device.deviceType == .continuityCamera { return true }
        let name = device.localizedName.lowercased()
        return iPhoneBridgeKeywords.contains(where: { name.contains($0) })
    }

    /// Score for "this is the user's real iPhone" — higher is better.
    /// Used when several devices match `looksLikeIPhone` (e.g. Camo Camera +
    /// iPhone Camera + native Continuity all present at once) so we always
    /// bind to the one closest to a real iPhone.
    ///
    /// The strongest signal is `modelID` starting with "iPhone" — that's
    /// Apple's official model code (e.g. "iPhone11,6" for iPhone XR), which
    /// only real iPhones have regardless of how a third-party camera bridge
    /// has renamed or retyped the device. Native Continuity tags
    /// (`.continuityCamera`) score equally high. Generic bridge cameras
    /// like "Camo Camera" or "EpocCam HD" — which are virtual devices, not
    /// the real iPhone — score lowest, so we only fall back to them if no
    /// real iPhone is present.
    /// Returns the iPhone-like device with the highest affinity from `list`,
    /// only if it scores at least `minAffinity`. Default is 2 — accept real
    /// iPhones via Continuity or bridges that preserve the iPhone identity,
    /// reject generic bridge drivers ("Camo Camera") that have no real
    /// iPhone behind them. Pass `1` to also accept generic bridges (the
    /// "Allow virtual cameras" opt-in for power users).
    ///
    /// Tiebreaker is implicit in the score: native `.continuityCamera`
    /// (score 4) always wins over bridge-exposed iPhones (score 3), which
    /// always win over name-only matches (score 2).
    public static func bestRealIPhone(in list: [AVCaptureDevice], minAffinity: Int = 2) -> AVCaptureDevice? {
        list
            .filter { iPhoneAffinity($0) >= minAffinity }
            .max(by: { iPhoneAffinity($0) < iPhoneAffinity($1) })
    }

    /// Score for "this is the user's real iPhone" — higher is better.
    /// Four signals in decreasing trustworthiness:
    ///
    ///   4 — `.continuityCamera` device type. Apple's native path. Lowest
    ///       latency, highest quality. Wins over everything else.
    ///   3 — Apple's model code (`modelID` starts with "iPhone"). Only real
    ///       iPhones report this. Bridges that pass-through the device
    ///       preserve modelID, so this catches them too.
    ///   3 — `manufacturer` field reports "Apple" AND device isn't built-in.
    ///       Catches bridges that strip the modelID but can't fake the
    ///       manufacturer (Apple would sue a vendor that lies about this).
    ///   2 — `localizedName` contains "iphone". Last-ditch — defeated by
    ///       bridges that rename the device. Worth keeping for resilience.
    ///   1 — Generic bridge driver name (Camo Camera, EpocCam HD, …).
    ///       Virtual cameras with no guaranteed iPhone behind them. NOT
    ///       bound by default — only when the user opts into virtual
    ///       cameras via Settings.
    public static func iPhoneAffinity(_ device: AVCaptureDevice) -> Int {
        iPhoneAffinity(
            deviceType: device.deviceType,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            localizedName: device.localizedName
        )
    }

    /// Pure-data overload — takes the four signal fields directly so that
    /// unit tests can exercise the scoring logic without instantiating a
    /// real `AVCaptureDevice` (which requires actual hardware). All the
    /// scoring rules live here; the `AVCaptureDevice` version above is a
    /// thin wrapper.
    static func iPhoneAffinity(
        deviceType: AVCaptureDevice.DeviceType,
        modelID: String,
        manufacturer: String,
        localizedName: String
    ) -> Int {
        if deviceType == .continuityCamera { return 4 }
        if modelID.hasPrefix("iPhone") { return 3 }
        if manufacturer.contains("Apple"),
           deviceType != .builtInWideAngleCamera { return 3 }
        let name = localizedName.lowercased()
        if name.contains("iphone") { return 2 }
        if iPhoneBridgeKeywords.contains(where: { name.contains($0) }) { return 1 }
        return 0
    }
}
