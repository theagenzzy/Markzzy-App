import Foundation
import AVFoundation
import AppKit
import Combine
import CoreGraphics

@MainActor
public final class AppModel: ObservableObject {
    public enum State: Equatable { case idle, preparing, recording, paused, finishing, done(URL), failed(String) }

    @Published public var state: State = .idle

    /// True while a recording is in progress (recording or paused) — used to
    /// finalize the file before the app terminates.
    public var isActivelyRecording: Bool {
        switch state { case .recording, .paused, .preparing, .finishing: return true; default: return false }
    }

    @Published public var screenSources: [ScreenSource] = []
    @Published public var cameras: [AVCaptureDevice] = []
    @Published public var microphones: [AVCaptureDevice] = []

    /// User-controlled filter that decides which devices show up in the UI
    /// pickers. Persisted across launches.
    @Published public var deviceFilter: DeviceFilter = AppModel.loadDeviceFilter() {
        didSet {
            UserDefaults.standard.set(deviceFilter.hideVirtualDevices == false, forKey: Keys.showAllDevices)
            UserDefaults.standard.set(Array(deviceFilter.hiddenDeviceIDs), forKey: Keys.hiddenDeviceIDs)
            UserDefaults.standard.set(deviceFilter.allowVirtualCameras, forKey: Keys.allowVirtualCameras)
            // Re-enumerate so any newly-revealed/hidden device is reflected.
            cameras = CameraCapture.listDevices(filter: deviceFilter)
            microphones = AudioCapture.listDevices(filter: deviceFilter)
            // Repair selection if currently selected device is now hidden.
            if let cam = selectedCamera, !cameras.contains(where: { $0.uniqueID == cam.uniqueID }) {
                selectedCamera = cameras.first
            }
            if let mic = selectedMic, !microphones.contains(where: { $0.uniqueID == mic.uniqueID }) {
                selectedMic = microphones.first
            }
        }
    }

    public func hideDevice(uniqueID: String) {
        var f = deviceFilter
        f.hiddenDeviceIDs.insert(uniqueID)
        deviceFilter = f
    }

    public func unhideDevice(uniqueID: String) {
        var f = deviceFilter
        f.hiddenDeviceIDs.remove(uniqueID)
        deviceFilter = f
    }

    /// All currently-connected devices (ignoring the user's hide filter),
    /// for the Settings UI that lists hidden / detected devices.
    /// Cached as `@Published` so SwiftUI re-renders don't keep re-calling
    /// AVFoundation discovery on every keystroke / button tap. Refreshed
    /// from `handleDeviceChange` and `refreshDevices`, just like
    /// `cameras` / `microphones`.
    ///
    /// Default to empty so `AppModel.init()` is cheap — eagerly calling
    /// `CameraCapture.listAllDevices()` here was the largest cold-start
    /// stall (AVFoundation device enumeration is ~1-3 s on first launch).
    /// `bootstrap()` populates these via `refreshDevices()` after the
    /// first frame is on screen.
    @Published public var allConnectedCameras: [AVCaptureDevice] = []
    @Published public var allConnectedMicrophones: [AVCaptureDevice] = []

    @Published public var selectedScreen: ScreenSource? {
        didSet {
            guard oldValue != selectedScreen, let s = selectedScreen else { return }
            Task { await livePreview.start(for: s) }
        }
    }
    @Published public var selectedCamera: AVCaptureDevice? {
        didSet {
            guard oldValue?.uniqueID != selectedCamera?.uniqueID else { return }
            // Rebind the preview to the new device AND re-assert the effect
            // pipeline (idle-gated). Fixes "switching iPhone→FaceTime doesn't
            // load the cutout first time". No-op while recording.
            reattachPreviewCameraIfIdle()
        }
    }

    /// True when the user has asked for the iPhone slot but no actual
    /// iPhone-like device is bound yet. Drives the "Looking for your
    /// iPhone…" overlay on the preview area. The wake session keeps
    /// AVFoundation's Continuity scan warm in the background while
    /// this is true; the moment KVO surfaces an iPhone we bind it,
    /// `selectedCamera` becomes iPhone-like, and the overlay disappears.
    public var isWaitingForIPhone: Bool {
        guard wantsContinuityCamera else { return false }
        guard let cam = selectedCamera else { return true }
        return !DeviceFilter.looksLikeIPhone(cam)
    }

    /// Set true when the user tapped "Disconnect" on the iPhone (or the
    /// iPhone otherwise dropped from us mid-session). Drives the
    /// disconnect banner with the "Reconnect iPhone" button.
    ///
    /// **Persistent**: once true, stays true across app restarts until
    /// the iPhone is successfully reconnected. We don't time it out —
    /// if the user closed Markzzy after a Disconnect and opens it days
    /// later, they should still see the Reconnect option until they've
    /// actually reconnected, not silently lose the indicator that
    /// something is wrong.
    @Published public var iPhoneRecentlyDisconnected: Bool = UserDefaults.standard.bool(forKey: Keys.iPhoneDisconnectFlag) {
        didSet {
            UserDefaults.standard.set(iPhoneRecentlyDisconnected, forKey: Keys.iPhoneDisconnectFlag)
        }
    }

    /// While `forceIPhoneReconnect()` is running its multi-attempt cycle,
    /// this is set to the human-friendly "attempt X/Y" string. Drives a
    /// progress label in the disconnect banner so the user sees we're
    /// actively trying instead of staring at a frozen button.
    @Published public var reconnectAttemptStatus: String?

    /// Set true after `forceIPhoneReconnect()` finishes all its attempts
    /// without success. The banner switches from the standard "tap
    /// Reconnect" message to extended manual-recovery instructions
    /// (toggle iPhone Settings, power-cycle as last resort).
    @Published public var reconnectExhausted: Bool = false
    /// User wants the iPhone (Continuity Camera) slot. Persisted so the slot
    /// stays "selected" even after macOS drops the device, and we re-bind to
    /// the real iPhone the moment it reappears.
    @Published public var wantsContinuityCamera: Bool = AppModel.loadWantsContinuity() {
        didSet {
            UserDefaults.standard.set(wantsContinuityCamera, forKey: Keys.wantsContinuityCamera)
            // Going off→on (the user just picked the iPhone slot): release
            // whatever camera the preview session was holding so the wake
            // session can claim the built-in camera as its placeholder
            // without fighting over FaceTime HD.
            if wantsContinuityCamera, !oldValue {
                applyPreviewCamera(nil)
                stopContinuityWakeSession()
            }
            updateContinuityPolling()
        }
    }
    @Published public var selectedMic: AVCaptureDevice? {
        didSet {
            guard oldValue?.uniqueID != selectedMic?.uniqueID else { return }
            applyMicMonitor()
        }
    }

    // MARK: - Face cam (persisted when rememberFaceCam is on)

    /// Guard set during a format swap so the bulk reassignment of face-cam
    /// properties doesn't re-persist mid-swap (see `reconcileFaceCam`).
    var isReconcilingFaceCam = false

    @Published public var pipPosition: CGPoint =
        AppModel.liveSizePosition(for: AppModel.loadedFaceCam(for: AppModel.loadFormat())).1 {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }
    @Published public var pipSize: CGFloat =
        AppModel.liveSizePosition(for: AppModel.loadedFaceCam(for: AppModel.loadFormat())).0 {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }
    @Published public var pipShape: PIPShape = AppModel.loadedFaceCam(for: AppModel.loadFormat()).shape {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }
    @Published public var pipBorder: PIPBorder = AppModel.loadedFaceCam(for: AppModel.loadFormat()).border {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }

    /// Background removal (person segmentation). When on, the camera background
    /// is removed: `faceCamBgTransparent` true = floating cutout over the
    /// screen; false = replaced by `faceCamBgColor` inside the shape.
    @Published public var removeBackground: Bool = AppModel.loadedFaceCam(for: AppModel.loadFormat()).removeBackground {
        didSet {
            if removeBackground {
                // Entering removal: transparent ⇒ free silhouette right away
                // (the transparent didSet won't fire if it was already true).
                if faceCamBgTransparent, !faceCamFreeform { faceCamFreeform = true }
            } else {
                // The plain-PIP size slider caps at 40%; clamp back into range.
                if pipSize > 0.40 { pipSize = 0.40 }
            }
            pushBackground(); saveFaceCamIfEnabled(); updatePreviewEffectPipeline()
        }
    }
    @Published public var faceCamBgTransparent: Bool = AppModel.loadedFaceCam(for: AppModel.loadFormat()).bgTransparent {
        didSet {
            guard faceCamBgTransparent != oldValue else { return }
            // Swap size+position to this mode's own saved sub-slot (transparent
            // vs color are independent within a format).
            if !isReconcilingFaceCam {
                reconcileFaceCamMode(enteringTransparent: faceCamBgTransparent)
            }
            // Transparent = pure silhouette (free, no shape). Color = shaped, so
            // default freeform off (fall back to a circle) when leaving transparent.
            if faceCamBgTransparent {
                if !faceCamFreeform { faceCamFreeform = true }
            } else if faceCamFreeform {
                faceCamFreeform = false
                if pipShape == .rectangle { pipShape = .circle }
            }
            pushBackground(); saveFaceCamIfEnabled(); updatePreviewEffectPipeline()
        }
    }
    @Published public var faceCamBgColor: CGColor = AppModel.loadedFaceCam(for: AppModel.loadFormat()).bgColor {
        didSet { pushBackground(); saveFaceCamIfEnabled() }
    }
    /// Freeform = no shape clip (free silhouette/full-body cutout) when
    /// background removal is on. false = clip to `pipShape`.
    @Published public var faceCamFreeform: Bool = AppModel.loadedFaceCam(for: AppModel.loadFormat()).freeform {
        didSet { pushBackground(); saveFaceCamIfEnabled(); updatePreviewEffectPipeline() }
    }

    // MARK: - Split-screen / camera-only background (blur / color / image)
    // Separate from the pipOverlay transparent/color machinery above. When the
    // camera fills its region (split or camera-only) the person stays sharp and
    // the background behind them is replaced.
    @Published public var faceCamBgMode: FaceCamBg =
        FaceCamBg(rawValue: UserDefaults.standard.string(forKey: "faceCamBgMode") ?? "") ?? .none {
        didSet {
            guard faceCamBgMode != oldValue else { return }
            UserDefaults.standard.set(faceCamBgMode.rawValue, forKey: "faceCamBgMode")
            pushBackground(); updatePreviewEffectPipeline()
        }
    }
    @Published public var faceCamBlurRadius: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "faceCamBlurRadius")
        return v > 0 ? CGFloat(v) : 18
    }() {
        didSet {
            UserDefaults.standard.set(Double(faceCamBlurRadius), forKey: "faceCamBlurRadius")
            pushBackground()
        }
    }
    @Published public var faceCamBgImageURL: URL? =
        UserDefaults.standard.string(forKey: "faceCamBgImageURL").map { URL(fileURLWithPath: $0) } {
        didSet {
            UserDefaults.standard.set(faceCamBgImageURL?.path, forKey: "faceCamBgImageURL")
            pushBackground()
        }
    }
    /// Mirror the face cam horizontally (selfie flip). Applies to the recording,
    /// the composed preview, and the floating bubble.
    @Published public var faceCamMirror: Bool = UserDefaults.standard.bool(forKey: "faceCamMirror") {
        didSet {
            UserDefaults.standard.set(faceCamMirror, forKey: "faceCamMirror")
            pushPIP()
            floatingCam?.setMirror(faceCamMirror)
        }
    }

    /// True when the camera fills its own region (split / camera-only) AND a
    /// background replacement is selected → segmentation + bg compositing on.
    public var splitBgActive: Bool {
        (layout == .splitScreenTop || layout == .splitCamTop || layout == .cameraOnly)
            && faceCamBgMode != .none
    }

    // MARK: - Preferences (persisted)

    @Published public var language: AppLanguage = AppModel.loadLanguage() {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Keys.language) }
    }
    @Published public var quality: RecordingQuality = AppModel.loadQuality() {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Keys.quality) }
    }

    /// Performance Mode: trades visual quality for system responsiveness
    /// while recording. When enabled:
    ///   - Live preview freezes during recording (last frame + REC badge)
    ///   - Camera locked at 10 fps instead of 15
    ///   - Canvas resolution forced to HD (720p tier) regardless of
    ///     the user's chosen output resolution
    /// For users on entry-level Macs (M1 Air) where running screen +
    /// camera + audio capture + Metal compose simultaneously saturates
    /// the system. Off by default — most users get the better quality.
    @Published public var performanceMode: Bool =
        UserDefaults.standard.bool(forKey: Keys.performanceMode) {
        didSet { UserDefaults.standard.set(performanceMode, forKey: Keys.performanceMode) }
    }
    @Published public var outputFormat: OutputFormat = AppModel.loadFormat() {
        didSet {
            guard outputFormat != oldValue else { return }
            UserDefaults.standard.set(outputFormat.rawValue, forKey: Keys.format)
            // Swap face-cam settings to this format's own saved values (size,
            // position, shape, border, style) — they're independent per format.
            reconcileFaceCam(from: oldValue, to: outputFormat)
            // YouTube only supports the floating PIP. Reel/Post keep whatever
            // layout was chosen — pipOverlay there is the background-removed
            // floating camera (valid), splits/camera-only are also valid.
            if outputFormat == .youtube, layout != .pipOverlay {
                layout = .pipOverlay
            }
            // Reel/Post pipOverlay = always background-removed; YouTube = never.
            syncRemovalForContext()
            // Persist the (possibly overridden) values for the new format.
            saveFaceCamIfEnabled()
            reattachPreviewCameraIfIdle()  // also refreshes the preview effect
        }
    }
    @Published public var layout: Layout = AppModel.loadLayout() {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: Keys.layout)
            syncRemovalForContext()
            reattachPreviewCameraIfIdle()
            // Live view switching during a recording (Reels/Post): push the new
            // layout + its background-removal/pip params to the running pipeline.
            // The canvas/format stays fixed; only what the compositor draws changes.
            if isActivelyRecording {
                pipeline?.updateLayout(layout)
                pushPIP()
            }
        }
    }

    /// Background removal is on automatically for the Reel/Post floating camera
    /// (pipOverlay) and off for YouTube / split / camera-only layouts. There's
    /// no user toggle — the Background (Transparent/Color) control is always
    /// shown for that context instead.
    private func syncRemovalForContext() {
        let shouldRemove = outputFormat != .youtube && layout == .pipOverlay
        if removeBackground != shouldRemove {
            // Suppress the per-property save while flipping removal — its didSet
            // clamps pipSize (plain-PIP cap) which would otherwise overwrite the
            // stored sub-slot with the clamped value. The size is reloaded below.
            isReconcilingFaceCam = true
            removeBackground = shouldRemove
            isReconcilingFaceCam = false
        }
        reloadFaceCamSizePosForContext()
    }

    /// Restore the live camera size/position from the saved sub-slot for the
    /// current pipOverlay mode (transparent vs color), so leaving pipOverlay
    /// (which clamps pipSize) and coming back keeps the size the user set.
    private func reloadFaceCamSizePosForContext() {
        guard rememberFaceCam, layout == .pipOverlay else { return }
        let v = Self.loadedFaceCam(for: outputFormat)
        let transparentMode = removeBackground && faceCamBgTransparent
        let size = transparentMode ? v.transparentSize : v.size
        let pos  = transparentMode ? v.transparentPosition : v.position
        isReconcilingFaceCam = true     // assigning pipSize/pos must not re-save
        pipSize = min(max(size, 0.08), pipSizeMax)
        pipPosition = pos
        isReconcilingFaceCam = false
        if isActivelyRecording { pushPIP() }   // live: reflect the restored size
    }

    /// Re-bind the camera to the preview session and force the camera
    /// NSView to rebuild whenever the format/layout changes while NOT
    /// recording. Fixes the "camera disappears after YouTube → record →
    /// back to Reel" bug: after a recording the device may still be
    /// releasing from the pipeline's camSession, and a layout switch
    /// otherwise never re-applies the input nor rebuilds the preview
    /// layer — leaving the camera slot black.
    private func reattachPreviewCameraIfIdle() {
        switch state {
        case .recording, .preparing, .paused, .finishing:
            return  // pipeline owns the camera; don't touch it
        default:
            break
        }
        applyPreviewCamera(selectedCamera)
        previewSessionGeneration &+= 1
        updatePreviewEffectPipeline()
    }

    /// Attach/detach the live background-removal effect on the PREVIEW session.
    /// Only active when a camera style is selected AND we're idle (the
    /// recording pipeline owns the camera otherwise). Wires a data output to
    /// the preview session and routes frames through `PreviewEffectRenderer`.
    func updatePreviewEffectPipeline() {
        let idle: Bool = { switch state { case .idle, .done, .failed: return true; default: return false } }()
        let wantEffect = idle && backgroundRemovalActive && previewInput != nil

        if wantEffect {
            previewEffectRenderer.onFrame = { [weak self] img, aspect in
                self?.faceCamEffectImage = img
                self?.faceCamEffectAspect = aspect
            }
            pushBackground()   // sync the effect renderer params for this layout
            // (Re)attach the data output. A camera swap reconfigures the session
            // and can drop the output while our reference stays non-nil — so
            // re-add whenever it's not actually attached, not just when nil.
            let attached = previewVideoOutput.map { previewSession.outputs.contains($0) } ?? false
            if !attached {
                if let stale = previewVideoOutput, previewSession.outputs.contains(stale) {
                    previewSession.beginConfiguration()
                    previewSession.removeOutput(stale)
                    previewSession.commitConfiguration()
                }
                let out = AVCaptureVideoDataOutput()
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(previewEffectRenderer, queue: previewEffectQueue)
                previewSession.beginConfiguration()
                if previewSession.canAddOutput(out) { previewSession.addOutput(out) }
                previewSession.commitConfiguration()
                previewVideoOutput = out
            }
        } else {
            if let out = previewVideoOutput {
                previewSession.beginConfiguration()
                previewSession.removeOutput(out)
                previewSession.commitConfiguration()
                previewVideoOutput = nil
            }
            previewEffectRenderer.reset()
            faceCamEffectImage = nil
        }
    }
    @Published public var screenAnchor: ScreenAnchor = AppModel.loadScreenAnchor() {
        didSet {
            UserDefaults.standard.set(screenAnchor.rawValue, forKey: Keys.screenAnchor)
            if isActivelyRecording { pipeline?.updateScreenAnchor(screenAnchor) }   // live crop
        }
    }
    /// false = Fill (crop the screen to the slot, current). true = Fit (whole
    /// desktop scaled to fit + blurred-screen background) — Reels/Post screens.
    @Published public var screenFit: Bool = UserDefaults.standard.bool(forKey: "screenFit") {
        didSet {
            UserDefaults.standard.set(screenFit, forKey: "screenFit")
            if isActivelyRecording { pipeline?.updateScreenFit(screenFit) }   // live
        }
    }
    /// Whether the floating composed preview (Reels/Post recording) is shown.
    @Published public var floatingPreviewVisible: Bool = true {
        didSet { floatingPreview.map { $0.setVisible(floatingPreviewVisible) } }
    }
    @Published public var outputResolution: OutputResolution = AppModel.loadOutputResolution() {
        didSet { UserDefaults.standard.set(outputResolution.rawValue, forKey: Keys.outputResolution) }
    }
    @Published public var countdownEnabled: Bool = AppModel.loadCountdownEnabled() {
        didSet { UserDefaults.standard.set(countdownEnabled, forKey: Keys.countdownEnabled) }
    }
    @Published public var rememberFaceCam: Bool = AppModel.loadRememberFaceCam() {
        didSet {
            UserDefaults.standard.set(rememberFaceCam, forKey: Keys.rememberFaceCam)
            if rememberFaceCam { saveFaceCamIfEnabled() }
        }
    }

    @Published public var outputDirectory: URL = AppModel.loadStoredOutputDirectory() {
        didSet {
            UserDefaults.standard.set(outputDirectory.path, forKey: Keys.outputDir)
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Ephemeral state

    @Published public var elapsed: TimeInterval = 0
    @Published public var screenPreviewImage: CGImage?
    @Published public var countdownValue: Int?
    @Published public var micLevel: Float = 0
    /// Flips true once the recording pipeline has produced its first composed
    /// frame. Views use this to smoothly swap from the live preview layout to
    /// a unified full-canvas render instead of showing a black gap.
    @Published public var composedFrameActive: Bool = false

    private let permissions = Permissions()
    private var pipeline: CapturePipeline?

    /// Loom-style floating camera bubble, alive only while recording in the
    /// YouTube / pipOverlay layout. Dragging/resizing it drives `pipPosition` /
    /// `pipSize` live so the recorded camera follows it in real time.
    private var floatingCam: FloatingCameraPanel?

    /// Floating composed-output preview (Reels/Post), alive only while recording.
    /// Shows the live result + controls (switch view, pause/stop) so the user can
    /// see/drive the recording when the main window isn't visible.
    private var floatingPreview: FloatingPreviewPanel?

    public let previewSession = AVCaptureSession()
    var previewInput: AVCaptureDeviceInput?

    /// Live face-cam effect (circular/cutout) for the idle preview. Set by the
    /// `PreviewEffectRenderer`; the preview view shows this CGImage in the
    /// camera slot instead of the raw AVCaptureVideoPreviewLayer when a style
    /// is active. nil = no effect (show raw camera).
    @Published public var faceCamEffectImage: CGImage?
    /// Aspect (W/H) of the current effect image — used to size the slot to a
    /// tight (bbox-cropped) silhouette so it can sit flush at the bottom.
    @Published public var faceCamEffectAspect: CGFloat = 0.5
    private let previewEffectRenderer = PreviewEffectRenderer()
    private var previewVideoOutput: AVCaptureVideoDataOutput?
    private let previewEffectQueue = DispatchQueue(label: "markzzy.preview-effect", qos: .userInitiated)
    /// Bumped on each recording stop so SwiftUI rebuilds the camera
    /// preview NSView. Without this, AVCaptureVideoPreviewLayer holds
    /// onto its pre-recording state and never re-engages with the
    /// (now-restored) preview session — camera slot stays black after
    /// recording ends.
    @Published public internal(set) var previewSessionGeneration: Int = 0
    private let livePreview = LivePreview()
    private let micMonitor = MicMonitor()
    private var timer: Timer?
    private var recordingStart: Date?
    var deviceObservers: [NSObjectProtocol] = []
    var deviceChangeTask: Task<Void, Never>?
    var continuityPollTask: Task<Void, Never>?
    /// KVO token on `CameraCapture.sharedDiscovery.devices`. AVFoundation only
    /// triggers Continuity Camera enumeration while a discovery session is
    /// alive AND something is observing it; KVO-ing here is what reliably
    /// tells us the moment the iPhone shows up (or disappears) without polling.
    var discoveryDevicesObservation: NSKeyValueObservation?
    /// Idle session held open while the user has the iPhone slot selected
    /// but no Continuity device is bound. An EMPTY AVCaptureSession won't
    /// do — macOS only kicks off the Bonjour-style Continuity scan once a
    /// session is running with at least one real video input. We attach
    /// the built-in FaceTime HD camera (cheapest device available) so the
    /// session is actually consuming camera frames, which is the documented
    /// trigger for `.continuityCamera` device announcements.
    let continuityWakeSession = AVCaptureSession()
    /// Dedicated serial queue for ALL mutations of `continuityWakeSession`
    /// (start/stop/begin/commit/addInput/removeInput). AVCaptureSession is
    /// not thread-safe and throws an Objective-C exception (which crashes
    /// the app via SIGABRT) if you call `commitConfiguration` on one thread
    /// while `stopRunning` is firing on another. Funneling everything
    /// through this queue guarantees serialization.
    let wakeSessionQueue = DispatchQueue(label: "dev.markzzy.wake-session")

    // MARK: - Init / lifecycle

    public init() {
        livePreview.onFrame = { [weak self] cg in
            Task { @MainActor in self?.screenPreviewImage = cg }
        }
        micMonitor.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        // Background removal is contextual (Reel/Post pipOverlay = on). Make sure
        // the persisted flag matches the launch format/layout.
        syncRemovalForContext()
    }

    deinit {
        deviceChangeTask?.cancel()
        discoveryDevicesObservation?.invalidate()
        let center = NotificationCenter.default
        for token in deviceObservers { center.removeObserver(token) }
    }

    public func bootstrap() async {
        let pid = Perf.begin("AppModel.bootstrap")
        defer { Perf.end("AppModel.bootstrap", id: pid) }
        // Camera TCC must be granted BEFORE the first read of
        // `AVCaptureDevice.DiscoverySession.devices` for `.continuityCamera`
        // — otherwise AVFoundation returns the discovery session's `.devices`
        // without ever spinning up the Continuity scanner, and the iPhone
        // simply never appears for the lifetime of the process.
        let permID = Perf.begin("permissions.requestAll")
        await permissions.requestAll()
        Perf.end("permissions.requestAll", id: permID)
        // Start KVO on the shared discovery session FIRST, before any read of
        // `.devices`. Apple's AVCam sample documents this ordering: KVO must
        // be in place when the first iPhone announcement arrives.
        observeDiscoveryDevices()
        // Kick the screen preview off as a fire-and-forget Task BEFORE
        // awaiting device enumeration. Both touch different subsystems
        // (ScreenCaptureKit vs AVFoundation) and both take ~500 ms cold;
        // sequential cost was ~1 s. With this split the preview canvas
        // appears in parallel with — and often before — the camera
        // dropdown finishes populating. Async let didn't fit because its
        // closure can't reach MainActor-isolated properties.
        if let screen = selectedScreen {
            Task {
                let prevID = Perf.begin("livePreview.start")
                await livePreview.start(for: screen)
                Perf.end("livePreview.start", id: prevID)
            }
        }
        let devID = Perf.begin("refreshDevices")
        await refreshDevices()
        Perf.end("refreshDevices", id: devID)
        applyMicMonitor()
        observeDeviceChanges()
        // If user has the iPhone slot active, kick the wake session so macOS
        // actually goes looking for the iPhone right now.
        updateContinuityPolling()
    }

    // (Camera device management, KVO, wake session, refreshDevices,
    //  handleDeviceChange and applyPreviewCamera live in
    //  `AppModel+Cameras.swift`.)

    func applyMicMonitor() {
        if case .recording = state { return }
        if let mic = selectedMic {
            micMonitor.start(with: mic)
        } else {
            micMonitor.stop()
        }
    }

    private func stopPreview() {
        if previewSession.isRunning { previewSession.stopRunning() }
        // Fully release the camera device. Just calling stopRunning()
        // leaves the input attached, and AVFoundation can keep the
        // device "warm" — that means the recording pipeline's camSession
        // can't fully claim the camera and gets only black frames.
        if let input = previewInput {
            previewSession.beginConfiguration()
            previewSession.removeInput(input)
            previewSession.commitConfiguration()
            previewInput = nil
        }
    }

    // MARK: - Recording flow

    public func toggleRecording() async {
        switch state {
        case .idle, .done, .failed:
            if countdownEnabled {
                await runCountdownThenStart()
            } else {
                await startRecording()
            }
        case .recording, .paused:
            await stopRecording()
        default: break
        }
    }

    public func pauseRecording() {
        guard case .recording = state, let p = pipeline else { return }
        p.pause()
        // Freeze the elapsed counter at the current value by stashing the
        // accumulated time into recordingStart's offset.
        if let start = recordingStart {
            elapsed = Date().timeIntervalSince(start)
        }
        timer?.invalidate(); timer = nil
        state = .paused
    }

    public func resumeRecording() {
        guard case .paused = state, let p = pipeline else { return }
        p.resume()
        // Reset the wall-clock anchor so the timer continues from `elapsed`.
        recordingStart = Date().addingTimeInterval(-elapsed)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        state = .recording
    }

    private func runCountdownThenStart() async {
        for i in [3, 2, 1] {
            countdownValue = i
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        countdownValue = nil
        await startRecording()
    }

    // MARK: - Floating camera bubble (Loom-style)

    /// True when the floating bubble should be used: YouTube format, the
    /// floating-PIP layout, and a camera selected.
    private var floatingCamEligible: Bool {
        outputFormat == .youtube && layout == .pipOverlay && selectedCamera != nil
    }

    /// The `NSScreen` matching the captured display, for coordinate mapping.
    private func nsScreen(for source: ScreenSource) -> NSScreen? {
        guard let displayID = source.display?.displayID else { return NSScreen.main }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first {
            ($0.deviceDescription[key] as? CGDirectDisplayID) == displayID
        } ?? NSScreen.main
    }

    /// Initial bubble frame (global AppKit coords) derived from the current
    /// `pipPosition` (top-left normalized) and `pipSize` (fraction of canvas
    /// width ≈ fraction of screen width).
    private func bubbleFrame(on screen: NSScreen) -> NSRect {
        let v = screen.frame
        let side = max(90, min(700, pipSize * v.width))
        let centerX = v.minX + pipPosition.x * v.width
        // pipPosition.y is top-left normalized; AppKit y grows upward.
        let centerY = v.minY + (1 - pipPosition.y) * v.height
        return NSRect(x: centerX - side / 2, y: centerY - side / 2,
                      width: side, height: side)
    }

    /// True while we're applying a bubble-driven change to the model — used to
    /// break the bubble→model→bubble feedback loop in `pushPIP`.
    private var isSyncingFromBubble = false

    /// Map the bubble's on-screen WINDOW frame back to `pipPosition` / `pipSize`.
    /// The camera circle is the BOTTOM square of the window (the optional control
    /// header sits on top), so derive the circle from `frame.width` + bottom edge.
    private func updatePip(from frame: NSRect, on screen: NSScreen) {
        let v = screen.frame
        guard v.width > 0, v.height > 0 else { return }
        let side = frame.width
        let cx = frame.minX + side / 2
        let cy = frame.minY + side / 2               // circle center (bottom square)
        let nx = (cx - v.minX) / v.width
        let ny = 1 - (cy - v.minY) / v.height        // back to top-left normalized
        let nsize = side / v.width
        isSyncingFromBubble = true
        pipPosition = CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
        pipSize = min(max(nsize, 0.04), 1)
        isSyncingFromBubble = false
    }

    /// Create + show the floating bubble BEFORE the pipeline starts (so its
    /// window exists and can be excluded from the recording's SCStream). The
    /// live camera feed is attached later via `floatingCam?.attach(session:)`
    /// once `pipe.start()` has the camera running.
    private func prepareFloatingCamera() {
        guard floatingCamEligible,
              let screen = selectedScreen.flatMap({ nsScreen(for: $0) }) else {
            PerfLog.log("FLOATCAM: skipped (eligible=\(floatingCamEligible) format=\(outputFormat.rawValue) layout=\(layout.rawValue) cam=\(selectedCamera != nil))")
            return
        }
        let panel = FloatingCameraPanel(initialFrame: bubbleFrame(on: screen))
        panel.applyFromModel(frame: bubbleFrame(on: screen), shape: pipShape,
                             border: pipBorder, mirror: faceCamMirror)
        panel.onFrameChange = { [weak self] f in
            self?.updatePip(from: f, on: screen)
        }
        // Loom controls (live during recording).
        panel.onSizePreset = { [weak self] fraction in self?.pipSize = fraction }
        panel.onToggleShape = { [weak self] in
            guard let self else { return }
            self.pipShape = (self.pipShape == .circle) ? .roundedRect : .circle
        }
        panel.onToggleMirror = { [weak self] in self?.faceCamMirror.toggle() }
        panel.orderFrontRegardless()
        floatingCam = panel
        PerfLog.log("FLOATCAM: prepared frame=\(Int(panel.frame.width))x\(Int(panel.frame.height)) at (\(Int(panel.frame.minX)),\(Int(panel.frame.minY))) win=\(panel.windowNumber) on screen \(Int(screen.frame.width))x\(Int(screen.frame.height))")
    }

    /// Floating composed preview for Reels/Post (not YouTube — that has the bubble).
    private func showFloatingPreview() {
        guard outputFormat != .youtube,
              let screen = selectedScreen.flatMap({ nsScreen(for: $0) }) else { return }
        let aspect: CGFloat = outputFormat == .square11 ? 1.0 : 9.0 / 16.0
        let v = screen.visibleFrame
        let h = min(v.height * 0.5, 520)
        let w = h * aspect
        // +barHeight: the control nav is a docked bar BELOW the video (not over it).
        let frame = NSRect(x: v.maxX - w - 24, y: v.minY + (v.height - h) / 2,
                           width: w, height: h + FloatingPreviewPanel.barHeight)
        let panel = FloatingPreviewPanel(initialFrame: frame, aspect: aspect, model: self)
        panel.onHide = { [weak self] in self?.floatingPreviewVisible = false }
        floatingPreviewVisible = true
        panel.orderFrontRegardless()
        floatingPreview = panel
        PerfLog.log("FLOATPREVIEW: shown \(Int(w))x\(Int(h)) at (\(Int(frame.minX)),\(Int(frame.minY)))")
    }

    private func hideFloatingPreview() {
        floatingPreview?.teardown()
        floatingPreview = nil
    }

    /// Move the pipOverlay circle by a normalized delta (dragging it on the
    /// floating preview). Clamped; `pipPosition.didSet` pushes it live.
    func nudgePip(dxFrac: CGFloat, dyFrac: CGFloat) {
        if pipLiveEditing {
            // Live circle drag: bypass @Published (its cascade re-renders the whole
            // ControlPanel/preview tree per mouse move = the lag, worst with bg
            // removal). Push straight to the pipeline; commit once on end.
            var p = liveDragPos ?? pipPosition
            p.x = min(max(p.x + dxFrac, 0), 1)
            p.y = min(max(p.y + dyFrac, 0), 1)
            liveDragPos = p
            pushLivePip()
        } else {
            pipPosition = CGPoint(x: min(max(pipPosition.x + dxFrac, 0), 1),
                                  y: min(max(pipPosition.y + dyFrac, 0), 1))
        }
    }

    /// Resize the pipOverlay circle by a normalized delta (dragging its edge on the
    /// floating preview). Clamped; live drag bypasses @Published like nudgePip.
    func nudgePipSize(dFrac: CGFloat) {
        if pipLiveEditing {
            liveDragSize = min(max((liveDragSize ?? pipSize) + dFrac, 0.08), pipSizeMax)
            pushLivePip()
        } else {
            pipSize = min(max(pipSize + dFrac, 0.08), pipSizeMax)
        }
    }

    /// Max camera size for the current mode (matches the main panel's size row):
    /// transparent silhouette goes up to 3× (overflows off-canvas), shaped color
    /// to 1×, plain PIP to 0.40.
    public var pipSizeMax: CGFloat {
        faceCamBottomAnchored ? 3.0 : (backgroundRemovalActive ? 1.0 : 0.40)
    }

    /// True while the user is live-dragging/resizing the pip (circle drag or the
    /// floating-preview size slider). During this, `saveFaceCamIfEnabled` is a
    /// no-op (avoids a UserDefaults JSON write per mouse move = the drag lag) and
    /// `pushPIP` skips the background re-push; we persist once on `endPipLiveEdit`.
    private(set) var pipLiveEditing = false
    // Pending values for a circle drag (the float-preview slider writes pipSize
    // directly so it leaves these nil → not overwritten on commit).
    private var liveDragPos: CGPoint?
    private var liveDragSize: CGFloat?

    func beginPipLiveEdit() {
        pipLiveEditing = true
        liveDragPos = nil
        liveDragSize = nil
    }

    /// Push the in-flight drag values straight to the compositor (no @Published).
    private func pushLivePip() {
        pipeline?.updatePIP(position: liveDragPos ?? pipPosition,
                            size: liveDragSize ?? pipSize,
                            shape: pipShape, border: pipBorder, mirror: faceCamMirror)
    }

    func endPipLiveEdit() {
        guard pipLiveEditing else { return }
        pipLiveEditing = false
        // Commit the drag results to @Published ONCE (single re-render); the
        // didSet then persists. Only commit what actually changed in a circle drag.
        if let p = liveDragPos { pipPosition = p }
        if let s = liveDragSize { pipSize = s }
        liveDragPos = nil
        liveDragSize = nil
        saveFaceCamIfEnabled()      // covers the slider path (no liveDrag* set)
    }

    private func hideFloatingCamera() {
        // Release the camera session from the bubble's preview layer FIRST so the
        // device is fully free for the preview restore / next recording (otherwise
        // the camera can "disappear" on the second recording).
        floatingCam?.detach()
        floatingCam?.orderOut(nil)
        floatingCam?.close()
        floatingCam = nil
    }

    /// Output path of the in-progress recording (so a FAILED stop can delete the
    /// truncated file instead of leaving junk behind).
    private var currentOutputURL: URL?

    private func startRecording() async {
        guard let screen = selectedScreen else {
            state = .failed("No screen source selected"); return
        }
        // Pre-flight: writable folder + enough disk. Fail fast with a clear msg.
        if let err = preflightRecording() { state = .failed(err); return }
        state = .preparing
        // Camera preview must stop NOW (camera can only be in one session at a
        // time, and the recording pipeline needs it). But keep `livePreview`
        // (the screen SCStream) running so the screen stays visible during
        // the camera warm-up — we'll swap it for composed frames once they
        // start arriving.
        stopPreview()
        // Same for the Continuity wake session — the recording pipeline will
        // be the one to claim the camera. Also drop the placeholder input so
        // the FaceTime HD device is free for the recording pipeline if it
        // needs it.
        stopContinuityWakeSession()
        micMonitor.stop()
        // Create the floating bubble NOW (before the pipeline builds its SCStream
        // filter) so its window can be excluded from the recording while still
        // appearing in normal macOS screenshots.
        prepareFloatingCamera()
        let outURL = defaultOutputURL()
        currentOutputURL = outURL
        do {
            let pipe = try CapturePipeline(
                screen: screen,
                camera: selectedCamera,
                microphone: selectedMic,
                pipPosition: pipPosition,
                pipSize: pipSize,
                pipShape: pipShape,
                pipBorder: pipBorder,
                output: outURL,
                bitrate: quality.bitrate,
                format: outputFormat,
                layout: layout,
                screenAnchor: screenAnchor,
                screenFit: screenFit,
                // Performance Mode forces HD (720p tier) regardless of
                // user selection — cuts canvas pixel count by ~half,
                // proportional reduction in compose + encoder work.
                resolution: performanceMode ? .hd720 : outputResolution,
                performanceMode: performanceMode
            )
            // Performance Mode: skip live preview push entirely (just
            // mark first composed frame so UI flips to "REC" badge).
            // Saves ~10 CGImage builds/s + main actor hops + SwiftUI
            // re-renders during recording.
            let perfMode = performanceMode
            // Only flip to composed frames once the camera is actually in the
            // frame (or there's no camera) — otherwise the FIRST recording can
            // briefly show a camera-less composite (black pip) during the cold
            // camera warm-up → "the camera disappears the first time".
            let camExpected = selectedCamera != nil && layout.usesCamera
            pipe.onComposedFrame = { [weak self] buffer, hadCamera in
                if !perfMode {
                    self?.livePreview.push(buffer)
                }
                guard !camExpected || hadCamera else { return }
                Task { @MainActor in
                    guard let self, !self.composedFrameActive else { return }
                    // Only flip while actually recording — a late composed frame
                    // arriving during stop (state == .finishing) must NOT re-enable
                    // composed mode, or the preview stays frozen on the last frame
                    // and the live camera "disappears".
                    guard case .recording = self.state else { return }
                    self.composedFrameActive = true
                }
            }
            // Sync background-removal state into the pipeline BEFORE it starts
            // compositing. Otherwise the first frames render with removal OFF
            // (bgRemovalEnabled defaults to false) → the raw camera WITH its
            // background flashes at the start of every transparent recording.
            pipeline = pipe
            // Exclude the floating bubble's window from THIS recording only.
            if let win = floatingCam?.windowNumber, win > 0 {
                pipe.excludedWindowID = CGWindowID(win)
            }
            pushBackground()
            try await pipe.start()
            // Now the camera session is live → feed the bubble's preview layer.
            floatingCam?.attach(session: pipe.cameraCaptureSession)
            // Reels/Post: floating composed-output preview with controls.
            showFloatingPreview()
            await livePreview.stop()
            recordingStart = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStart else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
            state = .recording
        } catch {
            hideFloatingCamera()
            hideFloatingPreview()
            applyPreviewCamera(selectedCamera)
            applyMicMonitor()
            let msg = Self.humanize(error)
            Telemetry.report("recording_start_failed", ["error": Self.cleanFailureMessage(msg)])
            state = .failed(msg)
        }
    }

    /// Maps low-level capture errors to user-facing strings, prefixed so the UI
    /// can surface a System Settings deep-link when the cause is a denied
    /// permission. Prefixes: `permission:screen:`, `permission:camera:`,
    /// `permission:mic:`.
    private static func humanize(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("user declined")
            || lower.contains("not authorized")
            || lower.contains("permission")
            || lower.contains("tcc") {
            // We don't always know which permission — best-effort guess.
            if lower.contains("camera") { return "permission:camera:\(raw)" }
            if lower.contains("audio") || lower.contains("microphone") { return "permission:mic:\(raw)" }
            return "permission:screen:\(raw)"
        }
        // Map ScreenCaptureKit's typed errors when we can.
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            switch ns.code {
            case -3801: return "permission:screen:\(raw)"     // userDeclined
            case -3804: return "permission:screen:\(raw)"     // failedToStart (often perm-related)
            default: break
            }
        }
        return raw
    }

    /// If the given failure message is permission-related, returns a deep-link
    /// URL into the relevant System Settings pane. nil otherwise.
    public static func settingsURL(for failureMessage: String) -> URL? {
        if failureMessage.hasPrefix("permission:screen:") {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
        if failureMessage.hasPrefix("permission:camera:") {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        }
        if failureMessage.hasPrefix("permission:mic:") {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
        return nil
    }

    /// Strips the `permission:KIND:` prefix for display.
    public static func cleanFailureMessage(_ m: String) -> String {
        if let r = m.range(of: "^permission:[a-z]+:", options: .regularExpression) {
            return String(m[r.upperBound...])
        }
        return m
    }

    func stopRecording() async {
        state = .finishing
        timer?.invalidate(); timer = nil
        recordingStart = nil
        // Stop callbacks BEFORE clearing the flag so a late composed frame can't
        // re-enable composed mode (which froze the preview on the last frame).
        pipeline?.onComposedFrame = nil
        composedFrameActive = false
        hideFloatingCamera()
        hideFloatingPreview()

        // Finalize the recording, capturing the result/error WITHOUT letting it
        // skip the camera-restore below. Previously a throw from stop() jumped
        // straight to the catch and, if anything there also threw, the camera
        // was never handed back → "the camera disappeared and nothing saved".
        var savedURL: URL?
        var stopError: String?
        do {
            savedURL = try await pipeline?.stop()
        } catch {
            stopError = error.localizedDescription
            PerfLog.log("STOP: recorder.stop() failed: \(error.localizedDescription)")
            Telemetry.report("recording_finalize_failed", ["error": error.localizedDescription])
        }
        pipeline = nil
        // Clean up a truncated/invalid file if finalization failed (disk full,
        // write error, no frames) so we never leave junk in the user's library.
        if savedURL == nil, let bad = currentOutputURL {
            try? FileManager.default.removeItem(at: bad)
        }
        currentOutputURL = nil

        // ALWAYS hand the camera back to the preview session, regardless of how
        // finalization went. Bump the generation after so SwiftUI rebuilds the
        // camera NSView and AVCaptureVideoPreviewLayer re-engages with the
        // restored preview session (otherwise the slot stays black).
        applyPreviewCamera(selectedCamera)
        previewSessionGeneration &+= 1
        if let s = selectedScreen { await livePreview.start(for: s) }
        applyMicMonitor()
        updateContinuityPolling()

        if let savedURL {
            state = .done(savedURL)
        } else if let stopError {
            state = .failed(stopError)
        } else {
            state = .idle
        }
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - PIP helpers

    public enum CornerPreset: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var point: CGPoint {
            switch self {
            case .topLeft:     CGPoint(x: 0.12, y: 0.12)
            case .topRight:    CGPoint(x: 0.88, y: 0.12)
            case .bottomLeft:  CGPoint(x: 0.12, y: 0.88)
            case .bottomRight: CGPoint(x: 0.88, y: 0.88)
            }
        }
    }
    public func snap(to corner: CornerPreset) { pipPosition = corner.point }
    public func matchesCorner(_ preset: CornerPreset, epsilon: CGFloat = 0.01) -> Bool {
        let p = pipPosition
        let c = preset.point
        return abs(p.x - c.x) < epsilon && abs(p.y - c.y) < epsilon
    }
    public var isCustomPosition: Bool {
        !CornerPreset.allCases.contains(where: { matchesCorner($0) })
    }
    func pushPIP() {
        pipeline?.updatePIP(position: pipPosition, size: pipSize,
                            shape: pipShape, border: pipBorder, mirror: faceCamMirror)
        // Keep the floating bubble in sync with the model (slider / S-M-L / shape
        // changes move + reshape the bubble live), unless the change ORIGINATED
        // from the bubble itself (guard against the feedback loop).
        syncFloatingCamFromModel()
        // Shape feeds the preview effect; re-derive the full background params.
        // During a live pos/size drag the background params don't change, so skip
        // the re-push (keeps the drag smooth — updatePIP above still moves it).
        if !pipLiveEditing { pushBackground() }
    }

    /// Push the model's pip frame/shape/border/mirror onto the live bubble.
    private func syncFloatingCamFromModel() {
        guard !isSyncingFromBubble, let panel = floatingCam,
              let screen = selectedScreen.flatMap({ nsScreen(for: $0) }) else { return }
        panel.applyFromModel(frame: bubbleFrame(on: screen), shape: pipShape,
                             border: pipBorder, mirror: faceCamMirror)
    }
    // Cached background image buffer (avoids reloading the file every frame).
    private var cachedBgImageBuffer: CVPixelBuffer?
    private var cachedBgImagePath: String?
    private func bgImageBuffer() -> CVPixelBuffer? {
        guard let url = faceCamBgImageURL else { return nil }
        if cachedBgImagePath == url.path, let b = cachedBgImageBuffer { return b }
        let buf = BgImageLoader.pixelBuffer(from: url)
        cachedBgImageBuffer = buf
        cachedBgImagePath = buf != nil ? url.path : nil
        return buf
    }

    /// Compute the EFFECTIVE background params for the current layout and push
    /// them to the pipeline + preview renderer. pipOverlay uses the
    /// transparent/color machinery; split/camera-only uses faceCamBgMode
    /// (none/blur/color/image).
    private func pushBackground() {
        var removal = false
        var bgMode = 0          // 0=transparent 1=color 2=blur 3=image
        var freeform = faceCamFreeform
        var blur: CGFloat = 0
        var image: CVPixelBuffer?
        var split = false

        if splitBgActive {
            removal = true
            freeform = false
            split = true
            switch faceCamBgMode {
            case .blur:  bgMode = 2; blur = faceCamBlurRadius
            case .color: bgMode = 1
            case .image: bgMode = 3; image = bgImageBuffer()
            case .none:  removal = false
            }
        } else if outputFormat != .youtube && layout == .pipOverlay && removeBackground {
            removal = true
            freeform = faceCamFreeform
            bgMode = faceCamBgTransparent ? 0 : 1
        }

        pipeline?.updateBackground(removal: removal, bgMode: bgMode, freeform: freeform,
                                   color: faceCamBgColor, blurRadius: blur, image: image)
        previewEffectRenderer.updateParams(shape: pipShape, freeform: freeform, bgMode: bgMode,
                                           color: faceCamBgColor, blurRadius: blur,
                                           image: image, split: split)
    }

    /// True when background removal is live for the face cam — Reel/Post only,
    /// in the pipOverlay layout (camera floating over the full-screen
    /// recording). Drives whether the preview shows the segmented effect.
    public var backgroundRemovalActive: Bool {
        (outputFormat != .youtube && layout == .pipOverlay && removeBackground) || splitBgActive
    }

    /// True for the transparent free-silhouette mode (no shape clip) — the
    /// camera slot uses native aspect and can sit flush to the edges.
    public var faceCamBottomAnchored: Bool {
        // ONLY the pipOverlay transparent silhouette is bottom-anchored (native
        // aspect / aspect-fit). Split & camera-only bg modes (blur/color/image)
        // fill their slot — exclude them so the preview matches the recording
        // (no black letterbox bars). `faceCamBgTransparent` can linger true from a
        // prior pipOverlay session, hence the explicit `!splitBgActive`.
        backgroundRemovalActive && faceCamBgTransparent && !splitBgActive
    }

    public func t(_ key: LKey) -> String { L10n.t(key, in: language) }

    /// Eje del recorte: si la pantalla es más ancha que el slot el
    /// overflow es horizontal (anchor = left/center/right); si es más
    /// alta, vertical (anchor = top/center/bottom). La UI usa esto
    /// para mostrar iconos/etiquetas correctos en cada caso.
    public var anchorAxis: AnchorAxis {
        guard let screen = selectedScreen, layout.usesScreen else { return .horizontal }
        let sw = CGFloat(screen.width)
        let sh = CGFloat(screen.height)
        let canvas = outputFormat.canvasSize(for: screen, resolution: outputResolution)
        let slotAspect: CGFloat
        switch layout {
        case .pipOverlay, .screenOnly:
            slotAspect = canvas.width / max(canvas.height, 1)
        case .splitScreenTop, .splitCamTop:
            slotAspect = canvas.width / max(canvas.height / 2, 1)
        case .cameraOnly:
            return .horizontal
        }
        let sourceAspect = sw / max(sh, 1)
        return sourceAspect > slotAspect ? .horizontal : .vertical
    }

    /// Effective screen capture dimensions after the format/layout/anchor crop.
    /// Used to tell the user what portion of their display is actually recorded.
    public var effectiveCaptureRect: CGRect? {
        guard let screen = selectedScreen else { return nil }
        if !layout.usesScreen { return nil }
        let sw = CGFloat(screen.width)
        let sh = CGFloat(screen.height)
        let canvas = outputFormat.canvasSize(for: screen, resolution: outputResolution)
        let slotAspect: CGFloat
        switch layout {
        case .pipOverlay, .screenOnly:
            slotAspect = canvas.width / canvas.height
        case .splitScreenTop, .splitCamTop:
            slotAspect = canvas.width / (canvas.height / 2)
        case .cameraOnly:
            return nil
        }
        return PIPCompositor.cropRect(
            sourceWidth: sw, sourceHeight: sh,
            targetAspect: slotAspect, anchor: screenAnchor
        )
    }

    /// User-facing short label for the effective capture. Returns `nil` when
    /// there's no crop applied (e.g. YouTube preset uses the full display).
    public var effectiveCaptureLabel: String? {
        guard let r = effectiveCaptureRect, let screen = selectedScreen else { return nil }
        if Int(r.width) == screen.width, Int(r.height) == screen.height { return nil }
        return "\(Int(r.width))×\(Int(r.height))"
    }

    // MARK: - Persistence
    // (Library / output-directory helpers live in `AppModel+Library.swift`.)

    enum Keys {
        static let outputDir         = "outputDirectoryPath"
        static let language          = "appLanguage"
        static let quality           = "recordingQuality"
        static let performanceMode   = "performanceMode"
        static let countdownEnabled  = "countdownEnabled"
        static let rememberFaceCam   = "rememberFaceCam"
        static let faceCam           = "faceCamSettings"          // legacy (global)
        static let faceCamByFormat   = "faceCamSettingsByFormat"  // per-format
        static let format            = "outputFormat"
        static let layout            = "layout"
        static let screenAnchor      = "screenAnchor"
        static let outputResolution  = "outputResolution"
        static let showAllDevices    = "showAllDevices"
        static let hiddenDeviceIDs   = "hiddenDeviceIDs"
        static let allowVirtualCameras = "allowVirtualCameras"
        static let wantsContinuityCamera = "wantsContinuityCamera"
        static let iPhoneDisconnectFlag  = "iPhoneRecentlyDisconnected"
    }

    static func loadFormat() -> OutputFormat {
        if let raw = UserDefaults.standard.string(forKey: Keys.format),
           let f = OutputFormat(rawValue: raw) { return f }
        return .youtube
    }
    private static func loadLayout() -> Layout {
        if let raw = UserDefaults.standard.string(forKey: Keys.layout),
           let l = Layout(rawValue: raw) { return l }
        return .pipOverlay
    }
    private static func loadScreenAnchor() -> ScreenAnchor {
        if let raw = UserDefaults.standard.string(forKey: Keys.screenAnchor),
           let s = ScreenAnchor(rawValue: raw) { return s }
        return .center
    }
    private static func loadOutputResolution() -> OutputResolution {
        if let raw = UserDefaults.standard.string(forKey: Keys.outputResolution),
           let r = OutputResolution(rawValue: raw) { return r }
        return .fullHd
    }

    private static func loadLanguage() -> AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: Keys.language),
           let lang = AppLanguage(rawValue: raw) { return lang }
        // Fall back to system locale: Spanish if user's prefs start with "es".
        if Locale.current.identifier.lowercased().hasPrefix("es") { return .es }
        return .en
    }

    private static func loadQuality() -> RecordingQuality {
        if let raw = UserDefaults.standard.string(forKey: Keys.quality),
           let q = RecordingQuality(rawValue: raw) { return q }
        return .medium
    }

    private static func loadCountdownEnabled() -> Bool {
        UserDefaults.standard.object(forKey: Keys.countdownEnabled) as? Bool ?? false
    }

    private static func loadRememberFaceCam() -> Bool {
        UserDefaults.standard.object(forKey: Keys.rememberFaceCam) as? Bool ?? true
    }

    private static func loadWantsContinuity() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.wantsContinuityCamera)
    }

    private static func loadDeviceFilter() -> DeviceFilter {
        let showAll = UserDefaults.standard.bool(forKey: Keys.showAllDevices)
        let hidden = (UserDefaults.standard.array(forKey: Keys.hiddenDeviceIDs) as? [String]) ?? []
        let allowVirtual = UserDefaults.standard.bool(forKey: Keys.allowVirtualCameras)
        return DeviceFilter(
            hideVirtualDevices: !showAll,
            hiddenDeviceIDs: Set(hidden),
            allowVirtualCameras: allowVirtual
        )
    }

    // (Face cam persistence lives in `AppModel+FaceCam.swift`.)
}

public struct VideoItem: Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let date: Date
    public let size: Int64

    public var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
