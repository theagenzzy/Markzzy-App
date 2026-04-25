import SwiftUI

@main
struct MarkzzyApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var license = LicenseManager()
    @StateObject private var updates = UpdateManager()
    @State private var lastHandledToken: String?

    var body: some Scene {
        Window("Markzzy", id: "main") {
            Group {
                switch license.status {
                case .unknown:
                    ProgressView().frame(width: 440, height: 380)
                case .unactivated, .expired:
                    LicenseActivationView(license: license)
                        .environmentObject(model)
                case .activated:
                    RootView()
                        .environmentObject(model)
                        .environmentObject(license)
                        .environmentObject(updates)
                        .task { await model.bootstrap() }
                }
            }
            // After-first-frame work: kick the license heartbeat (network)
            // and Sparkle's updater controller (plist + feed scheduling).
            // Doing this here instead of inside each manager's `init()`
            // means the window paints in ~200 ms instead of waiting on a
            // network roundtrip + Sparkle's plist reads (~1-2 s combined
            // on cold launch).
            .task {
                license.start()
                updates.start()
            }
            .onOpenURL { url in
                guard url.scheme == "markzzy", url.host == "activate" else { return }
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                guard let token = comps?.queryItems?.first(where: { $0.name == "token" })?.value
                else { return }
                // Skip if we already processed this token in this session, or if
                // we're already activated (the link is one-shot — a re-fire from
                // the browser/email client would just hit "link_used").
                if lastHandledToken == token { return }
                if case .activated = license.status { return }
                lastHandledToken = token
                Task { await license.redeem(token: token) }
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}

private struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var license: LicenseManager
    enum Tab: Hashable { case record, library, settings }
    @State private var tab: Tab = .record

    var body: some View {
        VStack(spacing: 0) {
            // Trial / payment-issue / canceled banners. Only one shows
            // at a time (urgency order in LicenseBannerStack).
            LicenseBannerStack(license: license)

            Picker("", selection: $tab) {
                Label(model.t(.tabRecord),   systemImage: "record.circle").tag(Tab.record)
                Label(model.t(.tabLibrary),  systemImage: "film.stack").tag(Tab.library)
                Label(model.t(.tabSettings), systemImage: "gearshape").tag(Tab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()

            ZStack {
                ControlPanel()
                    .opacity(tab == .record ? 1 : 0)
                    .allowsHitTesting(tab == .record)
                VideoLibraryView(isActive: tab == .library)
                    .opacity(tab == .library ? 1 : 0)
                    .allowsHitTesting(tab == .library)
                if tab == .settings {
                    SettingsView()
                }
            }
        }
        .frame(width: 500)
    }
}
