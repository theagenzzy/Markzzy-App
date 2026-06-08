import Foundation
import SwiftUI
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` that lets the
/// rest of the app expose a "Check for Updates…" action without pulling
/// Sparkle types into view code.
///
/// The Sparkle controller is created lazily by `start()` instead of in
/// `init()` because `SPUStandardUpdaterController(startingUpdater: true, …)`
/// reads multiple plists, schedules its first feed-fetch, and can stall the
/// main thread on cold launch. Holding the @StateObject creation that long
/// delays the first window paint by a noticeable beat. `start()` runs from
/// MarkzzyApp's `.task`, after the window is on screen.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    /// Resolution order: env > UserDefaults > production. Mirrors the same
    /// pattern as `LicenseManager.apiBase` so a single dev machine can
    /// point both the API and the Sparkle feed at localhost without
    /// recompiling. Set `MARKZZY_APPCAST_URL` (env var or `defaults write
    /// dev.markzzy.app MARKZZY_APPCAST_URL …`) when running the local
    /// update test from `docs/RELEASING.md`.
    static let feedURL: String = {
        let prod = "https://markzzy.tech/api/releases/appcast.xml"
        // Override is DEV-ONLY (bundle id prefix `dev.`) so a production build's
        // update feed can't be redirected via `defaults write`. (Updates are
        // EdDSA-signed regardless, but this keeps the channel pinned.)
        guard (Bundle.main.bundleIdentifier ?? "").hasPrefix("dev.") else { return prod }
        if let env = ProcessInfo.processInfo.environment["MARKZZY_APPCAST_URL"], !env.isEmpty {
            return env
        }
        if let pref = UserDefaults.standard.string(forKey: "MARKZZY_APPCAST_URL"), !pref.isEmpty {
            return pref
        }
        return prod
    }()

    @Published private(set) var canCheckForUpdates: Bool = false

    private var controller: SPUStandardUpdaterController?
    private let feedDelegate = FeedURLDelegate()

    override init() { super.init() }

    /// Boots the underlying Sparkle controller. Idempotent — additional
    /// calls are no-ops once the controller is alive.
    func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: feedDelegate,
            userDriverDelegate: nil
        )
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Provides the feed URL at runtime so we don't depend on `SUFeedURL` being
/// present in Info.plist (SPM-built bundles don't ship one by default).
private final class FeedURLDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateManager.feedURL
    }
}
