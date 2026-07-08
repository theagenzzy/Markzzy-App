import AppKit
import AVFoundation
import SwiftUI
import CoreImage
import CoreVideo

/// Loom-style floating camera bubble shown ONLY during recording in the
/// YouTube / pipOverlay layout.
///
/// It floats above every app and Space, is EXCLUDED from the screen capture
/// (`sharingType = .none`, so ScreenCaptureKit never records it → no duplicated
/// camera in the file), can be dragged (move) and corner-dragged (resize), and
/// carries a Loom-style control pill (size S/M/L, shape, mirror) that appears on
/// hover. Its on-screen frame drives `pipPosition` / `pipSize` live via
/// `onFrameChange`, so the recorded camera follows the bubble in real time.
final class FloatingCameraPanel: NSPanel {

    /// Fired continuously while the user moves/resizes the bubble (global coords).
    var onFrameChange: ((NSRect) -> Void)?
    /// Loom control callbacks.
    var onSizePreset: ((CGFloat) -> Void)?   // fraction of canvas width
    var onToggleShape: (() -> Void)?
    var onToggleMirror: (() -> Void)?

    private let cameraContainer = CALayer()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let ringLayer = CALayer()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Current visual params (kept so layout/resize can re-render the ring).
    private var shapeKind: PIPShape = .circle
    private var border: PIPBorder = PIPBorder()
    private var mirrorPending: Bool?

    private var controlsHost: NSHostingView<AnyView>?
    private var controlsNaturalSize: CGSize = .zero

    /// Window == the camera circle (no header). The Loom-style control pill is
    /// overlaid INSIDE the bottom of the circle (see `layoutBubble`).
    private func windowFrame(forCircle c: NSRect) -> NSRect { c }

    /// The camera circle == the whole content view.
    private var circleRect: NSRect {
        NSRect(origin: .zero, size: contentView?.bounds.size ?? frame.size)
    }

    init(initialFrame: NSRect) {
        // Window == the camera circle (the control pill overlays its bottom).
        let wf = initialFrame
        super.init(contentRect: wf,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        // The SYSTEM window shadow renders as a rounded-RECT halo around the
        // square window (the "second border"). Turn it off and draw our own
        // shape-matched shadow on the content layer instead.
        hasShadow = false
        // NOTE: we intentionally do NOT set `sharingType = .none`. The bubble is
        // excluded from OUR recording via SCContentFilter (so it never doubles in
        // the file) but stays visible to normal macOS screenshots.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false

        let content = BubbleContentView(frame: NSRect(origin: .zero, size: wf.size))
        content.wantsLayer = true
        content.focusRingType = .none
        content.layer?.masksToBounds = false   // let glow/neon extend past the shape
        // Custom shape-matched soft shadow (replaces the system rounded-rect one).
        content.layer?.shadowColor = NSColor.black.cgColor
        content.layer?.shadowOpacity = 0.45
        content.layer?.shadowRadius = 12
        content.layer?.shadowOffset = CGSize(width: 0, height: -3)
        content.onMove = { [weak self] dx, dy in self?.moveBubble(dx: dx, dy: dy) }
        content.onResize = { [weak self] delta in self?.resizeBubble(by: delta) }
        content.onHover = { [weak self] inside in self?.setControlsVisible(inside) }
        contentView = content

        // Camera lives inside an opaque, shape-clipped container with a DARK
        // background → no see-through bubble during warm-up, and the window's
        // alpha equals the shape so the system shadow follows it (no stray
        // rounded-rect outline).
        cameraContainer.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        cameraContainer.masksToBounds = true
        content.layer?.addSublayer(cameraContainer)

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.masksToBounds = true
        cameraContainer.addSublayer(previewLayer)

        ringLayer.contentsGravity = .resize
        ringLayer.zPosition = 1                // above the camera container
        content.layer?.addSublayer(ringLayer)

        // Loom control pill (hidden until hover). Sized at its natural size; the
        // pill scales down (scaleEffect) when the circle is too small to fit it.
        let host = NSHostingView(rootView: controlsView(scale: 1))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.alphaValue = 0
        controlsNaturalSize = host.fittingSize
        content.addSubview(host)
        controlsHost = host

        layoutBubble()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The control pill, scaled so it always fits inside the circle.
    private func controlsView(scale: CGFloat) -> AnyView {
        AnyView(
            BubbleControls(
                // Fractions of the current size max (not absolute) so S/M/L span
                // the same range as the main + floating-preview sliders — "Large"
                // is actually large. AppModel multiplies by pipSizeMax.
                onSmall:  { [weak self] in self?.onSizePreset?(0.25) },
                onMedium: { [weak self] in self?.onSizePreset?(0.50) },
                onLarge:  { [weak self] in self?.onSizePreset?(0.85) },
                onShape:  { [weak self] in self?.onToggleShape?() },
                onMirror: { [weak self] in self?.onToggleMirror?() }
            )
            .scaleEffect(scale, anchor: .center)
        )
    }

    /// Attach the live recording camera feed (called after `pipe.start()`).
    func attach(session: AVCaptureSession) {
        previewLayer.session = session
        if let pending = mirrorPending { setMirror(pending); mirrorPending = nil }
    }

    /// Release the camera session (called before closing) so the device is freed
    /// immediately for the preview restore / next recording.
    func detach() {
        previewLayer.session = nil
    }

    func setMirror(_ on: Bool) {
        guard let conn = previewLayer.connection, conn.isVideoMirroringSupported else {
            mirrorPending = on
            return
        }
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = on
    }

    /// Push the model's frame/shape/border/mirror onto the bubble (keeps the
    /// bubble synced when the slider / S-M-L / shape controls change the model).
    func applyFromModel(frame circle: NSRect, shape: PIPShape, border: PIPBorder, mirror: Bool) {
        self.shapeKind = shape
        self.border = border
        let wf = windowFrame(forCircle: circle)
        if abs(wf.width - self.frame.width) > 0.5 || abs(wf.height - self.frame.height) > 0.5
            || abs(wf.minX - self.frame.minX) > 0.5 || abs(wf.minY - self.frame.minY) > 0.5 {
            setFrame(wf, display: true)
        }
        setMirror(mirror)
        layoutBubble()
    }

    // MARK: - Move / resize

    private func moveBubble(dx: CGFloat, dy: CGFloat) {
        var f = frame
        f.origin.x += dx
        f.origin.y += dy
        if let v = (screen ?? NSScreen.main)?.frame {
            f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
            f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        }
        setFrame(f, display: true)
        layoutBubble()
        onFrameChange?(f)
    }

    /// Resize the CIRCLE keeping its center fixed; the window re-derives (adds the
    /// header again if it becomes small).
    private func resizeBubble(by delta: CGFloat) {
        let minSide: CGFloat = 90, maxSide: CGFloat = 700
        // Current circle = bottom square of the window.
        let f = frame
        let oldSide = f.width
        let cx = f.minX + oldSide / 2
        let cy = f.minY + oldSide / 2
        let newSide = min(max(oldSide + delta, minSide), maxSide)
        let circle = NSRect(x: cx - newSide / 2, y: cy - newSide / 2,
                            width: newSide, height: newSide)
        setFrame(windowFrame(forCircle: circle), display: true)
        layoutBubble()
        onFrameChange?(frame)
    }

    // MARK: - Layout

    private func cornerRadius(for side: CGFloat) -> CGFloat {
        switch shapeKind {
        case .circle, .softEdge: return side / 2
        case .squircle:          return side * 0.24
        case .roundedRect:       return side * 0.12   // matches the Metal shader
        default:                 return 0             // rectangle
        }
    }

    private func layoutBubble() {
        guard contentView != nil else { return }
        let c = circleRect                       // camera area = bottom square
        let r = cornerRadius(for: min(c.width, c.height))
        // Disable implicit animations so move/resize tracks the cursor 1:1.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cameraContainer.frame = c
        cameraContainer.cornerRadius = r
        previewLayer.frame = cameraContainer.bounds
        previewLayer.cornerRadius = r
        // Shape-matched shadow path on the CIRCLE (no rounded-rect halo).
        contentView?.layer?.shadowPath = CGPath(roundedRect: c, cornerWidth: r,
                                                cornerHeight: r, transform: nil)
        updateRingLayer(bounds: c)
        CATransaction.commit()

        if let host = controlsHost {
            let natW = controlsNaturalSize.width > 0 ? controlsNaturalSize.width : 160
            let natH = controlsNaturalSize.height > 0 ? controlsNaturalSize.height : 32
            // Loom-style: the pill OVERLAPS the bottom of the circle, raised to
            // ~24% from the bottom where the circle is wide enough → stays INSIDE
            // the camera, never touches the border ring, nothing above the circle.
            let rad = min(c.width, c.height) / 2
            let cyCenter = max(c.height * 0.24, natH / 2 + 6)
            let chord = 2 * sqrt(max(0, rad * rad - (rad - cyCenter) * (rad - cyCenter)))
            let scale = min(1, (chord * 0.82) / natW)
            host.rootView = controlsView(scale: scale)
            // Frame stays natural-sized & centered; scaleEffect shrinks the pill
            // visually within it so it fits the circle.
            host.frame = NSRect(x: (c.width - natW) / 2, y: cyCenter - natH / 2,
                                width: natW, height: natH)
        }
    }

    /// Render the ring with the SHARED BorderRenderer so the bubble matches the
    /// recording for every style. nil border → clear.
    private func updateRingLayer(bounds b: CGRect) {
        guard border.style != .none, border.width > 0, b.width >= 1, b.height >= 1,
              let (buf, pad) = BorderRenderer.makeRing(
                shape: shapeKind, style: border.style,
                width: b.width, height: b.height,
                color: border.color, color2: border.color2,
                lineWidth: border.strokeWidth(forDiameter: min(b.width, b.height))),
              let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: buf),
                                               from: CGRect(x: 0, y: 0,
                                                            width: CVPixelBufferGetWidth(buf),
                                                            height: CVPixelBufferGetHeight(buf)))
        else {
            ringLayer.contents = nil
            return
        }
        ringLayer.contents = cg
        ringLayer.frame = CGRect(x: -pad, y: -pad, width: b.width + 2 * pad, height: b.height + 2 * pad)
    }

    private func setControlsVisible(_ visible: Bool) {
        guard let host = controlsHost else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            host.animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// Content view: turns drags into move (anywhere) or resize (bottom-right
/// corner). Tracks GLOBAL mouse location so deltas stay correct as the window
/// moves under the cursor. No `hitTest` override → the control pill's buttons
/// receive their own clicks; drags land on the empty camera area.
private final class BubbleContentView: NSView {
    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onHover: ((Bool) -> Void)?

    private var lastMouse: NSPoint = .zero
    private var resizing = false
    private let cornerZone: CGFloat = 30
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent)  { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        lastMouse = NSEvent.mouseLocation
        let p = convert(event.locationInWindow, from: nil)
        // AppKit origin is bottom-left → bottom-right corner = (maxX, minY).
        resizing = (p.x > bounds.maxX - cornerZone && p.y < cornerZone)
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - lastMouse.x
        let dy = now.y - lastMouse.y
        lastMouse = now
        if resizing {
            onResize?(dx - dy)   // drag toward bottom-right grows
        } else {
            onMove?(dx, dy)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

/// The Loom-style control pill rendered under the bubble.
private struct BubbleControls: View {
    let onSmall: () -> Void
    let onMedium: () -> Void
    let onLarge: () -> Void
    let onShape: () -> Void
    let onMirror: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            pill("S", action: onSmall)
            pill("M", action: onMedium)
            pill("L", action: onLarge)
            Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 18)
                .padding(.horizontal, 2)
            icon("square.on.circle", action: onShape)
            icon("arrow.left.and.right", action: onMirror)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private func pill(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 15, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func icon(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
