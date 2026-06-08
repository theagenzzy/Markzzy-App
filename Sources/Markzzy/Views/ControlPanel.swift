import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct ControlPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var license: LicenseManager
    @State private var showResolutionMenu = false

    enum PreviewMode: String, CaseIterable, Identifiable {
        case canvas, instagram, tiktok
        var id: String { rawValue }
        var label: String {
            switch self {
            case .canvas: "Canvas"
            case .instagram: "Instagram"
            case .tiktok: "TikTok"
            }
        }
        var sfSymbol: String {
            switch self {
            case .canvas:    "aspectratio"
            case .instagram: "camera.aperture"
            case .tiktok:    "music.note"
            }
        }
        var subtitle: String {
            switch self {
            case .canvas:    "Plain output canvas"
            case .instagram: "Reels chrome overlay"
            case .tiktok:    "TikTok chrome overlay"
            }
        }
        var chrome: PlatformChrome.Platform? {
            switch self {
            case .canvas: nil
            case .instagram: .instagram
            case .tiktok: .tiktok
            }
        }
    }
    @State private var previewMode: PreviewMode = .canvas
    @State private var showPreviewMenu = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    outputSummaryHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    ZStack {
                        PIPComposedPreview()
                            .environmentObject(model)
                        if let chrome = previewMode.chrome, model.outputFormat == .reel916 {
                            GeometryReader { geo in
                                let canvasH = geo.size.height
                                let canvasW = canvasH * 9 / 16  // 9:16 slot within the 220pt frame
                                PlatformChrome(platform: chrome)
                                    .frame(width: canvasW, height: canvasH)
                                    .position(x: geo.size.width / 2, y: canvasH / 2)
                            }
                        }
                        if let n = model.countdownValue {
                            countdownOverlay(value: n)
                        }
                    }
                    .frame(height: 220)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    formatBox
                        .padding(.horizontal, 16)

                    // Face-cam shape/size/position/border for the floating PIP
                    // (YouTube, and Reel/Post when in a PIP-overlay style).
                    // Background removal is no longer a toggle here — it's chosen
                    // via the two camera styles in the Layout picker (Reel/Post).
                    // When the circular style is active we expose its bg color.
                    if model.layout == .pipOverlay {
                        GroupBox {
                            VStack(spacing: 12) {
                                if model.outputFormat != .youtube {
                                    // Reel/Post: the floating camera is ALWAYS
                                    // background-removed. No toggle — just choose
                                    // Transparent (silhouette over the screen) or
                                    // Color (shaped, color behind).
                                    backgroundModeRow
                                    if model.faceCamBgTransparent {
                                        Divider()
                                        sizeRow
                                        Divider()
                                        positionRow
                                    } else {
                                        backgroundColorRow
                                        Divider()
                                        shapeRow
                                        Divider()
                                        sizeRow
                                        Divider()
                                        positionRow
                                    }
                                } else {
                                    // YouTube: plain floating PIP (no removal).
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
                            }
                            .padding(.vertical, 4)
                        } label: {
                            Label(model.t(.facecam), systemImage: "person.crop.circle")
                        }
                        .padding(.horizontal, 16)
                    }

                    // Split-screen / camera-only: choose the camera's background
                    // (none / blur / color / image). The person stays sharp.
                    if model.layout == .splitScreenTop || model.layout == .splitCamTop
                        || model.layout == .cameraOnly {
                        GroupBox {
                            VStack(spacing: 12) {
                                splitBgModeRow
                                if model.faceCamBgMode == .blur {
                                    Divider(); blurRadiusRow
                                } else if model.faceCamBgMode == .color {
                                    Divider(); backgroundColorRow
                                } else if model.faceCamBgMode == .image {
                                    Divider(); bgImageRow
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            Label(model.t(.facecam), systemImage: "person.crop.circle")
                        }
                        .padding(.horizontal, 16)
                    }

                    GroupBox {
                        VStack(spacing: 10) {
                            sourceRow(icon: "display", label: model.t(.sourceLabel)) {
                                HStack(spacing: 6) {
                                    Picker("", selection: $model.selectedScreen) {
                                        ForEach(model.screenSources) {
                                            Text($0.title).tag(Optional($0))
                                        }
                                    }
                                    .labelsHidden()
                                    if let cap = model.effectiveCaptureLabel {
                                        HStack(spacing: 3) {
                                            Text(model.t(.crop)).font(.caption2)
                                            Text(cap).font(.caption2.monospacedDigit())
                                        }
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
                                HStack(spacing: 4) {
                                    Picker("", selection: cameraPickerSelection) {
                                        Text(model.t(.noneOption)).tag(CameraPickerTag.none)
                                        // Sticky iPhone slot — always present so the
                                        // user keeps the selection even if macOS
                                        // drops Continuity Camera between sessions.
                                        Text(iPhoneSlotLabel).tag(CameraPickerTag.iPhone)
                                        ForEach(nonIPhoneCameras, id: \.uniqueID) {
                                            Text(camLabel($0)).tag(CameraPickerTag.device($0.uniqueID))
                                        }
                                    }
                                    .labelsHidden()
                                    .disabled(isRecording)
                                    .help(isRecording ? model.t(.lockedDuringRecording) : "")
                                    deviceOptionsMenu(for: model.selectedCamera)
                                }
                            }
                            sourceRow(icon: "mic", label: model.t(.mic)) {
                                HStack(spacing: 4) {
                                    Picker("", selection: $model.selectedMic) {
                                        Text(model.t(.off)).tag(Optional<AVCaptureDevice>(nil))
                                        ForEach(model.microphones, id: \.uniqueID) {
                                            Text($0.localizedName).tag(Optional($0))
                                        }
                                    }
                                    .labelsHidden()
                                    .disabled(isRecording)
                                    .help(isRecording ? model.t(.lockedDuringRecording) : "")
                                    deviceOptionsMenu(for: model.selectedMic)
                                }
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
        .onChange(of: model.state) { _, new in
            // Swap back to Canvas as soon as we enter prep/recording so the
            // user never mistakes the IG/TikTok chrome overlay for actual
            // content that will be burned into the output.
            switch new {
            case .preparing, .recording:
                if previewMode != .canvas { previewMode = .canvas }
            default:
                break
            }
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
                        .frame(width: 95, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        ForEach(OutputFormat.allCases) { formatButton($0) }
                    }
                    Spacer()
                }

                if model.outputFormat != .youtube {
                    Divider()
                    HStack(spacing: 10) {
                        Text(model.t(.layout))
                            .frame(width: 95, alignment: .leading)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(spacing: 6) {
                            ForEach(reelLayouts) { layoutButton($0) }
                        }
                        Spacer()
                    }
                    if model.layout.usesScreen {
                        Divider()
                        // Fill (crop to frame) vs Fit (whole desktop + blurred bg).
                        HStack(spacing: 10) {
                            Text(model.language == .es ? "Pantalla" : "Screen")
                                .frame(width: 95, alignment: .leading)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Picker("", selection: $model.screenFit) {
                                Text(model.language == .es ? "Llenar" : "Fill").tag(false)
                                Text(model.language == .es ? "Ajustar" : "Fit").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                            Spacer()
                        }
                        // Anchor only matters when cropping (Fill).
                        if !model.screenFit {
                            Divider()
                            HStack(spacing: 10) {
                                Text(model.t(.screenAnchor))
                                    .frame(width: 95, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                HStack(spacing: 6) {
                                    ForEach(ScreenAnchor.allCases) { anchorButton($0) }
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(model.t(.formatSection), systemImage: "aspectratio")
        }
    }

    /// Layouts offered for Reel/Post. `.pipOverlay` first = the floating round
    /// face-cam over the full screen (Background Transparent/Color + Shape +
    /// Size); previously only reachable by carrying the layout over from YouTube.
    private var reelLayouts: [Layout] {
        [.pipOverlay, .splitScreenTop, .splitCamTop, .cameraOnly, .screenOnly]
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
        // Format = canvas size, baked into the recorder at start → can't change
        // mid-recording. (Layout/view CAN change live; see layoutButton.)
        .disabled(isRecording)
        .help(isRecording ? model.t(.lockedDuringRecording) : formatTooltip(f))
    }

    /// Compact caption above the preview canvas. The dimensions become a Menu
    /// for non-YouTube presets so the user can change resolution inline without
    /// a dedicated row in the Format box.
    private var outputSummaryHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: model.outputFormat.sfSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
            Text(model.outputFormat.localizedLabel(model.language))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text("·").foregroundStyle(.tertiary).font(.caption)
            Button { showResolutionMenu.toggle() } label: {
                HStack(spacing: 4) {
                    Text(outputDimsText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showResolutionMenu, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(OutputResolution.allCases) { r in
                        resolutionMenuItem(r)
                    }
                }
                .frame(width: 240)
                .padding(.vertical, 4)
            }
            Spacer()
            if model.outputFormat == .reel916 {
                Button {
                    showPreviewMenu.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: previewMode.sfSymbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text("Preview:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(previewMode.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRecording)
                .popover(isPresented: $showPreviewMenu, arrowEdge: .bottom) {
                    VStack(spacing: 0) {
                        ForEach(PreviewMode.allCases) { m in
                            previewModeRow(m)
                        }
                    }
                    .frame(width: 240)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func previewModeRow(_ m: PreviewMode) -> some View {
        let active = previewMode == m
        return Button {
            previewMode = m
            showPreviewMenu = false
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: m.sfSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(active ? .white : .primary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(m.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(active ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func resolutionMenuItem(_ r: OutputResolution) -> some View {
        let active = model.outputResolution == r
        return Button {
            model.outputResolution = r
            showResolutionMenu = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "checkmark" : "circle")
                    .frame(width: 14)
                    .foregroundStyle(active ? Color.accentColor : .clear)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.label).font(.body.weight(.medium))
                    Text(r.tooltip).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private var outputDimsText: String {
        guard let screen = model.selectedScreen else { return "—" }
        let canvas = model.outputFormat.canvasSize(
            for: screen, resolution: model.outputResolution
        )
        return "\(Int(canvas.width))×\(Int(canvas.height)) MP4"
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

    private func anchorButton(_ a: ScreenAnchor) -> some View {
        let active = model.screenAnchor == a
        let axis = model.anchorAxis
        return Button { model.screenAnchor = a } label: {
            HStack(spacing: 4) {
                Image(systemName: a.sfSymbol(for: axis)).font(.system(size: 11, weight: .semibold))
                Text(a.localizedLabel(for: axis, in: model.language)).font(.caption)
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
            .frame(width: 95, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

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
                    Circle()
                        .fill(model.state == .paused ? Color.yellow : Color.red)
                        .frame(width: 6, height: 6)
                    Text(timeString(model.elapsed))
                        .monospacedDigit()
                    if model.state == .paused {
                        Text(model.t(.paused))
                            .font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(model.state == .paused ? Color.yellow : Color.red)
                .font(.subheadline.weight(.semibold))
            }
            AccountMenu()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Face cam sub-rows

    private var shapeRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.shape)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        // Background-removed face cams can go much bigger — there's no opaque box
        // covering the screen. The TRANSPARENT silhouette goes up to 3× so a
        // landscape webcam (16:9) can still fill a vertical Reel (9:16): the
        // person scales up and the transparent side margins overflow off-canvas
        // (invisible), while the head-safe clamp keeps the head on screen.
        let maxSize: CGFloat = model.pipSizeMax
        return HStack(spacing: 10) {
            Text(model.t(.size)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Slider(value: $model.pipSize, in: 0.10...maxSize)
            Text("\(Int(model.pipSize * 100))%")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var positionRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.position)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                cornerButton(.topLeft,     icon: "arrow.up.left")
                cornerButton(.topRight,    icon: "arrow.up.right")
                cornerButton(.bottomLeft,  icon: "arrow.down.left")
                cornerButton(.bottomRight, icon: "arrow.down.right")
                customButton   // custom (free drag) last
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

    /// Custom position. Pulsando: centra la cámara (entra en modo
    /// libre, ya no coincide con una esquina) y deja al usuario
    /// arrastrar la cámara en el preview para reposicionarla.
    private var customButton: some View {
        let active = model.isCustomPosition
        return Button {
            // Si ya estás en modo libre, no toques la posición —
            // respetamos donde dejaste la cámara. Si estás clavado
            // a una esquina, te llevamos al centro como punto de
            // inicio para indicar visualmente que ahora puedes
            // arrastrar libremente.
            if !active { model.pipPosition = CGPoint(x: 0.5, y: 0.5) }
        } label: {
            Image(systemName: "scope")
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
        .help(model.t(.customPosition))
    }

    private var borderStyleRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.border)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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

    // Background = Transparent (over the screen) vs solid Color.
    private var backgroundModeRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.bgColorLabel)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Picker("", selection: Binding(
                get: { model.faceCamBgTransparent },
                set: { model.faceCamBgTransparent = $0 }
            )) {
                Text(model.t(.bgModeTransparent)).tag(true)
                Text(model.t(.bgModeColor)).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // Split-screen / camera-only background source picker.
    private var splitBgModeRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.bgColorLabel)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Picker("", selection: $model.faceCamBgMode) {
                Text(model.t(.bgModeNone)).tag(FaceCamBg.none)
                Text(model.t(.bgModeBlur)).tag(FaceCamBg.blur)
                Text(model.t(.bgModeColor)).tag(FaceCamBg.color)
                Text(model.t(.bgModeImage)).tag(FaceCamBg.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var blurRadiusRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.bgBlurLabel)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Slider(value: $model.faceCamBlurRadius, in: 4...40)
            Text("\(Int(model.faceCamBlurRadius))")
                .monospacedDigit().frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var bgImageRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.bgColorLabel)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Button(model.faceCamBgImageURL?.lastPathComponent ?? model.t(.bgImageChoose)) {
                chooseBgImage()
            }
            .lineLimit(1).truncationMode(.middle)
            if model.faceCamBgImageURL != nil {
                Button { model.faceCamBgImageURL = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }

    private func chooseBgImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.faceCamBgImageURL = url
        }
    }

    // Solid background color picker — shown in color mode.
    private var backgroundColorRow: some View {
        HStack(spacing: 10) {
            Text(model.t(.bgColorLabel)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ColorPicker("", selection: Binding(
                get: { Color(cgColor: model.faceCamBgColor) },
                set: { model.faceCamBgColor = NSColor($0).cgColor }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 32)
            Spacer()
        }
    }

    private var borderCustomRow: some View {
        let style = model.pipBorder.style
        return HStack(spacing: 10) {
            Text(model.t(.color)).frame(width: 95, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
            .frame(width: 95, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            transportButtons
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
            case .paused:
                Text(model.t(.paused))
                    .foregroundStyle(.yellow)
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
                HStack(spacing: 6) {
                    Text("\(model.t(.errorPrefix)) \(AppModel.cleanFailureMessage(m))")
                        .foregroundStyle(.red)
                    if let url = AppModel.settingsURL(for: m) {
                        Button(model.t(.openSystemSettings)) {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transport (record / pause / resume / stop)

    @ViewBuilder
    private var transportButtons: some View {
        switch model.state {
        case .recording:
            HStack(spacing: 8) {
                showPreviewButton
                pauseButton
                stopButton
            }
        case .paused:
            HStack(spacing: 8) {
                showPreviewButton
                resumeButton
                stopButton
            }
        default:
            startButton
        }
    }

    /// Re-show the floating composed preview (Reels/Post) after it's been hidden.
    @ViewBuilder
    private var showPreviewButton: some View {
        if model.outputFormat != .youtube, !model.floatingPreviewVisible {
            Button { model.floatingPreviewVisible = true } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .help(model.language == .es ? "Mostrar preview flotante" : "Show floating preview")
            }
            .controlSize(.large)
        }
    }

    private var startButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                Text(model.t(.startRecording)).font(.body.weight(.semibold))
                Spacer()
                Text("⇧⌘R").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    private var pauseButton: some View {
        Button { model.pauseRecording() } label: {
            HStack(spacing: 6) {
                Image(systemName: "pause.fill")
                Text(model.t(.pauseAction)).font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .keyboardShortcut("p", modifiers: [.command, .shift])
    }

    private var resumeButton: some View {
        Button { model.resumeRecording() } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text(model.t(.resumeAction)).font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .keyboardShortcut("p", modifiers: [.command, .shift])
    }

    private var stopButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                Text(model.t(.stopAction)).font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        switch model.state {
        case .recording, .paused: return true
        default: return false
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func deviceOptionsMenu(for device: AVCaptureDevice?) -> some View {
        let canHide = device.map { $0.deviceType != .continuityCamera } ?? false
        Menu {
            if let d = device, canHide {
                Button {
                    model.hideDevice(uniqueID: d.uniqueID)
                } label: {
                    Text(String(format: model.t(.hideDeviceFormat), d.localizedName))
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(device == nil || isRecording || !canHide)
    }

    private func camLabel(_ d: AVCaptureDevice) -> String {
        DeviceFilter.looksLikeIPhone(d) ? "\(d.localizedName) (iPhone)" : d.localizedName
    }

    // MARK: - Camera picker (iPhone-aware)

    enum CameraPickerTag: Hashable {
        case none
        case iPhone
        case device(String)
    }

    private var nonIPhoneCameras: [AVCaptureDevice] {
        model.cameras.filter { !DeviceFilter.looksLikeIPhone($0) }
    }

    private var iPhoneSlotLabel: String {
        model.t(.cameraIPhoneSlot)
    }

    private var cameraPickerSelection: Binding<CameraPickerTag> {
        Binding(
            get: {
                if model.wantsContinuityCamera { return .iPhone }
                if let cam = model.selectedCamera {
                    if DeviceFilter.looksLikeIPhone(cam) { return .iPhone }
                    return .device(cam.uniqueID)
                }
                return .none
            },
            set: { tag in
                switch tag {
                case .none:
                    model.wantsContinuityCamera = false
                    model.selectedCamera = nil
                case .iPhone:
                    model.wantsContinuityCamera = true
                    // Bind only to a REAL iPhone (score >= 2): native
                    // Continuity, or a bridge that exposes the device
                    // with its actual iPhone identity (modelID iPhone* or
                    // name containing "iphone"). NEVER bind to generic
                    // bridge cameras like "Camo Camera" — those are
                    // virtual devices with no guaranteed iPhone frames.
                    // If no real iPhone is present yet, leave selectedCamera
                    // nil — the preview shows the "Looking for your iPhone…"
                    // overlay and handleDeviceChange will bind as soon as
                    // KVO surfaces the real device.
                    model.selectedCamera = DeviceFilter.bestRealIPhone(in: model.cameras, minAffinity: model.deviceFilter.minIPhoneAffinity)
                case .device(let id):
                    model.wantsContinuityCamera = false
                    model.selectedCamera = model.cameras.first(where: { $0.uniqueID == id })
                }
            }
        )
    }
}
