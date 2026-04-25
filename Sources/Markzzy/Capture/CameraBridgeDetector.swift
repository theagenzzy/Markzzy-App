import AVFoundation
import Foundation

/// A third-party app or kernel extension that intercepts cameras at the
/// CoreMediaIO level and exposes the iPhone (or other devices) as
/// `.external`, masking Apple's native Continuity Camera. Once installed
/// as a system extension or DAL plugin, a bridge affects EVERY app on the
/// Mac — Markzzy can't disable it from inside the process.
///
/// We don't try to "win" against bridges (impossible from userspace).
/// We detect them so we can:
///   - Diagnose to the user why their iPhone might be slow / unavailable.
///   - Show a "via [Vendor]" badge so the user knows the path.
///   - Provide vendor-specific uninstall instructions if they want clean
///     native Continuity.
public struct CameraBridge: Identifiable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let vendorName: String
    /// Substrings (lowercased) we look for in `AVCaptureDevice.localizedName`.
    public let deviceNamePatterns: [String]
    /// Bundle/plugin filenames we look for in `/Library/CoreMediaIO/Plug-Ins/DAL/`.
    public let dalPluginNames: [String]
    /// Bundle ID and team ID for `systemextensionsctl uninstall` (when the
    /// bridge ships as a system extension instead of a DAL plugin).
    public let extensionBundleID: String?
    public let extensionTeamID: String?
    /// Optional vendor URL pointing at official uninstall instructions.
    public let vendorURL: URL?
}

public enum CameraBridgeDetector {

    /// Bridges Markzzy knows how to identify. Add new ones here as we learn
    /// of them in the wild.
    public static let known: [CameraBridge] = [
        CameraBridge(
            id: "camo",
            displayName: "Camo",
            vendorName: "Reincubate",
            deviceNamePatterns: ["camo"],
            dalPluginNames: [],
            extensionBundleID: "com.reincubate.macos.cam.avextension",
            extensionTeamID: "Q248YREB53",
            vendorURL: URL(string: "https://reincubate.com/support/how-to/uninstall-camo/")
        ),
        CameraBridge(
            id: "epoccam",
            displayName: "EpocCam",
            vendorName: "Elgato (Kinoni)",
            deviceNamePatterns: ["epoccam"],
            dalPluginNames: ["EpocCam.plugin"],
            extensionBundleID: nil,
            extensionTeamID: nil,
            vendorURL: URL(string: "https://help.elgato.com/")
        ),
        CameraBridge(
            id: "iriun",
            displayName: "Iriun Webcam",
            vendorName: "Iriun",
            deviceNamePatterns: ["iriun"],
            dalPluginNames: ["IriunWebcam.plugin"],
            extensionBundleID: nil,
            extensionTeamID: nil,
            vendorURL: URL(string: "https://iriun.com/")
        ),
        CameraBridge(
            id: "droidcam",
            displayName: "DroidCam",
            vendorName: "Dev47Apps",
            deviceNamePatterns: ["droidcam"],
            dalPluginNames: ["DroidCam.plugin"],
            extensionBundleID: nil,
            extensionTeamID: nil,
            vendorURL: URL(string: "https://www.dev47apps.com/")
        ),
        CameraBridge(
            id: "ndi",
            displayName: "NDI Tools",
            vendorName: "NewTek / Vizrt",
            deviceNamePatterns: ["ndi"],
            dalPluginNames: ["NewTek NDI Webcam.plugin", "NDI Webcam Input.plugin"],
            extensionBundleID: nil,
            extensionTeamID: nil,
            vendorURL: URL(string: "https://ndi.video/")
        )
    ]

    /// Returns every known bridge currently present on this Mac. A bridge
    /// matches if either:
    ///   (a) one of its DAL plugins exists on disk, OR
    ///   (b) the AVFoundation device list contains a camera whose name
    ///       matches one of its patterns.
    /// Both signals catch bridges that are installed even when no device of
    /// theirs is currently connected.
    public static func detect() -> [CameraBridge] {
        detect(deviceNames: CameraCapture.listAllDevices().map { $0.localizedName },
               dalPluginsAt: "/Library/CoreMediaIO/Plug-Ins/DAL/")
    }

    /// Pure-data overload — takes the inputs directly so unit tests can
    /// exercise detection logic without touching the real filesystem or
    /// AVFoundation.
    static func detect(deviceNames: [String], dalPluginsAt path: String) -> [CameraBridge] {
        let lowercaseNames = deviceNames.map { $0.lowercased() }
        let dalContents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return known.filter { bridge in
            let nameHit = bridge.deviceNamePatterns.contains { pattern in
                lowercaseNames.contains { $0.contains(pattern) }
            }
            let pluginHit = bridge.dalPluginNames.contains { dalContents.contains($0) }
            return nameHit || pluginHit
        }
    }

    /// Identifies which bridge (if any) "owns" a given device — used to
    /// label the in-preview badge ("via Camo", "via EpocCam"). Returns nil
    /// for native Continuity devices and for cameras unrelated to any
    /// known bridge.
    public static func bridgeBacking(_ device: AVCaptureDevice) -> CameraBridge? {
        let name = device.localizedName.lowercased()
        return known.first { bridge in
            bridge.deviceNamePatterns.contains { name.contains($0) }
        }
    }

    /// True when AVFoundation can see at least one device of type
    /// `.continuityCamera`. When this is true, native Continuity Camera
    /// works and we don't need to nag the user about installed bridges.
    public static func nativeContinuityAvailable() -> Bool {
        CameraCapture.listAllDevices().contains { $0.deviceType == .continuityCamera }
    }
}
