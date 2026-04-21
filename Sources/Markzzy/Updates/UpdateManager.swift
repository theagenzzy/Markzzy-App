import Foundation
import SwiftUI
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` that lets the
/// rest of the app expose a "Check for Updates…" action without pulling
/// Sparkle types into view code.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let feedURL = "https://markzzy.tech/api/releases/appcast.xml"

    @Published private(set) var canCheckForUpdates: Bool = false

    private let controller: SPUStandardUpdaterController
    private let feedDelegate = FeedURLDelegate()

    override init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: feedDelegate,
            userDriverDelegate: nil
        )
        super.init()
        self.controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Provides the feed URL at runtime so we don't depend on `SUFeedURL` being
/// present in Info.plist (SPM-built bundles don't ship one by default).
private final class FeedURLDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateManager.feedURL
    }
}
