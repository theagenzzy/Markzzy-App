import SwiftUI
import AVFoundation

struct ControlPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        PIPComposedPreview()
                            .environmentObject(model)
                        if let n = model.countdownValue {
                            countdownOverlay(value: n)
                        }
                    }
                    .frame(height: 220)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                    formatBox
                        .padding(.horizontal, 16)

                    if model.outputFormat == .youtube {
                        GroupBox {
                            VStack(spacing: 12) {
                                shapeRow
                                Divider()
                                sizeRow
                                Divider()
                                positionRow
                                Divider()
                                borderStyleRow
                                if model.pipBorder.style != .none {
                                    borderCustomRow
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            Label(model.t(.facecam), systemImage: "person.crop.circle")
                        }
                        .padding(.horizontal, 16)
                    } else if model.layout == .pipOverlay {
                        Text(model.t(.faceCamHiddenNote))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                    }

                    GroupBox {
                        VStack(spacing: 10) {
                            sourceRow(icon: "display", label: model.t(.screen)) {
                                HStack(spacing: 6) {
                                    Picker("", selection: $model.selectedScreen) {
                                        ForEach(model.screenSources) {
                                            Text($0.title).tag(Optional($0))
                                        }
                                    }
                                    .labelsHidden()
                                    if let cap = model.effectiveCaptureLabel {
                                        Text(cap)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(Color.accentColor.opacity(0.85))
                                            )
                                            .help(cropTooltip)
                                    }
                                }
                            }
                            sourceRow(icon: "video", label: model.t(.camera)) {
                                Picker("", selection: $model.selectedCamera) {
                                    Text(model.t(.noneOption)).tag(Optional<AVCaptureDevice>(nil))
                                    ForEach(model.cameras, id: \.uniqueID) {
                                        Text(camLabel($0)).tag(Optional($0))
                                    }
                                }
                                .labelsHidden()
                            }
                            sourceRow(icon: "mic", label: model.t(.mic)) {
                                Picker("", selection: $model.selectedMic) {
                                    Text(model.t(.off)).tag(Optional<AVCaptureDevice>(nil))
                                    ForEach(model.microphones, id: \.uniqueID) {
                                        Text($0.localizedName).tag(Optional($0))
                                    }
                                }
                                .labelsHidden()
                            }
                            if model.selectedMic != nil {
                                micLevelMeter
                            }
                        }
                        .padding(.vertical, 2)
                    } label: {
                        Label(model.t(.sources), systemImage: "slider.horizontal.3")
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 10)
            }
            Divider()
            footer
        }
        .frame(width: 500, height: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: model.selectedCamera) { _, new in
            model.applyPreviewCamera(new)
        }
    }

    // MARK: - Title bar

    private func countdownOverlay(value: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.55))
            VStack(spacing: 8) {
                Text(model.t(.recordingIn))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(value)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .transition(.opacity)
    }

    private var formatBox: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(model.t(.format))
                        .frame(width: 70, alignment: .leading)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(OutputFormat.allCases) { formatButton($0) }
                    }
                    Spacer()
                }

                if model.outputFormat != .youtube {
                    Divider()
                    HStack(spacing: 10) {
                        Text(model.t(.layout))
                            .frame(width: 70, alignment: .leading)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(nonPipLayouts) { layoutButton($0) }
                        }
                        Spacer()
                    }
                    if model.layout.usesScreen {
                        Divider()
                        HStack(spacing: 10) {
                            Text(model.t(.screenAnchor))
                                .frame(width: 70, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $model.screenAnchor) {
                                ForEach(ScreenAnchor.allCases) { a in
                                    Text(a.localizedLabel(model.language)).tag(a)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.formatSection), systemImage: "aspectratio")
        }
    }

    private var nonPipLayouts: [Layout] {
        [.splitScreenTop, .splitCamTop, .cameraOnly, .screenOnly]
    }

    private func formatButton(_ f: OutputFormat) -> some View {
        let active = model.outputFormat == f
        return Button { model.outputFormat = f } label: {
            HStack(spacing: 4) {
                Image(systemName: f.sfSymbol).font(.system(size: 11, weight: .semibold))
                Text(f.localizedLabel(model.language)).font(.caption)
            }
            .frame(height: 24)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.12))
        )
        .help(formatTooltip(f))
    }

    private var cropTooltip: String {
        guard let r = model.effectiveCaptureRect, let s = model.selectedScreen else { return "" }
        let anchor = model.screenAnchor.localizedLabel(model.language)
        return "\(Int(r.width))×\(Int(r.height)) · \(anchor) · source \(s.width)×\(s.height)"
    }

    private func formatTooltip(_ f: OutputFormat) -> String {
        switch f {
        case .youtube:  "YouTube · Vimeo · Loom · Courses — native screen size"
        case .reel916:  "TikTok · Instagram Reels · YouTube Shorts · Facebook Reels · Stories — 1080×1920"
        case .square11: "Instagram feed · Facebook feed — 1080×1080"
        }
    }

    private func layoutButton(_ l: Layout) -> some View {
        let active = model.layout == l
        return Button { model.layout = l } label: {
            Image(systemName: l.sfSymbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.12))
        )
        .help(l.localizedLabel(model.language))
    }

    private var micLevelMeter: some View {
        HStack(spacing: 10) {
            Label {
                Text(model.t(.mic))
                    .foregroundStyle(.tertiary)
                    .opacity(0)  // keeps alignment with sourceRow
            } icon: {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            .frame(width: 92, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(micLevelColor)
                        .frame(width: geo.size.width * CGFloat(model.micLevel))
                }
            }
            .frame(height: 6)
        }
    }

    private var micLevelColor: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .red],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            LogoMark(size: 22)
            Text("Markzzy").font(.headline)
            Spacer()
            if isRecording {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(timeString(model.elapsed))
                        .monospacedDigit()
                }
                .foregroundStyle(.red)
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Face cam sub-rows

    private var shapeRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.shape)).frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(PIPShape.allCases) { sh in
                    shapeButton(sh)
                }
            }
            Spacer()
        }
    }

    private func shapeButton(_ sh: PIPShape) -> some View {
        let active = model.pipShape == sh
        return Button { model.pipShape = sh } label: {
            Image(systemName: sh.sfSymbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.12))
        )
        .help(sh.localizedLabel(model.language))
    }

    private var sizeRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.size)).frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: $model.pipSize, in: 0.10...0.40)
            Text("\(Int(model.pipSize * 100))%")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var positionRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.position)).frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                cornerButton(.topLeft,     icon: "arrow.up.left")
                cornerButton(.topRight,    icon: "arrow.up.right")
                cornerButton(.bottomLeft,  icon: "arrow.down.left")
                cornerButton(.bottomRight, icon: "arrow.down.right")
                customIndicator
            }
            Spacer()
            Text(model.t(.orDragAbove))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func cornerButton(_ preset: AppModel.CornerPreset, icon: String) -> some View {
        let active = model.matchesCorner(preset)
        return Button {
            model.snap(to: preset)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.12))
        )
    }

    private var customIndicator: some View {
        let active = model.isCustomPosition
        return Image(systemName: "scope")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 24, height: 22)
            .foregroundStyle(active ? .white : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.12))
            )
            .help(model.t(.customPosition))
    }

    private var borderStyleRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.border)).frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(PIPBorder.Style.allCases) { borderStyleButton($0) }
            }
            Spacer()
        }
    }

    private func borderStyleButton(_ s: PIPBorder.Style) -> some View {
        let active = model.pipBorder.style == s
        return Button { model.pipBorder.style = s } label: {
            Image(systemName: s.sfSymbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.12))
        )
        .help(s.localizedLabel(model.language))
    }

    private var borderCustomRow: some View {
        let style = model.pipBorder.style
        return HStack(spacing: 10) {
            Text(model.t(.color)).frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            if style == .chrome {
                Text(model.t(.metallicPreset))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ColorPicker("", selection: Binding(
                    get: { Color(cgColor: model.pipBorder.color) },
                    set: { model.pipBorder.color = NSColor($0).cgColor }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)
                if style.usesSecondColor {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ColorPicker("", selection: Binding(
                        get: { Color(cgColor: model.pipBorder.color2) },
                        set: { model.pipBorder.color2 = NSColor($0).cgColor }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 32)
                }
            }
            Slider(value: $model.pipBorder.width, in: 1...8)
            Text("\(Int(model.pipBorder.width))")
                .monospacedDigit()
                .frame(width: 18, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sources row helper

    private func sourceRow<C: View>(icon: String, label: String,
                                    @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 10) {
            Label {
                Text(label).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            .frame(width: 92, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            Button {
                Task { await model.toggleRecording() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isRecording ? "stop.fill" : "record.circle")
                    Text(isRecording ? model.t(.stopRecording) : model.t(.startRecording))
                        .font(.body.weight(.semibold))
                    Spacer()
                    Text("⇧⌘R").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            statusLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var statusLine: some View {
        Group {
            switch model.state {
            case .idle:
                Text("\(model.t(.savesTo)) \((model.outputDirectory.path as NSString).abbreviatingWithTildeInPath)")
            case .preparing:
                Text(model.t(.preparing))
            case .recording:
                Text(model.t(.recording))
                    .foregroundStyle(.red)
            case .finishing:
                Text(model.t(.saving))
            case .done(let url):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(url.lastPathComponent)
                    Button(model.t(.showInFinder)) { model.revealInFinder(url) }
                        .buttonStyle(.link)
                }
            case .failed(let m):
                Text("\(model.t(.errorPrefix)) \(m)").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        if case .recording = model.state { return true } else { return false }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func camLabel(_ d: AVCaptureDevice) -> String {
        d.deviceType == .continuityCamera ? "\(d.localizedName) (iPhone)" : d.localizedName
    }
}
