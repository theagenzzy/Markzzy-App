import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateManager
    @EnvironmentObject var license: LicenseManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    generalBox
                    recordingBox
                    devicesBox
                    folderBox
                    licenseBox
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

    private var devicesBox: some View {
        let hiddenIDs = model.deviceFilter.hiddenDeviceIDs
        let allDevices = (model.allConnectedCameras + model.allConnectedMicrophones)
        let hiddenDevices = allDevices.filter { hiddenIDs.contains($0.uniqueID) }

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { !model.deviceFilter.hideVirtualDevices },
                    set: { newVal in
                        var f = model.deviceFilter
                        f.hideVirtualDevices = !newVal
                        model.deviceFilter = f
                    })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.t(.showAllDevices))
                        Text(model.t(.showAllDevicesHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Text(model.t(.hiddenDevicesHeader))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                if hiddenDevices.isEmpty {
                    Text(model.t(.noHiddenDevices))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(hiddenDevices, id: \.uniqueID) { d in
                        HStack(spacing: 8) {
                            Image(systemName: d.hasMediaType(.video) ? "camera" : "mic")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(d.localizedName)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(model.t(.unhideAction)) {
                                model.unhideDevice(uniqueID: d.uniqueID)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.devicesSection), systemImage: "rectangle.connected.to.line.below")
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

    private var licenseBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if case let .activated(plan, expiresAt) = license.status {
                    HStack(spacing: 10) {
                        planBadge(plan)
                        Spacer()
                        Link(model.t(.licenseManageOnWeb),
                             destination: URL(string: "https://markzzy.tech/dashboard")!)
                            .font(.caption)
                    }

                    Divider()

                    VStack(spacing: 8) {
                        if let email = license.activatedEmail, !email.isEmpty {
                            licenseRow(model.t(.licenseEmailLabel),
                                       value: email,
                                       icon: "envelope")
                        }
                        licenseRow(
                            model.t(.licenseRenewsOn),
                            value: DateFormatter.localizedString(
                                from: expiresAt, dateStyle: .medium, timeStyle: .none
                            ),
                            icon: "calendar"
                        )
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Text(model.t(.licenseNotActive))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.licenseSection), systemImage: "checkmark.seal")
        }
    }

    private func licenseRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(value)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func planBadge(_ plan: String) -> some View {
        let (label, tint): (String, Color) = {
            switch plan.lowercased() {
            case "trial":    return (model.t(.licensePlanTrial), .orange)
            case "monthly":  return (model.t(.licensePlanMonthly), .blue)
            case "lifetime": return (model.t(.licensePlanLifetime), .purple)
            default:         return (plan.capitalized, .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(tint.opacity(0.15))
        )
        .overlay(
            Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5)
        )
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
