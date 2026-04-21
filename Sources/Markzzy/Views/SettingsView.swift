import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    generalBox
                    recordingBox
                    folderBox
                }
                .padding(16)
            }
        }
        .frame(width: 500, height: 720)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            LogoMark(size: 22)
            Text(model.t(.settings)).font(.headline)
            Spacer()
            Button(model.t(.checkForUpdates)) { updates.checkForUpdates() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!updates.canCheckForUpdates)
            Text("0.1.0").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var generalBox: some View {
        GroupBox {
            VStack(spacing: 12) {
                row(label: model.t(.language)) {
                    Picker("", selection: $model.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider()
                Toggle(isOn: $model.rememberFaceCam) {
                    Text(model.t(.rememberFaceCam))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.general), systemImage: "slider.horizontal.3")
        }
    }

    private var recordingBox: some View {
        GroupBox {
            VStack(spacing: 12) {
                row(label: model.t(.quality)) {
                    Picker("", selection: $model.quality) {
                        ForEach(RecordingQuality.allCases) { q in
                            Text(q.localizedLabel(model.language)).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider()
                row(label: model.t(.countdown)) {
                    Picker("", selection: $model.countdownEnabled) {
                        Text(model.t(.countdownOff)).tag(false)
                        Text(model.t(.countdown3s)).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.tabRecord), systemImage: "record.circle")
        }
    }

    private var folderBox: some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text((model.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(model.t(.changeFolder)) { chooseFolder() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.outputFolder), systemImage: "externaldrive")
        }
    }

    private func row<C: View>(label: String,
                              @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = model.t(.selectFolderMessage)
        panel.prompt = model.t(.chooseThisFolder)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.outputDirectory
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDirectory = url
        }
    }
}
