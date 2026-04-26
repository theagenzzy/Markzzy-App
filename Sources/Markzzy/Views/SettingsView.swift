import SwiftUI
import AppKit
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateManager
    @EnvironmentObject var license: LicenseManager

    /// Which subsection of Settings is currently visible. Splitting the
    /// long scroll into tabs lets SwiftUI render only one section's
    /// worth of content per frame — the old all-in-one ScrollView was
    /// re-laying out every box (including the AVFoundation-backed
    /// "Detected cameras" table) on every state change, which made
    /// every button click feel laggy.
    enum Section: String, CaseIterable, Identifiable {
        case general, recording, cameras, output, license
        var id: String { rawValue }
    }
    @State private var section: Section = .general
    /// Persists across launches so the user's last pick stays selected
    /// between Settings opens. Default is monthly because most trial →
    /// paid conversions choose the recurring plan first.
    @AppStorage("licenseUpgradePlanChoice") private var selectedUpgradePlan: String = "monthly"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    sectionContent
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(width: 500, height: 720)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// Top segmented picker. Compact labels — the section icons help
    /// recognition at a glance.
    private var sectionPicker: some View {
        Picker("", selection: $section) {
            Label(model.t(.sectionGeneral),   systemImage: "gearshape").tag(Section.general)
            Label(model.t(.sectionRecording), systemImage: "record.circle").tag(Section.recording)
            Label(model.t(.sectionCameras),   systemImage: "camera").tag(Section.cameras)
            Label(model.t(.sectionOutput),    systemImage: "folder").tag(Section.output)
            Label(model.t(.sectionLicense),   systemImage: "person.crop.rectangle").tag(Section.license)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Renders only the boxes for the active section. The non-active
    /// boxes don't get instantiated at all — their state isn't observed,
    /// they don't query AVFoundation, and they don't trigger layout.
    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .general:
            generalBox
        case .recording:
            recordingBox
        case .cameras:
            devicesBox
            continuityTipBox
        case .output:
            folderBox
        case .license:
            licenseBox
        }
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
            Text("0.1.1").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var generalBox: some View {
        VStack(spacing: 14) {
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

            aboutBox
        }
    }

    /// "About Markzzy" card with version + useful links. Gives the
    /// General tab some weight so it doesn't feel empty next to the
    /// dense Cameras tab.
    private var aboutBox: some View {
        GroupBox {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    LogoMark(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Markzzy")
                            .font(.headline)
                        Text("\(model.t(.appVersion)) 0.1.1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.t(.checkForUpdates)) { updates.checkForUpdates() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!updates.canCheckForUpdates)
                }
                .padding(.vertical, 6)
                Divider().padding(.horizontal, -12)
                Button { license.openWebsite() } label: {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundStyle(.blue)
                            .frame(width: 18)
                        Text(model.t(.appWebsite))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Divider().padding(.horizontal, -12)
                Button { license.openChangelog() } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                            .frame(width: 18)
                        Text(model.t(.appWhatsNew))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        } label: {
            Label(model.t(.appAbout), systemImage: "info.circle")
        }
    }

    private var recordingBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    row(label: model.t(.quality)) {
                        Picker("", selection: $model.quality) {
                            ForEach(RecordingQuality.allCases) { q in
                                Text(q.localizedLabel(model.language)).tag(q)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    // Description of the currently-selected quality so
                    // the user understands the trade-off at a glance.
                    HStack(spacing: 8) {
                        Image(systemName: qualityIcon(model.quality))
                            .font(.caption)
                            .foregroundStyle(qualityColor(model.quality))
                            .frame(width: 16)
                        Text(qualityDescription(model.quality))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 110)
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

    private func qualityDescription(_ q: RecordingQuality) -> String {
        switch q {
        case .low: return model.t(.qualityLowDesc)
        case .medium: return model.t(.qualityMediumDesc)
        case .high: return model.t(.qualityHighDesc)
        }
    }

    private func qualityIcon(_ q: RecordingQuality) -> String {
        switch q {
        case .low: return "leaf"
        case .medium: return "scalemass"
        case .high: return "sparkles"
        }
    }

    private func qualityColor(_ q: RecordingQuality) -> Color {
        switch q {
        case .low: return .green
        case .medium: return .blue
        case .high: return .purple
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

                Toggle(isOn: Binding(
                    get: { model.deviceFilter.allowVirtualCameras },
                    set: { newVal in
                        var f = model.deviceFilter
                        f.allowVirtualCameras = newVal
                        model.deviceFilter = f
                    })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.t(.allowVirtualCameras))
                        Text(model.t(.allowVirtualCamerasHint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                detectedCamerasSection

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

    /// Diagnostic table — surfaces what AVFoundation reports for each
    /// camera + how Markzzy classifies it. Critical for support tickets:
    /// user takes a screenshot, we know exactly what they have.
    private var detectedCamerasSection: some View {
        let cams = model.allConnectedCameras
        return VStack(alignment: .leading, spacing: 6) {
            Text(model.t(.detectedCamerasHeader))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(model.t(.detectedCamerasHint))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(cams, id: \.uniqueID) { cam in
                detectedCameraRow(cam)
            }
        }
    }

    @ViewBuilder
    private func detectedCameraRow(_ cam: AVCaptureDevice) -> some View {
        let role = cameraRoleLabel(for: cam)
        let status = cameraStatusLabel(for: cam)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(cam.localizedName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(cam.modelID) · \(cam.manufacturer)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(role)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(roleColor(for: cam))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(roleColor(for: cam).opacity(0.15))
                .clipShape(Capsule())
            Text(status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private func cameraRoleLabel(for cam: AVCaptureDevice) -> String {
        switch DeviceFilter.iPhoneAffinity(cam) {
        case 4: return model.t(.roleNativeContinuity)
        case 3: return model.t(.roleRealIPhone)
        case 2: return model.t(.roleBridgedIPhone)
        case 1: return model.t(.roleVirtualBridge)
        default: return model.t(.roleStandard)
        }
    }

    private func roleColor(for cam: AVCaptureDevice) -> Color {
        switch DeviceFilter.iPhoneAffinity(cam) {
        case 4: return .green
        case 3: return .blue
        case 2: return .indigo
        case 1: return .orange
        default: return .gray
        }
    }

    private func cameraStatusLabel(for cam: AVCaptureDevice) -> String {
        if model.selectedCamera?.uniqueID == cam.uniqueID {
            return model.t(.statusInUse)
        }
        if model.deviceFilter.isHidden(cam) {
            return model.t(.statusFiltered)
        }
        return model.t(.statusAvailable)
    }

    /// Permanent educational tip explaining Continuity Camera behavior
    /// — specifically why tapping "Disconnect" on the iPhone is bad
    /// (triggers iOS cool-down) and that USB is the bulletproof
    /// alternative. Lives in Settings so it's discoverable but not
    /// in-the-way during normal use.
    private var continuityTipBox: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 16))
                    .foregroundStyle(.yellow)
                    .frame(width: 22, alignment: .center)
                    .padding(.top, 1)
                Text(model.t(.continuityTipBody))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.continuityTipHeader), systemImage: "iphone.gen3")
        }
    }

    private var folderBox: some View {
        VStack(spacing: 14) {
            outputFolderCard()
            recentRecordingsCard()
            storageCard()
        }
    }

    /// Folder + path + open-in-finder. Stats moved to storageCard so this
    /// card stays focused on "where do new recordings go".
    private func outputFolderCard() -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 22)
                    Text((model.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button(model.t(.changeFolder)) { chooseFolder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.outputDirectory])
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.blue)
                            .frame(width: 18)
                        Text(model.t(.outputOpenInFinder))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.outputFolder), systemImage: "externaldrive")
        }
    }

    /// Last 3 recordings — quick-access without leaving Settings. Each row
    /// reveals the file in Finder; "View all" opens the Library tab.
    private func recentRecordingsCard() -> some View {
        let videos = Array(model.listRecordedVideos().prefix(3))
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if videos.isEmpty {
                    HStack {
                        Image(systemName: "film")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                        Text(model.t(.outputNoRecordingsYet))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(videos, id: \.url) { v in
                        recentRecordingRow(v)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.outputRecentRecordings), systemImage: "film.stack")
        }
    }

    private func recentRecordingRow(_ v: VideoItem) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([v.url])
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(relativeDate(v.date)) · \(v.sizeFormatted)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// Storage usage — sums every Markzzy recording in the output dir,
    /// then estimates how many more hours the user can record at the
    /// current quality before the disk fills up. Helps the user see
    /// "what does Markzzy actually take" vs the rest of their disk.
    private func storageCard() -> some View {
        let videos = model.listRecordedVideos()
        let used: Int64 = videos.reduce(0) { $0 + $1.size }
        let usedStr = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        let freeBytes: Int64 = (try? model.outputDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        let hoursLeft = estimatedHoursRemaining(freeBytes: freeBytes)
        let qualityName: String = {
            switch model.quality {
            case .low: return "720p"
            case .medium: return "1080p"
            case .high: return "4K"
            }
        }()

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    folderStat(
                        icon: "internaldrive",
                        iconColor: .green,
                        label: model.t(.outputDiskSpace),
                        value: freeDiskSpaceString()
                    )
                    folderStat(
                        icon: "film.stack",
                        iconColor: .orange,
                        label: model.t(.outputRecordingsCount),
                        value: "\(videos.count)"
                    )
                    folderStat(
                        icon: "scalemass",
                        iconColor: .purple,
                        label: model.t(.outputUsedByMarkzzy),
                        value: usedStr
                    )
                }
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                        .padding(.top, 1)
                    // Markdown bold survives in Text(_:) on macOS 12+, so the
                    // **%@** placeholder gets the localized estimate inline.
                    Text(.init(String(format: model.t(.outputStorageEstimateFormat), qualityName, hoursLeft)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.outputStorage), systemImage: "chart.pie")
        }
    }

    /// Coarse capacity estimate. Bitrates are honest ballparks for the
    /// h.264 settings the recorder uses — kept conservative so the user
    /// isn't promised more time than they actually have.
    private func estimatedHoursRemaining(freeBytes: Int64) -> String {
        let bytesPerHour: Double = {
            switch model.quality {
            case .low:    return 1.8 * 1_073_741_824   // 720p   ~1.8 GB/h
            case .medium: return 3.6 * 1_073_741_824   // 1080p  ~3.6 GB/h
            case .high:   return 14.4 * 1_073_741_824  // 4K     ~14 GB/h
            }
        }()
        guard bytesPerHour > 0 else { return "—" }
        let hours = Double(freeBytes) / bytesPerHour
        if hours < 1 { return model.t(.outputStorageLessThanHour) }
        if hours < 24 { return String(format: model.t(.outputStorageHoursFormat), Int(hours)) }
        let days = Int(hours / 24)
        return String(format: model.t(.outputStorageDaysFormat), days)
    }

    private func folderStat(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Reads the free space on the volume that contains the output dir.
    /// Falls back to "—" on any FS error so we never crash.
    private func freeDiskSpaceString() -> String {
        do {
            let values = try model.outputDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            let bytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } catch {
            return "—"
        }
    }

    private var licenseBox: some View {
        VStack(spacing: 12) {
            if case let .activated(plan, expiresAt) = license.status {
                // One consolidated status card — plan + days + primary CTA.
                licenseStatusHero(plan: plan, expiresAt: expiresAt)
                if license.paymentPastDue { pastDueCard() }
                if let endsAt = license.willEndAt { cancelAtPeriodEndCard(endsAt: endsAt) }
                licenseDetailsStrip(expiresAt: expiresAt)
                // Single-column What's Included. The plan comparison lives
                // inside the upgrade modal on the dashboard now — clicking
                // "Activate plan →" opens it pre-selected, so the user
                // sees the comparison there. Side-by-side in 500 px broke
                // the comparison table's column widths and made it
                // unreadable; one source of truth is cleaner anyway.
                whatsIncludedCard()
                licenseActionsRow()
            } else {
                licenseInactiveCard()
            }
        }
    }

    /// Feature checklist — justifies the price by spelling out what every
    /// plan unlocks. Same content for trial / monthly / lifetime; only the
    /// support line varies (priority included for paid plans).
    private func whatsIncludedCard() -> some View {
        let isPaid = license.isLifetime || license.isMonthlyActive
        let features: [String] = [
            model.t(.licenseFeaturePresets),
            model.t(.licenseFeatureLayouts),
            model.t(.licenseFeatureWatermark),
            model.t(.licenseFeatureLibrary),
            isPaid ? model.t(.licenseFeatureSupportPaid) : model.t(.licenseFeatureSupportTrial),
        ]
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .padding(.top, 1)
                        Text(feature)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.licenseWhatsIncluded), systemImage: "sparkles")
        }
    }

    /// Plan comparison table — three columns (Trial / Monthly / Lifetime),
    /// rows for the dimensions a buyer cares about. Helps trial users
    /// pick what to upgrade to and surfaces the Lifetime value prop.
    private func comparePlansCard() -> some View {
        GroupBox {
            VStack(spacing: 0) {
                comparePlansHeader()
                Divider().padding(.horizontal, -12)
                comparePlansRow(label: model.t(.licenseComparePrice),
                                values: [model.t(.licenseCompareFree),
                                         model.t(.licenseCompareMonthlyPrice),
                                         model.t(.licenseCompareLifetimePrice)])
                Divider().padding(.horizontal, -12)
                comparePlansRow(label: model.t(.licenseCompareBilling),
                                values: ["—",
                                         model.t(.licenseCompareRecurring),
                                         model.t(.licenseCompareOneTime)])
                Divider().padding(.horizontal, -12)
                comparePlansRow(label: model.t(.licenseCompareUpdates),
                                values: ["✓", "✓", "✓"])
                Divider().padding(.horizontal, -12)
                comparePlansRow(label: model.t(.licenseCompareSupport),
                                values: ["—",
                                         model.t(.licenseComparePriority),
                                         model.t(.licenseComparePriority)])
                Divider().padding(.horizontal, -12)
                comparePlansRow(label: model.t(.licenseCompareBestFor),
                                values: [model.t(.licenseCompareTesting),
                                         model.t(.licenseCompareActiveUse),
                                         model.t(.licenseCompareLongTerm)])
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.licenseComparePlans), systemImage: "chart.bar.doc.horizontal")
        }
    }

    private func comparePlansHeader() -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity)
            let cols = [
                model.t(.licensePlanTrial),
                model.t(.licensePlanMonthly),
                model.t(.licensePlanLifetime),
            ]
            ForEach(cols, id: \.self) { col in
                Text(col.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.vertical, 6)
    }

    private func comparePlansRow(label: String, values: [String]) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Text(v)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(v == "—" ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.vertical, 7)
    }

    /// Status hero — pill + headline + subline + plan picker (only when
    /// trialing). The picker is a segmented switch between Monthly and
    /// Lifetime; the user makes the choice in the app and lands directly
    /// on the right checkout in the dashboard. Replaces the old single
    /// CTA + tiny "Lifetime $129 →" link, which made Lifetime feel
    /// secondary even though it's the better long-term value.
    private func licenseStatusHero(plan: String, expiresAt: Date) -> some View {
        let (planLabel, planTint) = planLabelAndTint(for: plan)
        let isTrial = license.isTrialing
        let daysLeft = isTrial ? license.trialDaysRemaining : nil
        let tone: Color = {
            guard let d = daysLeft else { return planTint }
            return d <= 1 ? .red : d <= 3 ? .orange : .blue
        }()

        return VStack(alignment: .leading, spacing: 10) {
            // Top row: pill (with day count appended when known) + compact
            // primary CTA only when not trialing-with-picker (avoids
            // double-action below).
            HStack(spacing: 6) {
                Circle().fill(tone).frame(width: 6, height: 6)
                Text(pillText(planLabel: planLabel, daysLeft: daysLeft).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tone)
                    .tracking(0.6)
                Spacer()
            }
            // Headline + subline.
            VStack(alignment: .leading, spacing: 3) {
                Text(heroPrimaryText(daysLeft: daysLeft, plan: plan))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                Text(heroSecondaryText(plan: plan, expiresAt: expiresAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Plan picker — only when trialing (the only state where the
            // user has a meaningful choice between Monthly and Lifetime).
            if isTrial {
                upgradePlanPicker(tone: tone)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(tone.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(tone.opacity(0.22), lineWidth: 1)
        )
    }

    /// Segmented picker between Monthly and Lifetime + a single Activate
    /// button that opens the dashboard pre-selected to the chosen plan.
    /// Defaults to Monthly because most trial → paid conversions go to
    /// the recurring plan first, but Lifetime is one click away with no
    /// visual demotion.
    private func upgradePlanPicker(tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $selectedUpgradePlan) {
                Text(model.t(.licenseHeroPlanMonthlyLine)).tag("monthly")
                Text(model.t(.licenseHeroPlanLifetimeLine)).tag("lifetime")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button { license.openUpgrade(plan: selectedUpgradePlan) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                    Text(model.t(.licenseHeroActivatePlan))
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(tone)
        }
        .padding(.top, 4)
    }

    private func pillText(planLabel: String, daysLeft: Int?) -> String {
        // When we know how many days are left, append the count to the
        // pill so the "X days left" shows up at a glance even when the
        // headline already said it. Redundant for trial callouts but the
        // pill is the most-glanced label in the License section.
        guard let d = daysLeft else { return planLabel }
        return "\(planLabel) · \(d)d"
    }

    private func heroPrimaryText(daysLeft: Int?, plan: String) -> String {
        if license.isTrialing {
            if let d = daysLeft {
                switch d {
                case 0: return model.t(.licenseHeroTrialEndsToday)
                case 1: return model.t(.licenseHeroOneDayLeft)
                default: return String(format: model.t(.licenseHeroDaysLeftFormat), d)
                }
            }
            return model.t(.licensePlanTrial)   // server hasn't replied yet — never show wrong number
        }
        switch plan.lowercased() {
        case "lifetime": return model.t(.licenseHeroLifetimeAccess)
        case "monthly":  return model.t(.licenseHeroSubActive)
        default:         return planLabelAndTint(for: plan).0
        }
    }

    private func heroSecondaryText(plan: String, expiresAt: Date) -> String {
        if license.isTrialing {
            if let charge = license.trialChargeDate {
                let dateStr = DateFormatter.localizedString(from: charge, dateStyle: .long, timeStyle: .none)
                return String(format: model.t(.licenseHeroChargeOnFormat), dateStr)
            }
            return model.t(.licenseHeroCancelBeforeEnds)
        }
        if plan.lowercased() == "lifetime" {
            return model.t(.licenseHeroLifetimeBlurb)
        }
        let dateStr = DateFormatter.localizedString(from: expiresAt, dateStyle: .long, timeStyle: .none)
        return String(format: model.t(.licenseHeroNextRenewalFormat), dateStr)
    }

    private func pastDueCard() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t(.licensePastDueTitle))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
            Text(model.t(.licensePastDueBody))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                license.openUpdatePayment()
            } label: {
                Label(model.t(.licenseUpdatePaymentButton), systemImage: "creditcard")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    private func cancelAtPeriodEndCard(endsAt: Date) -> some View {
        let dateStr = DateFormatter.localizedString(from: endsAt, dateStyle: .long, timeStyle: .none)
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(format: model.t(.licenseSubEndsOnFormat), dateStr))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(model.t(.licenseReactivateBody))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                license.openDashboard()
            } label: {
                Label(model.t(.licenseReactivateButton), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }

    /// Inline single-line metadata — collapses email · renewal · device
    /// onto one row separated by middots. Tertiary tone so it reads as
    /// quiet ambient context, not a focal point.
    private func licenseDetailsStrip(expiresAt: Date) -> some View {
        let renews = DateFormatter.localizedString(from: expiresAt, dateStyle: .medium, timeStyle: .none)
        let device = Host.current().localizedName ?? "This Mac"
        return HStack(spacing: 6) {
            if let email = license.activatedEmail, !email.isEmpty {
                inlineDetail(icon: "envelope.fill", text: email, tint: .blue)
                inlineDot()
            }
            inlineDetail(icon: "calendar", text: "Renews \(renews)", tint: .orange)
            inlineDot()
            inlineDetail(icon: "laptopcomputer", text: device, tint: .purple)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func inlineDetail(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func inlineDot() -> some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }

    /// Compact actions row — three text-only links across the top, plus a
    /// muted Cancel link below. Replaces the 5-row stacked card. Primary
    /// action (Upgrade) lives in the Hero, so this row is only secondary
    /// stuff — keep it visually quiet.
    private func licenseActionsRow() -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                actionTextButton(title: model.t(.licenseManageOnWeb),
                                 icon: "safari") { license.openDashboard() }
                Divider().frame(height: 14)
                actionTextButton(title: model.t(.licenseGetHelp),
                                 icon: "questionmark.circle") {
                    if let url = URL(string: "mailto:development@theagenzzy.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider().frame(height: 14)
                actionTextButton(title: model.t(.licenseSignOut),
                                 icon: "rectangle.portrait.and.arrow.right",
                                 tone: .red) {
                    Task { await license.signOutFromServer() }
                }
            }
            // Cancel sits in its own muted row so it doesn't compete with
            // the primary three. Hidden for lifetime (nothing to cancel)
            // and when already-canceled (Reactivate card shows instead).
            if !license.isLifetime, !license.cancelAtPeriodEnd {
                Button { license.openCancel() } label: {
                    Text(model.t(.licenseCancelSubscription))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func actionTextButton(title: String, icon: String,
                                  tone: Color = .primary,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tone)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Empty state when no active license.
    private func licenseInactiveCard() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(model.t(.licenseNotActive))
                .font(.headline)
            Button { license.openWebsite() } label: {
                Label(model.t(.licenseGetItHere), systemImage: "arrow.up.right")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func planLabelAndTint(for plan: String) -> (String, Color) {
        switch plan.lowercased() {
        case "trial":    return (model.t(.licensePlanTrial), .orange)
        case "monthly":  return (model.t(.licensePlanMonthly), .blue)
        case "lifetime": return (model.t(.licensePlanLifetime), .purple)
        default:         return (plan.capitalized, .secondary)
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
