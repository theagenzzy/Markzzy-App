import SwiftUI
import AVFoundation

/// Live preview of the output canvas. Renders screen + camera with a single
/// persistent `CameraPreview` NSView whose frame/opacity is updated per layout
/// — never destroyed — so the capture session doesn't flicker on UI changes.
struct PIPComposedPreview: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let aspect = canvasAspect()
            let canvas = fitted(aspect: aspect, in: geo.size)
            let origin = CGPoint(
                x: (geo.size.width  - canvas.width)  / 2,
                y: (geo.size.height - canvas.height) / 2
            )
            let s = screenFrame(canvas: canvas, origin: origin)
            let c = cameraFrame(canvas: canvas, origin: origin)

            ZStack(alignment: .topLeading) {
                // Canvas background (shows the target aspect).
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: origin.x, y: origin.y)

                // Drag area for the PIP (only meaningful in pipOverlay).
                if model.layout == .pipOverlay, model.selectedCamera != nil {
                    Color.clear
                        .frame(width: canvas.width, height: canvas.height)
                        .offset(x: origin.x, y: origin.y)
                        .contentShape(Rectangle())
                        .gesture(pipDragGesture(origin: origin, canvas: canvas))
                        .allowsHitTesting(model.selectedCamera != nil)
                }

                // Screen slot (always in the view tree).
                screenView
                    .frame(width: s.width, height: s.height)
                    .clipped()
                    .offset(x: s.minX, y: s.minY)
                    .opacity(model.layout.usesScreen ? 1 : 0)
                    .overlay(
                        slotOutline
                            .frame(width: s.width, height: s.height)
                            .offset(x: s.minX, y: s.minY)
                            .opacity(model.layout.usesScreen && showSlotGuides ? 1 : 0),
                        alignment: .topLeading
                    )

                // Camera slot (always in the view tree — keeps the NSView alive).
                // Tagged with the preview-session generation: when the
                // camera gets handed back from the recording pipeline,
                // SwiftUI rebuilds the NSView so AVCaptureVideoPreviewLayer
                // re-engages with the freshly restored session. Without
                // this, the camera slot stays black after the first stop.
                // Clipped to the canvas so a cutout that overflows an edge/corner
                // (or rises tall from the bottom) is trimmed exactly like the
                // recording, instead of spilling over the gray area. The camera
                // is positioned RELATIVE to this canvas-sized container.
                Color.clear
                    .frame(width: canvas.width, height: canvas.height)
                    .overlay(alignment: .topLeading) {
                        cameraView(frame: CGRect(x: c.minX - origin.x,
                                                 y: c.minY - origin.y,
                                                 width: c.width, height: c.height))
                    }
                    .clipped()
                    .offset(x: origin.x, y: origin.y)
                    .id(model.previewSessionGeneration)
                    .opacity((!model.composedFrameActive && model.layout.usesCamera) ? 1 : 0)
                    // Drag DESDE la cámara: el NSView de la cámara
                    // capturaba los clicks y bloqueaba el área de
                    // drag de abajo → el usuario presionaba la
                    // cámara y "no la podía mover". Mismo gesto
                    // aplicado encima del NSView resuelve la UX
                    // intuitiva (tocas el objeto, lo arrastras).
                    .gesture(
                        pipDragGesture(origin: origin, canvas: canvas),
                        including: (model.layout == .pipOverlay && model.selectedCamera != nil)
                            ? .all : .none
                    )

                // Full-canvas disconnect banner. Drawn last so it sits
                // above the small PIP slot AND above the screen
                // preview. Only appears when:
                //   - the disconnect flag is set (persisted across launches),
                //   - the user is still on the iPhone slot
                //     (not "I switched to FaceTime HD"),
                //   - the layout actually uses a camera.
                if model.iPhoneRecentlyDisconnected,
                   model.wantsContinuityCamera,
                   model.layout.usesCamera {
                    IPhoneDisconnectedBanner()
                        .environmentObject(model)
                        .frame(width: canvas.width, height: canvas.height)
                        .offset(x: origin.x, y: origin.y)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "canvas")
        }
    }

    /// Gesto de drag de la cámara PIP. Mismo cálculo se reutiliza
    /// desde el área transparente del canvas Y desde la propia cámara
    /// para que se pueda arrastrar desde cualquiera.
    private func pipDragGesture(origin: CGPoint, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let nx = (value.location.x - origin.x) / canvas.width
                let ny = (value.location.y - origin.y) / canvas.height
                // Drag libre — sin snap. Las esquinas siguen accesibles vía los
                // botones cornerButton. Transparente puede llegar a los bordes.
                let edges = model.faceCamBottomAnchored
                model.pipPosition = CGPoint(x: clamp(nx, edges: edges),
                                            y: clamp(ny, edges: edges))
            }
    }

    private func clamp(_ v: CGFloat, edges: Bool = false) -> CGFloat {
        edges ? min(max(v, 0.0), 1.0) : min(max(v, 0.05), 0.95)
    }
    private func snap(_ v: CGFloat, anchors: [CGFloat], threshold: CGFloat) -> CGFloat {
        for a in anchors where abs(v - a) < threshold { return a }
        return v
    }

    // MARK: - Screen view

    @ViewBuilder
    private var screenView: some View {
        if let img = model.screenPreviewImage {
            // Crop the screen preview exactly the way the compositor will —
            // anchor-driven offset, not SwiftUI's default-center clipping.
            GeometryReader { geo in
                anchorCroppedImage(img: img, in: geo.size)
            }
            .clipped()
            .background(Color.black)
        } else {
            Color(NSColor.underPageBackgroundColor)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "display").font(.title2).foregroundStyle(.tertiary)
                        Text(model.t(.screenPreview)).font(.caption).foregroundStyle(.tertiary)
                    }
                )
        }
    }

    private func anchorCroppedImage(img: CGImage, in slot: CGSize) -> some View {
        let srcAspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
        let slotAspect = slot.width / max(slot.height, 1)
        let scaledW: CGFloat
        let scaledH: CGFloat
        if srcAspect > slotAspect {
            scaledH = slot.height
            scaledW = scaledH * srcAspect
        } else {
            scaledW = slot.width
            scaledH = scaledW / srcAspect
        }
        // Anchor por eje: si el overflow real es horizontal mueve en
        // X, si es vertical mueve en Y. Antes Y estaba hardcoded a
        // center → al recortar arriba/abajo (YouTube 16:9 en
        // pantalla 16:10) el preview no respondía al anchor.
        let offsetX: CGFloat
        let offsetY: CGFloat
        switch model.anchorAxis {
        case .horizontal:
            switch model.screenAnchor {
            case .left:   offsetX = 0
            case .center: offsetX = (slot.width - scaledW) / 2
            case .right:  offsetX = slot.width - scaledW
            }
            offsetY = (slot.height - scaledH) / 2
        case .vertical:
            offsetX = (slot.width - scaledW) / 2
            switch model.screenAnchor {
            case .left:   offsetY = 0                        // top
            case .center: offsetY = (slot.height - scaledH) / 2
            case .right:  offsetY = slot.height - scaledH    // bottom
            }
        }
        return Image(decorative: img, scale: 1)
            .resizable()
            .frame(width: scaledW, height: scaledH)
            .offset(x: offsetX, y: offsetY)
    }

    // MARK: - Camera view (stable across layouts)

    @ViewBuilder
    private func cameraView(frame c: CGRect) -> some View {
        let isOverlay = model.layout == .pipOverlay

        ZStack {
            if model.selectedCamera != nil {
                if model.backgroundRemovalActive, !model.composedFrameActive {
                    // Background-removal mode. Show the composited effect once
                    // ready; while Vision warms up show the raw camera WITHOUT a
                    // shape mask or border (no cyan-circle flash).
                    if let effect = model.faceCamEffectImage {
                        // Freeform silhouette: aspect-FIT so the whole camera
                        // frame (head included) always shows — the transparent
                        // letterbox margin is invisible, so the head is never
                        // cropped. Shaped (color) PIP keeps .fill.
                        Image(decorative: effect, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: model.faceCamBottomAnchored ? .fit : .fill)
                            .frame(width: c.width, height: c.height)
                            .clipped()
                    } else {
                        // Matte still warming up (~0.3s). Show nothing (clear)
                        // rather than the raw camera — no cyan-circle flash; the
                        // screen behind shows through (transparent intent).
                        Color.clear
                            .frame(width: c.width, height: c.height)
                    }
                } else if isOverlay {
                    // Floating PIP (YouTube + Reel/Post pipOverlay): clip to the
                    // chosen shape. Soft-edge needs a gradient MASK; other shapes
                    // use `.clipShape` (synced with the view geometry → no resize
                    // glint, unlike a separate `.mask` view).
                    if model.pipShape.usesSoftMask {
                        CameraPreview(session: model.previewSession)
                            .compositingGroup()
                            .mask(cameraMask)
                    } else {
                        CameraPreview(session: model.previewSession)
                            .clipShape(model.pipShape.anyShape())
                    }
                    if !model.pipShape.usesSoftMask, model.pipBorder.style != .none {
                        ShapedBorderOverlay(
                            shape: model.pipShape,
                            border: model.pipBorder,
                            side: min(c.width, c.height)
                        )
                        .frame(width: c.width, height: c.height)
                    }
                } else {
                    // Split / camera-only: the camera FILLS its rectangular slot
                    // (aspect-fill). NO shape clip — must not be circular here.
                    CameraPreview(session: model.previewSession)
                        .frame(width: c.width, height: c.height)
                        .clipped()
                }
            } else if model.isWaitingForIPhone {
                Color.black.overlay(
                    IPhoneWaitingOverlay()
                        .environmentObject(model)
                )
            } else {
                Color.black.overlay(
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                )
            }
        }
        .shadow(color: isOverlay ? .black.opacity(0.35) : .clear, radius: 6, y: 2)
        .frame(width: c.width, height: c.height)
        .offset(x: c.minX, y: c.minY)
        .overlay(
            slotOutline
                .frame(width: c.width, height: c.height)
                .offset(x: c.minX, y: c.minY)
                .opacity(!isOverlay && model.layout.usesCamera && showSlotGuides ? 1 : 0),
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var cameraMask: some View {
        if model.layout == .pipOverlay {
            if model.pipShape.usesSoftMask {
                // softEdge: gradiente radial RELATIVO al tamaño real
                // del slot. El antiguo endRadius=1000 era tan grande
                // que dentro del PIP la máscara era 100% opaca → el
                // borde difuminado no se veía nunca. GeometryReader
                // anclar el radio al lado del slot lo arregla.
                GeometryReader { geo in
                    let r = min(geo.size.width, geo.size.height) / 2
                    RadialGradient(
                        stops: [
                            .init(color: .white, location: 0.0),
                            .init(color: .white, location: 0.78),
                            .init(color: .clear, location: 1.0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: r
                    )
                }
            } else {
                model.pipShape.anyShape().fill(Color.black)
            }
        } else {
            Rectangle().fill(Color.black)
        }
    }

    // MARK: - Layout-dependent frames

    private func screenFrame(canvas: CGSize, origin: CGPoint) -> CGRect {
        // Once the pipeline starts emitting composed frames, switch to a
        // unified full-canvas rendering (screen + cam already baked in). Until
        // then — during the ~1s warmup between "start" and first frame —
        // keep the split layout so the user still sees camera + screen.
        if model.composedFrameActive { return CGRect(origin: origin, size: canvas) }
        switch model.layout {
        case .pipOverlay, .screenOnly:
            return CGRect(origin: origin, size: canvas)
        case .splitScreenTop:
            return CGRect(x: origin.x, y: origin.y,
                          width: canvas.width, height: canvas.height / 2)
        case .splitCamTop:
            return CGRect(x: origin.x, y: origin.y + canvas.height / 2,
                          width: canvas.width, height: canvas.height / 2)
        case .cameraOnly:
            return .zero
        }
    }

    private func cameraFrame(canvas: CGSize, origin: CGPoint) -> CGRect {
        // Camera is baked into the composed frame once pipeline is producing.
        // Keep the slot visible during the warmup (last preview-session frame
        // remains frozen on the AVCaptureVideoPreviewLayer, no black gap).
        if model.composedFrameActive { return .zero }
        switch model.layout {
        case .pipOverlay:
            return pipRect(canvas: canvas, origin: origin)
        case .splitScreenTop:
            return CGRect(x: origin.x, y: origin.y + canvas.height / 2,
                          width: canvas.width, height: canvas.height / 2)
        case .splitCamTop:
            return CGRect(x: origin.x, y: origin.y,
                          width: canvas.width, height: canvas.height / 2)
        case .cameraOnly:
            return CGRect(origin: origin, size: canvas)
        case .screenOnly:
            return .zero
        }
    }

    private func pipRect(canvas: CGSize, origin: CGPoint) -> CGRect {
        let pipW = canvas.width * model.pipSize
        // Freeform silhouette uses the FULL camera frame at native aspect — the
        // size is slider-controlled and constant, never derived from the
        // person's pose (so it never grows/shrinks when they move their hands).
        let freeform = model.faceCamBottomAnchored
        let pipH: CGFloat
        if freeform {
            // Native aspect, NO height cap → matches the recording shader exactly.
            pipH = pipW / cameraAspect()
        } else if model.pipShape == .rectangle {
            pipH = pipW / cameraAspect()
        } else {
            pipH = pipW
        }
        let rawX = origin.x + model.pipPosition.x * canvas.width
        let rawY = origin.y + model.pipPosition.y * canvas.height
        let cX: CGFloat
        let cY: CGFloat
        if freeform {
            // Head-safe: the TOP edge never leaves the canvas (centre ≥ pipH/2),
            // so the head can't be cut off. The bottom and sides MAY overflow so
            // the cutout can hug/exit any edge or corner and a tall "standing
            // person" can rise from the bottom. The canvas clips the overflow,
            // exactly like the recording path.
            let overX = pipW * 0.45
            let overY = pipH * 0.45
            let loX = origin.x + pipW / 2 - overX
            let hiX = origin.x + canvas.width - pipW / 2 + overX
            let loY = origin.y + pipH / 2
            let hiY = origin.y + canvas.height - pipH / 2 + overY
            cX = min(max(rawX, loX), hiX)
            cY = min(max(rawY, loY), hiY)
        } else {
            let pad: CGFloat = (model.pipBorder.cgColor != nil) ? model.pipBorder.lineWidth : 4
            let minX = origin.x + pipW / 2 + pad
            let maxX = origin.x + canvas.width  - pipW / 2 - pad
            let minY = origin.y + pipH / 2 + pad
            let maxY = origin.y + canvas.height - pipH / 2 - pad
            cX = min(max(rawX, minX), maxX)
            cY = min(max(rawY, minY), maxY)
        }
        return CGRect(x: cX - pipW / 2, y: cY - pipH / 2, width: pipW, height: pipH)
    }

    // MARK: - Gestures / guides

    private var slotOutline: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private var showSlotGuides: Bool { !isRecording }
    private var isRecording: Bool {
        if case .recording = model.state { return true } else { return false }
    }

    // MARK: - Helpers

    private func canvasAspect() -> CGFloat {
        switch model.outputFormat {
        case .youtube:  return screenAspect()
        case .reel916:  return 9.0 / 16.0
        case .square11: return 1.0
        }
    }

    private func screenAspect() -> CGFloat {
        if let s = model.selectedScreen, s.height > 0 {
            return CGFloat(s.width) / CGFloat(s.height)
        }
        return 16.0 / 10.0
    }

    /// REAL camera aspect (W/H), emitted by the live effect renderer. The old
    /// hardcoded 4:3 made the preview slot size differently from the recording
    /// (which uses the true camera dimensions) → preview ≠ recording. Falls back
    /// to 4:3 only until the first effect frame sets the real value.
    private func cameraAspect() -> CGFloat {
        let a = model.faceCamEffectAspect
        return a > 0.05 ? a : (4.0 / 3.0)
    }

    private func fitted(aspect: CGFloat, in container: CGSize) -> CGSize {
        let ca = container.width / container.height
        return aspect > ca
            ? CGSize(width: container.width, height: container.width / aspect)
            : CGSize(width: container.height * aspect, height: container.height)
    }
}

/// "Looking for your iPhone…" overlay shown over the empty camera slot
/// while we wait for a real iPhone (Continuity or bridge-exposed) to
/// surface. The wake session is keeping AVFoundation's scan warm in the
/// background — this overlay is purely UX so the user knows we're not
/// frozen and what to do (wake the phone, bring it closer).
///
/// Adapts to the camera slot size: full text + hint when the slot is
/// large (PIP camera-only or split layouts), compact icon + short label
/// when it's tiny (PIP overlay corner thumbnail). If a third-party camera
/// bridge is installed AND there's room, an extra diagnostic line
/// explains why the iPhone might be slow to appear.
private struct IPhoneWaitingOverlay: View {
    @EnvironmentObject var model: AppModel

    /// Cached at first render — re-evaluated when the model triggers a
    /// device list change. Pure data lookup, cheap.
    private var detectedBridges: [CameraBridge] {
        CameraBridgeDetector.detect()
    }

    var body: some View {
        GeometryReader { geo in
            let minSide = min(geo.size.width, geo.size.height)
            let style = OverlayStyle.forSize(minSide)
            content(style: style)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    /// Title + hint vary based on whether this is the user's first
    /// attempt to find an iPhone, or a reconnect after disconnect.
    private var titleKey: LKey {
        model.iPhoneRecentlyDisconnected ? .iPhoneReconnectingTitle : .iPhoneWaitingTitle
    }
    private var hintKey: LKey {
        model.iPhoneRecentlyDisconnected ? .iPhoneReconnectingHint : .iPhoneWaitingHint
    }

    @ViewBuilder
    private func content(style: OverlayStyle) -> some View {
        switch style {
        case .minimal:
            Image(systemName: "iphone.gen3")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))
                .symbolEffect(.pulse, options: .repeating)
        case .compact:
            VStack(spacing: 4) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse, options: .repeating)
                Text(model.t(titleKey))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(6)
        case .full:
            VStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse, options: .repeating)
                Text(model.t(titleKey))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(model.t(hintKey))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 12)
                // Reconnect button lives in the full-canvas
                // `IPhoneDisconnectedBanner` overlay (rendered by the
                // parent `PIPComposedPreview`). Don't duplicate it here.
                if !model.iPhoneRecentlyDisconnected, !detectedBridges.isEmpty {
                    Divider()
                        .frame(width: 60)
                        .opacity(0.3)
                        .padding(.vertical, 2)
                    Text(String(format: model.t(.iPhoneWaitingBridgeNote),
                                detectedBridges.map(\.displayName).joined(separator: ", ")))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
    }

    private enum OverlayStyle {
        case minimal, compact, full
        static func forSize(_ minSide: CGFloat) -> OverlayStyle {
            if minSide < 70 { return .minimal }
            if minSide < 180 { return .compact }
            return .full
        }
    }
}

/// Full-canvas overlay shown when the user tapped Disconnect on the
/// iPhone. The compact in-PIP overlay can't fit a button when the camera
/// slot is small (PIP layout in YouTube preset), so we render this on
/// top of the entire preview area instead — guarantees the Reconnect
/// button is always reachable regardless of layout.
///
/// Has three visual states based on `AppModel`:
///   1. Idle — initial after disconnect. Shows "Reconnect iPhone" button.
///   2. In-progress — `reconnectAttemptStatus != nil`. Shows spinner +
///      "Trying 1/3…" so the user knows we're working.
///   3. Exhausted — `reconnectExhausted == true`. Shows extended manual
///      recovery instructions (lock+unlock, iOS Settings, restart) and
///      a "Try again" button to start a fresh cycle.
private struct IPhoneDisconnectedBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            // Reel (9:16) and Square (1:1) canvases are much narrower
            // than YouTube — the banner needs aggressive size scaling
            // and shorter copy to keep title + hint + button readable
            // instead of breaking mid-word and truncating to "Try to r…".
            let narrow = geo.size.width < 360
            ZStack {
                Color.black.opacity(0.78)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    content(narrow: narrow)
                        .padding(.horizontal, narrow ? 10 : 20)
                        .padding(.vertical, narrow ? 14 : 20)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func content(narrow: Bool) -> some View {
        let titleSize: CGFloat = narrow ? 12 : 14
        let hintSize: CGFloat = narrow ? 9.5 : 11
        let iconSize: CGFloat = narrow ? 22 : 30
        let buttonSize: CGFloat = narrow ? 10.5 : 12

        if let status = model.reconnectAttemptStatus {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text(String(format: model.t(.iPhoneReconnectingAttempt), status))
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
        } else if model.reconnectExhausted {
            VStack(spacing: narrow ? 8 : 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: narrow ? 20 : 26))
                    .foregroundStyle(.orange)
                Text(model.t(.iPhoneReconnectExhaustedTitle))
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.t(.iPhoneReconnectExhaustedHint))
                    .font(.system(size: hintSize))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(narrow ? .center : .leading)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, narrow ? 4 : 16)
                reconnectButton(label: .iPhoneReconnectTryAgain,
                                fontSize: buttonSize, narrow: narrow) {
                    model.reconnectExhausted = false
                    Task { await model.forceIPhoneReconnect() }
                }
                .padding(.top, 4)
                if !narrow {
                    Text(model.t(.iPhoneReconnectStillWatching))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
            }
        } else {
            VStack(spacing: narrow ? 8 : 10) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: iconSize))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.pulse, options: .repeating)
                Text(model.t(.iPhoneReconnectingTitle))
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.t(narrow ? .iPhoneReconnectingHintShort
                                   : .iPhoneReconnectingHint))
                    .font(.system(size: hintSize))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, narrow ? 4 : 24)
                reconnectButton(label: narrow ? .iPhoneReconnectButtonShort
                                              : .iPhoneReconnectButton,
                                fontSize: buttonSize, narrow: narrow) {
                    Task { await model.forceIPhoneReconnect() }
                }
                .padding(.top, 4)
            }
        }
    }

    /// Compact button. On narrow canvases drops the SF Symbol prefix and
    /// allows the text to scale — `Label` truncates to "Try to r…" otherwise.
    @ViewBuilder
    private func reconnectButton(label: LKey, fontSize: CGFloat,
                                 narrow: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if !narrow { Image(systemName: "arrow.clockwise") }
                Text(model.t(label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.system(size: fontSize, weight: .medium))
            .padding(.horizontal, narrow ? 4 : 0)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(narrow ? .small : .regular)
        .tint(.blue)
    }
}

/// Border overlay that paints the stroke/gradient/glow on top of a clipped
/// CameraPreview. Side is passed in so the view never has to wait for a
/// GeometryReader to measure — avoids a blank first frame when switching
/// between layouts (e.g. coming back to YouTube from Reels).
private struct ShapedBorderOverlay: View {
    let shape: PIPShape
    let border: PIPBorder
    let side: CGFloat

    var body: some View {
        if let color = border.swiftUIColor {
            // Proportional to the slot diameter so it matches the recording.
            content(color: color, width: border.strokeWidth(forDiameter: side), side: side)
        }
    }

    @ViewBuilder
    private func content(color: Color, width w: CGFloat, side: CGFloat) -> some View {
        switch border.style {
        case .none:
            EmptyView()
        case .solid:
            shape.anyShape().stroke(color, lineWidth: w)
        case .gradient:
            let palette = PIPBorder.gradientPalette(from: border.color, to: border.color2)
                .map { Color(cgColor: $0) }
            shape.anyShape().stroke(
                AngularGradient(gradient: Gradient(colors: palette),
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)),
                lineWidth: w
            )
        case .chrome:
            let chrome = PIPBorder.chromePalette.map { Color(cgColor: $0) }
            let locs: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
            shape.anyShape().stroke(
                LinearGradient(
                    stops: zip(chrome, locs).map { .init(color: $0, location: $1) },
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: w
            )
        case .neon:
            shape.anyShape()
                .stroke(color, lineWidth: w)
                .shadow(color: color, radius: w * 4)
                .shadow(color: color, radius: w * 2)
                .shadow(color: color, radius: w)
        case .glow:
            shape.anyShape()
                .stroke(color, lineWidth: max(1, w * 0.8))
                .shadow(color: color, radius: w * 2)
        }
    }
}
