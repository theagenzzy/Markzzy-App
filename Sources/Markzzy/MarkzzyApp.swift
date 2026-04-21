import SwiftUI

@main
struct MarkzzyApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var license = LicenseManager()
    @StateObject private var updates = UpdateManager()

    var body: some Scene {
        WindowGroup("Markzzy") {
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
    enum Tab: Hashable { case record, library, settings }
    @State private var tab: Tab = .record

    var body: some View {
        VStack(spacing: 0) {
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
