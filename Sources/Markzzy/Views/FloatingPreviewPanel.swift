import AppKit
import SwiftUI
import Combine

/// Floating, always-on-top preview of the COMPOSED output (reel/post) shown while
/// recording — so the user can see the result even when recording full-screen and
/// the main app window isn't visible. Excluded from the recording
/// (`sharingType = .none`) to avoid a mirror/feedback loop. Draggable + resizable,
/// with a hover control pill: switch view (layout), pause/stop, collapse.
final class FloatingPreviewPanel: NSPanel {

    /// Initial/min height of the docked control bar BELOW the video. The actual
    /// height is dynamic (`currentBarHeight`) — pipOverlay shows a second row
    /// (size + background) so the bar grows and the panel resizes to fit.
    static let barHeight: CGFloat = 72

    /// Called when the user taps the hide (eye) control — the app then exposes a
    /// "show floating preview" button to bring it back.
    var onHide: (() -> Void)?

    private let previewLayer = CALayer()
    private var controlsHost: NSHostingView<FloatingPreviewControls>?
    private var cancellable: AnyCancellable?
    private var layoutCancellable: AnyCancellable?
    private var currentBarHeight: CGFloat = FloatingPreviewPanel.barHeight
    private let aspect: CGFloat          // canvas w/h (reel 9:16, post 1:1)
    private var expandedFrame: NSRect = .zero
    private weak var model: AppModel?

    init(initialFrame: NSRect, aspect: CGFloat, model: AppModel) {
        self.aspect = aspect
        self.model = model
        super.init(contentRect: initialFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none                // <- never recorded (no feedback loop)
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        expandedFrame = initialFrame

        let content = PreviewContentView(frame: NSRect(origin: .zero, size: initialFrame.size))
        content.wantsLayer = true
        content.layer?.masksToBounds = false
        content.layer?.shadowColor = NSColor.black.cgColor
        content.layer?.shadowOpacity = 0.45
        content.layer?.shadowRadius = 14
        content.layer?.shadowOffset = CGSize(width: 0, height: -3)
        content.onMove = { [weak self] dx, dy in self?.moveBy(dx: dx, dy: dy) }
        content.onResize = { [weak self] d in self?.resizeBy(d) }
        content.onHover = { [weak self] inside in self?.setControlsVisible(inside) }
        // Drag the pipOverlay circle to reposition / resize it live.
        content.pipCircleRect = { [weak self] in self?.pipCircleRect() }
        content.onPipMove = { [weak self] dx, dy in self?.handlePipMove(dx, dy) }
        content.onPipResize = { [weak self] p in self?.handlePipResize(p) }
        content.onPipEditBegin = { [weak self] in self?.model?.beginPipLiveEdit() }
        content.onPipEditEnd = { [weak self] in self?.model?.endPipLiveEdit() }
        contentView = content

        previewLayer.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        previewLayer.cornerRadius = 12
        previewLayer.masksToBounds = true
        previewLayer.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        previewLayer.borderWidth = 1
        previewLayer.contentsGravity = .resizeAspect
        content.layer?.addSublayer(previewLayer)

        let host = NSHostingView(rootView: FloatingPreviewControls(
            model: model, onHide: { [weak self] in self?.onHide?() }))
        host.alphaValue = 1                 // docked bar — always visible
        content.addSubview(host)
        controlsHost = host

        // Live composed frame → preview layer.
        cancellable = model.$screenPreviewImage
            .receive(on: RunLoop.main)
            .sink { [weak self] img in
                guard let self else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.previewLayer.contents = img
                CATransaction.commit()
            }

        // Re-fit the bar (and the panel height) when the layout changes — pipOverlay
        // adds a second control row, the others drop it.
        layoutCancellable = model.$layout
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncBarHeight() }   // after SwiftUI re-renders
            }

        layoutContent()
        DispatchQueue.main.async { [weak self] in self?.syncBarHeight() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func teardown() {
        cancellable?.cancel(); cancellable = nil
        layoutCancellable?.cancel(); layoutCancellable = nil
        orderOut(nil)
        close()
    }

    /// Match the bar height to the controls' natural size (1 vs 2 rows) and resize
    /// the panel (keep the top-left corner fixed; video keeps the canvas aspect).
    private func syncBarHeight() {
        guard let host = controlsHost else { return }
        host.layoutSubtreeIfNeeded()
        let desired = max(34, host.fittingSize.height + 12)
        if abs(desired - currentBarHeight) > 0.5 {
            currentBarHeight = desired
            let f = frame
            let topY = f.maxY
            let newH = f.width / aspect + currentBarHeight
            setFrame(NSRect(x: f.minX, y: topY - newH, width: f.width, height: newH), display: true)
            expandedFrame = frame
        }
        layoutContent()
    }

    func setVisible(_ visible: Bool) {
        if visible { orderFrontRegardless() } else { orderOut(nil) }
    }

    /// The video region (top of the panel; the docked control bar is below it).
    private func videoRect(_ b: NSRect) -> NSRect {
        NSRect(x: 0, y: currentBarHeight, width: b.width,
               height: max(0, b.height - currentBarHeight))
    }

    /// The pipOverlay circle rect in content-view coords (nil if not pipOverlay).
    private func pipCircleRect() -> NSRect? {
        guard let m = model, m.layout == .pipOverlay, let b = contentView?.bounds, b.width > 0
        else { return nil }
        let vr = videoRect(b)
        let pipW = m.pipSize * vr.width
        let cx = vr.minX + m.pipPosition.x * vr.width
        let cy = vr.minY + (1 - m.pipPosition.y) * vr.height   // top-left → AppKit bottom-left
        return NSRect(x: cx - pipW / 2, y: cy - pipW / 2, width: pipW, height: pipW)
    }

    private func handlePipMove(_ dx: CGFloat, _ dy: CGFloat) {
        guard let b = contentView?.bounds else { return }
        let vr = videoRect(b)
        guard vr.width > 0, vr.height > 0 else { return }
        model?.nudgePip(dxFrac: dx / vr.width, dyFrac: -dy / vr.height) // AppKit y up → pip y down
    }

    /// Drag the circle's edge: set pipSize so the ring follows the cursor radius.
    private func handlePipResize(_ p: NSPoint) {
        guard let m = model, let r = pipCircleRect() else { return }
        let vr = videoRect(contentView?.bounds ?? .zero)
        guard vr.width > 0 else { return }
        let dist = hypot(p.x - r.midX, p.y - r.midY)
        m.nudgePipSize(dFrac: (2 * dist) / vr.width - m.pipSize)
    }

    // MARK: - Move / resize

    private func moveBy(dx: CGFloat, dy: CGFloat) {
        var f = frame
        f.origin.x += dx; f.origin.y += dy
        if let v = (screen ?? NSScreen.main)?.frame {
            f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
            f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        }
        setFrame(f, display: true)
        expandedFrame = f
    }

    /// Resize keeping the top-left corner fixed; video height follows the canvas
    /// aspect, plus the fixed docked control bar below it.
    private func resizeBy(_ delta: CGFloat) {
        let minW: CGFloat = 140, maxW: CGFloat = 900
        let f = frame
        let topY = f.maxY
        let newW = min(max(f.width + delta, minW), maxW)
        let newH = newW / aspect + currentBarHeight
        let newFrame = NSRect(x: f.minX, y: topY - newH, width: newW, height: newH)
        setFrame(newFrame, display: true)
        expandedFrame = newFrame
        layoutContent()
    }

    // MARK: - Layout

    private func layoutContent() {
        guard let content = contentView else { return }
        let b = content.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = videoRect(b)          // video occupies the top region
        CATransaction.commit()
        if let host = controlsHost {
            let w = host.fittingSize.width > 0 ? host.fittingSize.width : 220
            let h = host.fittingSize.height > 0 ? host.fittingSize.height : 32
            // Docked nav: centered in the bar strip BELOW the video (YouTube-style).
            host.frame = NSRect(x: (b.width - w) / 2, y: (currentBarHeight - h) / 2, width: w, height: h)
        }
    }

    private func setControlsVisible(_ visible: Bool) {
        // Docked bar stays visible; hover no longer toggles it.
        controlsHost?.alphaValue = 1
    }
}

/// Content view: drag to move (anywhere) / corner to resize; tracks hover. No
/// `hitTest` override so the control pill's buttons receive their own clicks.
private final class PreviewContentView: NSView {
    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onHover: ((Bool) -> Void)?
    var pipCircleRect: (() -> NSRect?)?            // pipOverlay circle in view coords, else nil
    var onPipMove: ((CGFloat, CGFloat) -> Void)?   // drag delta (AppKit px) → move the pip
    var onPipResize: ((NSPoint) -> Void)?          // cursor in view coords → resize the pip
    var onPipEditBegin: (() -> Void)?              // pip gesture started (suspend saves)
    var onPipEditEnd: (() -> Void)?                // pip gesture ended (persist once)

    private enum DragMode { case move, resize, pip, pipResize }
    private var lastMouse: NSPoint = .zero
    private var mode: DragMode = .move
    private let cornerZone: CGFloat = 30
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent)  { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        lastMouse = NSEvent.mouseLocation
        let p = convert(event.locationInWindow, from: nil)
        if p.x > bounds.maxX - cornerZone && p.y < cornerZone {
            mode = .resize
        } else if let r = pipCircleRect?() {
            let radius = r.width / 2
            let dist = hypot(p.x - r.midX, p.y - r.midY)
            let band = max(14, radius * 0.28)        // outer ring → resize
            if dist <= radius + band && dist >= radius - band {
                mode = .pipResize                    // grab the edge → resize circle
                onPipEditBegin?()
            } else if dist < radius - band {
                mode = .pip                          // grab the inside → move circle
                onPipEditBegin?()
            } else {
                mode = .move                         // outside the circle → move panel
            }
        } else {
            mode = .move                             // drag the whole panel
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - lastMouse.x, dy = now.y - lastMouse.y
        lastMouse = now
        switch mode {
        case .resize:    onResize?(dx - dy)
        case .pip:       onPipMove?(dx, dy)
        case .pipResize: onPipResize?(convert(event.locationInWindow, from: nil))
        case .move:      onMove?(dx, dy)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if mode == .pip || mode == .pipResize { onPipEditEnd?() }
        mode = .move
    }
    override var acceptsFirstResponder: Bool { true }
}

/// Hover control pill: view switcher + pause/resume + stop + collapse.
private struct FloatingPreviewControls: View {
    @ObservedObject var model: AppModel
    let onHide: () -> Void

    private let layouts: [Layout] = [.pipOverlay, .splitScreenTop, .splitCamTop, .cameraOnly, .screenOnly]

    var body: some View {
        VStack(spacing: 6) {
            // Row 1 (pipOverlay only): camera size + background (transparent/color).
            if model.layout == .pipOverlay {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: $model.pipSize, in: 0.10...model.pipSizeMax) { editing in
                        editing ? model.beginPipLiveEdit() : model.endPipLiveEdit()
                    }
                    .controlSize(.mini)
                    .frame(width: 88)
                    .tint(.white)
                    Text("\(Int(model.pipSize * 100))%")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, alignment: .trailing)
                    bar
                    backgroundMenu
                }
            }
            // Row 2: view switcher + transport.
            HStack(spacing: 5) {
                ForEach(layouts) { l in
                    Button { model.layout = l } label: {
                        Image(systemName: l.sfSymbol).font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.layout == l ? Color.white : Color.white.opacity(0.6))
                    .background(model.layout == l ? Color.accentColor.opacity(0.9) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
                bar
                if model.state == .paused {
                    ctl("play.fill", .white) { model.resumeRecording() }
                } else {
                    ctl("pause.fill", .white) { model.pauseRecording() }
                }
                ctl("stop.fill", .red) { Task { await model.toggleRecording() } }
                bar
                ctl("eye.slash", .white.opacity(0.7)) { onHide() }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    /// Background mode for the floating circle: Transparent (silhouette over the
    /// screen) vs Color (shaped, color behind) + the color. Mirrors the main panel.
    private var backgroundMenu: some View {
        Menu {
            Button { model.faceCamBgTransparent = true } label: {
                Label(model.t(.bgModeTransparent),
                      systemImage: model.faceCamBgTransparent ? "checkmark" : "circle.dotted")
            }
            Button { model.faceCamBgTransparent = false } label: {
                Label(model.t(.bgModeColor),
                      systemImage: !model.faceCamBgTransparent ? "checkmark" : "circle.fill")
            }
            if !model.faceCamBgTransparent {
                Divider()
                ColorPicker(model.t(.bgColorLabel), selection: Binding(
                    get: { Color(cgColor: model.faceCamBgColor) },
                    set: { model.faceCamBgColor = NSColor($0).cgColor }
                ))
            }
        } label: {
            Image(systemName: model.faceCamBgTransparent ? "circle.dotted" : "paintpalette.fill")
                .font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 20)
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var bar: some View {
        Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16).padding(.horizontal, 1)
    }
    private func ctl(_ name: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
    }
}
