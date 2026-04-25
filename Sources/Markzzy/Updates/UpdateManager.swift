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
    static let feedURL = "https://markzzy.tech/api/releases/appcast.xml"

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
