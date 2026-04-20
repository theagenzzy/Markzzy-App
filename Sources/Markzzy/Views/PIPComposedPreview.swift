import SwiftUI
import AVFoundation

/// Shows the simulated output: a dark canvas (aspect of the target screen)
/// with the live camera drawn at the chosen shape/position/size/border.
/// The PIP is draggable; snaps near corners and center-lines.
struct PIPComposedPreview: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let aspect = screenAspect()
            let canvas = fitted(aspect: aspect, in: geo.size)
            let canvasOrigin = CGPoint(
                x: (geo.size.width - canvas.width) / 2,
                y: (geo.size.height - canvas.height) / 2
            )

            ZStack(alignment: .topLeading) {
                backdrop
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvasOrigin.x, y: canvasOrigin.y)

                if model.selectedCamera != nil {
                    pip(canvas: canvas, origin: canvasOrigin)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private var isRecording: Bool {
        if case .recording = model.state { return true } else { return false }
    }

    // MARK: - Parts

    @ViewBuilder
    private var backdrop: some View {
        if let img = model.screenPreviewImage {
            Image(decorative: img, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.underPageBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "display").font(.title2).foregroundStyle(.tertiary)
                        Text(model.t(.screenPreview)).font(.caption).foregroundStyle(.tertiary)
                    }
                )
        }
    }

    @ViewBuilder
    private func pip(canvas: CGSize, origin: CGPoint) -> some View {
        let pipW = canvas.width * model.pipSize
        // Match compositor: non-rectangular shapes are square (centered crop).
        let pipH: CGFloat = model.pipShape == .rectangle
            ? pipW / cameraAspect()
            : pipW

        // Clamp preview so the PIP never escapes the canvas (matches the
        // compositor's padding behavior during recording).
        let pad: CGFloat = (model.pipBorder.cgColor != nil) ? model.pipBorder.lineWidth : 4
        let rawX = origin.x + model.pipPosition.x * canvas.width
        let rawY = origin.y + model.pipPosition.y * canvas.height
        let minX = origin.x + pipW / 2 + pad
        let maxX = origin.x + canvas.width  - pipW / 2 - pad
        let minY = origin.y + pipH / 2 + pad
        let maxY = origin.y + canvas.height - pipH / 2 - pad
        let centerX = min(max(rawX, minX), maxX)
        let centerY = min(max(rawY, minY), maxY)

        Group {
            if isRecording {
                // Composed frame in the backdrop already has the camera. Show a
                // dashed guide so the user can still drag to reposition.
                model.pipShape.anyShape()
                    .stroke(
                        Color.white.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .background(Color.white.opacity(0.05))
                    .frame(width: pipW, height: pipH)
            } else {
                ShapedCamera(shape: model.pipShape, border: model.pipBorder)
                    .environmentObject(model)
                    .frame(width: pipW, height: pipH)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
        }
        .position(x: centerX, y: centerY)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let nx = (value.location.x - origin.x) / canvas.width
                    let ny = (value.location.y - origin.y) / canvas.height
                    model.pipPosition = CGPoint(
                        x: snap(clamp(nx), anchors: [0.12, 0.5, 0.88], threshold: 0.04),
                        y: snap(clamp(ny), anchors: [0.12, 0.5, 0.88], threshold: 0.04)
                    )
                }
        )
    }

    // MARK: - Helpers

    private func fitted(aspect: CGFloat, in container: CGSize) -> CGSize {
        let ca = container.width / container.height
        return aspect > ca
            ? CGSize(width: container.width, height: container.width / aspect)
            : CGSize(width: container.height * aspect, height: container.height)
    }

    private func screenAspect() -> CGFloat {
        if let s = model.selectedScreen, s.height > 0 {
            return CGFloat(s.width) / CGFloat(s.height)
        }
        return 16.0 / 10.0
    }

    private func cameraAspect() -> CGFloat {
        // iPhone Continuity is typically portrait-ish 4:3 rotated;
        // builtin is 16:9 or 4:3. Default to 4:3 landscape.
        return 4.0 / 3.0
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0.05), 0.95) }

    private func snap(_ v: CGFloat, anchors: [CGFloat], threshold: CGFloat) -> CGFloat {
        for a in anchors where abs(v - a) < threshold { return a }
        return v
    }
}

/// Wraps CameraPreview with the chosen shape clip and border stroke.
private struct ShapedCamera: View {
    @EnvironmentObject var model: AppModel
    let shape: PIPShape
    let border: PIPBorder

    @ViewBuilder
    func borderOverlay(color: Color, width w: CGFloat, side: CGFloat) -> some View {
        switch border.style {
        case .none:
            EmptyView()
        case .solid:
            shape.anyShape().stroke(color, lineWidth: w)
        case .gradient:
            let palette = PIPBorder.gradientPalette(from: border.color, to: border.color2)
                .map { Color(cgColor: $0) }
            shape.anyShape().stroke(
                AngularGradient(
                    gradient: Gradient(colors: palette),
                    center: .center,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(270)
                ),
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
                    startPoint: .top,
                    endPoint: .bottom
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

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let camera = CameraPreview(session: model.previewSession)
            ZStack {
                if shape.usesSoftMask {
                    camera.mask(
                        RadialGradient(
                            colors: [.white, .white, .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: side / 2
                        )
                    )
                } else {
                    camera
                        .compositingGroup()
                        .mask(shape.anyShape())
                }

                if let color = border.swiftUIColor, !shape.usesSoftMask {
                    borderOverlay(color: color, width: border.lineWidth, side: side)
                }
            }
        }
    }
}
