import Foundation
import AVFoundation
import AppKit
import Combine
import CoreGraphics

@MainActor
public final class AppModel: ObservableObject {
    public enum State: Equatable { case idle, preparing, recording, paused, finishing, done(URL), failed(String) }

    @Published public var state: State = .idle
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
    @Published public var selectedCamera: AVCaptureDevice?

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

    @Published public var pipPosition: CGPoint = AppModel.loadedFaceCam().position {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }
    @Published public var pipSize: CGFloat = AppModel.loadedFaceCam().size {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }
    @Published public var pipShape: PIPShape = AppModel.loadedFaceCam().shape {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }
    @Published public var pipBorder: PIPBorder = AppModel.loadedFaceCam().border {
        didSet { pushPIP(); saveFaceCamIfEnabled() }
    }

    // MARK: - Preferences (persisted)

    @Published public var language: AppLanguage = AppModel.loadLanguage() {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Keys.language) }
    }
    @Published public var quality: RecordingQuality = AppModel.loadQuality() {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Keys.quality) }
    }
    @Published public var outputFormat: OutputFormat = AppModel.loadFormat() {
        didSet {
            UserDefaults.standard.set(outputFormat.rawValue, forKey: Keys.format)
            // Auto-reconcile layout: only pipOverlay makes sense on YouTube,
            // and pipOverlay doesn't make sense on vertical/square.
            if outputFormat == .youtube, layout != .pipOverlay {
                layout = .pipOverlay
            } else if outputFormat != .youtube, layout == .pipOverlay {
                layout = .splitScreenTop
            }
        }
    }
    @Published public var layout: Layout = AppModel.loadLayout() {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Keys.layout) }
    }
    @Published public var screenAnchor: ScreenAnchor = AppModel.loadScreenAnchor() {
        didSet { UserDefaults.standard.set(screenAnchor.rawValue, forKey: Keys.screenAnchor) }
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

    public let previewSession = AVCaptureSession()
    var previewInput: AVCaptureDeviceInput?
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

    private func startRecording() async {
        guard let screen = selectedScreen else {
            state = .failed("No screen source selected"); return
        }
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
        let outURL = defaultOutputURL()
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
                resolution: outputResolution
            )
            pipe.onComposedFrame = { [weak self] buffer in
                self?.livePreview.push(buffer)
                Task { @MainActor in
                    guard let self, !self.composedFrameActive else { return }
                    self.composedFrameActive = true
                }
            }
            try await pipe.start()
            // Composed frames are now flowing — stop the standalone screen
            // SCStream so the two sources don't race on the preview.
            await livePreview.stop()
            pipeline = pipe
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
            applyPreviewCamera(selectedCamera)
            applyMicMonitor()
            state = .failed(Self.humanize(error))
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
        composedFrameActive = false
        do {
            let url = try await pipeline?.stop()
            pipeline = nil
            applyPreviewCamera(selectedCamera)
            if let s = selectedScreen { await livePreview.start(for: s) }
            applyMicMonitor()
            updateContinuityPolling()
            if let url { state = .done(url) } else { state = .idle }
        } catch {
            applyPreviewCamera(selectedCamera)
            if let s = selectedScreen { await livePreview.start(for: s) }
            applyMicMonitor()
            updateContinuityPolling()
            state = .failed(error.localizedDescription)
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
    private func pushPIP() {
        pipeline?.updatePIP(position: pipPosition, size: pipSize,
                            shape: pipShape, border: pipBorder)
    }

    public func t(_ key: LKey) -> String { L10n.t(key, in: language) }

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
        static let countdownEnabled  = "countdownEnabled"
        static let rememberFaceCam   = "rememberFaceCam"
        static let faceCam           = "faceCamSettings"
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

    private static func loadFormat() -> OutputFormat {
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
