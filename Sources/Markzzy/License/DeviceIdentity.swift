import Foundation
import IOKit
import CryptoKit

enum DeviceIdentity {
    /// Hashes the Mac's IOPlatformUUID so the server never sees the raw value.
    /// SHA-256 hex (64 chars) — matches the regex on /api/license/redeem.
    static func id() -> String {
        let raw = platformUUID() ?? fallbackId()
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Friendly name for the dashboard. Uses the user-set computer name when
    /// available; falls back to the host name.
    static func name() -> String {
        if let n = Host.current().localizedName, !n.isEmpty { return n }
        return Host.current().name ?? "Mac"
    }

    private static func platformUUID() -> String? {
        let entry = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let cf = IORegistryEntryCreateCFProperty(
            entry,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return cf?.takeRetainedValue() as? String
    }

    /// Last-resort identifier when IORegistry is unavailable. Persists in
    /// Keychain so it stays stable across launches.
    private static func fallbackId() -> String {
        if let saved = Keychain.get("deviceFallbackId") { return saved }
        let new = UUID().uuidString
        Keychain.set(new, for: "deviceFallbackId")
        return new
    }
}
