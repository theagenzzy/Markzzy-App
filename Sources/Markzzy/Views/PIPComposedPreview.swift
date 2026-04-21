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
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                                .onChanged { value in
                                    let nx = (value.location.x - origin.x) / canvas.width
                                    let ny = (value.location.y - origin.y) / canvas.height
                                    model.pipPosition = CGPoint(
                                        x: snap(clamp(nx), anchors: [0.12, 0.5, 0.88], threshold: 0.04),
                                        y: snap(clamp(ny), anchors: [0.12, 0.5, 0.88], threshold: 0.04)
                                    )
                                }
                        )
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
                cameraView(frame: c)
                    .opacity((!model.composedFrameActive && model.layout.usesCamera) ? 1 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "canvas")
        }
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0.05), 0.95) }
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
        let offsetX: CGFloat
        switch model.screenAnchor {
        case .left:   offsetX = 0
        case .center: offsetX = (slot.width - scaledW) / 2
        case .right:  offsetX = slot.width - scaledW
        }
        let offsetY = (slot.height - scaledH) / 2
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
                CameraPreview(session: model.previewSession)
                    .compositingGroup()
                    .mask(cameraMask)
                if isOverlay, !model.pipShape.usesSoftMask, model.pipBorder.style != .none {
                    ShapedBorderOverlay(
                        shape: model.pipShape,
                        border: model.pipBorder,
                        side: min(c.width, c.height)
                    )
                    .frame(width: c.width, height: c.height)
                }
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
                RadialGradient(
                    colors: [.white, .white, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 1000
                )
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
        let pipH: CGFloat = model.pipShape == .rectangle ? pipW / cameraAspect() : pipW
        let pad: CGFloat = (model.pipBorder.cgColor != nil) ? model.pipBorder.lineWidth : 4
        let rawX = origin.x + model.pipPosition.x * canvas.width
        let rawY = origin.y + model.pipPosition.y * canvas.height
        let minX = origin.x + pipW / 2 + pad
        let maxX = origin.x + canvas.width  - pipW / 2 - pad
        let minY = origin.y + pipH / 2 + pad
        let maxY = origin.y + canvas.height - pipH / 2 - pad
        let cX = min(max(rawX, minX), maxX)
        let cY = min(max(rawY, minY), maxY)
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

    private func cameraAspect() -> CGFloat { 4.0 / 3.0 }

    private func fitted(aspect: CGFloat, in container: CGSize) -> CGSize {
        let ca = container.width / container.height
        return aspect > ca
            ? CGSize(width: container.width, height: container.width / aspect)
            : CGSize(width: container.height * aspect, height: container.height)
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
            content(color: color, width: border.lineWidth, side: side)
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
            shape.anyShape().stroke(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: Color(white: 0.88), location: 0.3),
                        .init(color: Color(white: 0.45), location: 0.5),
                        .init(color: Color(white: 0.88), location: 0.7),
                        .init(color: .white, location: 1),
                    ],
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
