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

    /// All currently-connected devices (ignoring filter), for the Settings UI
    /// that lists hidden ones.
    public var allConnectedCameras: [AVCaptureDevice] { CameraCapture.listAllDevices() }
    public var allConnectedMicrophones: [AVCaptureDevice] { AudioCapture.listAllDevices() }

    @Published public var selectedScreen: ScreenSource? {
        didSet {
            guard oldValue != selectedScreen, let s = selectedScreen else { return }
            Task { await livePreview.start(for: s) }
        }
    }
    @Published public var selectedCamera: AVCaptureDevice?
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
    private var previewInput: AVCaptureDeviceInput?
    private let livePreview = LivePreview()
    private let micMonitor = MicMonitor()
    private var timer: Timer?
    private var recordingStart: Date?
    private var deviceObservers: [NSObjectProtocol] = []
    private var deviceChangeTask: Task<Void, Never>?

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
        let center = NotificationCenter.default
        for token in deviceObservers { center.removeObserver(token) }
    }

    public func bootstrap() async {
        await permissions.requestAll()
        await refreshDevices()
        if let screen = selectedScreen {
            await livePreview.start(for: screen)
        }
        applyMicMonitor()
        observeDeviceChanges()
    }

    /// Listens for cameras / mics being plugged or unplugged at runtime
    /// (USB cams, Continuity Camera, AirPods…). macOS sometimes fires the
    /// notifications a few times in a row, so we debounce.
    private func observeDeviceChanges() {
        guard deviceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let queue = OperationQueue.main
        let handler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.scheduleDeviceRescan() }
        }
        deviceObservers.append(
            center.addObserver(
                forName: .AVCaptureDeviceWasConnected, object: nil, queue: queue, using: handler
            )
        )
        deviceObservers.append(
            center.addObserver(
                forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: queue, using: handler
            )
        )
    }

    private func scheduleDeviceRescan() {
        deviceChangeTask?.cancel()
        deviceChangeTask = Task { @MainActor [weak self] in
            // Debounce — give macOS a moment to settle when several devices
            // appear at once (e.g. picking up a USB hub).
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.handleDeviceChange()
        }
    }

    private func handleDeviceChange() {
        let previousCameraID = selectedCamera?.uniqueID
        let previousMicID = selectedMic?.uniqueID

        let newCameras = CameraCapture.listDevices(filter: deviceFilter)
        let newMicrophones = AudioCapture.listDevices(filter: deviceFilter)
        let hadContinuity = cameras.contains(where: { $0.deviceType == .continuityCamera })
        let hasContinuityNow = newCameras.contains(where: { $0.deviceType == .continuityCamera })

        cameras = newCameras
        microphones = newMicrophones

        // Camera selection logic.
        if let prevID = previousCameraID,
           let stillThere = newCameras.first(where: { $0.uniqueID == prevID }) {
            // Auto-promote a Continuity Camera that just appeared, but only if
            // the user wasn't actively recording (we don't yank devices mid-take).
            if !hadContinuity, hasContinuityNow, case .recording = state {
                selectedCamera = stillThere
            } else if !hadContinuity, hasContinuityNow {
                selectedCamera = newCameras.first(where: { $0.deviceType == .continuityCamera })
            } else {
                selectedCamera = stillThere
            }
        } else {
            // Previously selected camera disappeared (or none). Pick the best.
            let next = newCameras.first(where: { $0.deviceType == .continuityCamera }) ?? newCameras.first
            selectedCamera = next
            if case .recording = state, previousCameraID != nil {
                state = .failed("The selected camera was disconnected.")
                Task { await stopRecording() }
            }
        }

        // Mic selection logic — simpler: keep current if present, otherwise pick first.
        if let prevID = previousMicID,
           let stillThere = newMicrophones.first(where: { $0.uniqueID == prevID }) {
            selectedMic = stillThere
        } else {
            selectedMic = newMicrophones.first
            if case .recording = state, previousMicID != nil {
                state = .failed("The selected microphone was disconnected.")
                Task { await stopRecording() }
            }
        }

        applyPreviewCamera(selectedCamera)
    }

    public func refreshDevices() async {
        screenSources = await ScreenCapture.listSources()
        cameras = CameraCapture.listDevices(filter: deviceFilter)
        microphones = AudioCapture.listDevices(filter: deviceFilter)
        if selectedScreen == nil { selectedScreen = screenSources.first }
        if selectedCamera == nil {
            selectedCamera = cameras.first(where: { $0.deviceType == .continuityCamera }) ?? cameras.first
        }
        if selectedMic == nil { selectedMic = microphones.first }
        applyPreviewCamera(selectedCamera)
    }

    public func applyPreviewCamera(_ device: AVCaptureDevice?) {
        previewSession.beginConfiguration()
        previewSession.sessionPreset = .medium
        if let existing = previewInput {
            previewSession.removeInput(existing)
            previewInput = nil
        }
        if let device, let input = try? AVCaptureDeviceInput(device: device),
           previewSession.canAddInput(input) {
            previewSession.addInput(input)
            previewInput = input
        }
        previewSession.commitConfiguration()
        if previewInput != nil, !previewSession.isRunning {
            let session = previewSession
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        } else if previewInput == nil, previewSession.isRunning {
            previewSession.stopRunning()
        }
    }

    private func applyMicMonitor() {
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

    private func stopRecording() async {
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
            if let url { state = .done(url) } else { state = .idle }
        } catch {
            applyPreviewCamera(selectedCamera)
            if let s = selectedScreen { await livePreview.start(for: s) }
            applyMicMonitor()
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

    // MARK: - Output directory

    private static func loadStoredOutputDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: Keys.outputDir), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Desktop/Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func defaultOutputURL() -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputDirectory.appendingPathComponent("Markzzy-\(fmt.string(from: Date())).mp4")
    }

    // MARK: - Library

    public func listRecordedVideos() -> [VideoItem] {
        let fm = FileManager.default
        let dir = outputDirectory
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return VideoItem(
                    url: url,
                    name: url.lastPathComponent,
                    date: values?.creationDate ?? Date.distantPast,
                    size: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.date > $1.date }
    }

    public func deleteVideo(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence

    private enum Keys {
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

    private static func loadDeviceFilter() -> DeviceFilter {
        let showAll = UserDefaults.standard.bool(forKey: Keys.showAllDevices)
        let hidden = (UserDefaults.standard.array(forKey: Keys.hiddenDeviceIDs) as? [String]) ?? []
        return DeviceFilter(hideVirtualDevices: !showAll, hiddenDeviceIDs: Set(hidden))
    }

    // MARK: - Face cam persistence

    private struct PersistedFaceCam: Codable {
        var shape: String
        var size: Double
        var positionX: Double
        var positionY: Double
        var borderStyle: String
        var borderColor: [Double]
        var borderColor2: [Double]
        var borderWidth: Double
    }

    struct FaceCamValues {
        let shape: PIPShape
        let size: CGFloat
        let position: CGPoint
        let border: PIPBorder
    }

    private static let defaultFaceCam = FaceCamValues(
        shape: .circle,
        size: 0.22,
        position: CGPoint(x: 0.85, y: 0.88),
        border: PIPBorder()
    )

    private static func loadedFaceCam() -> FaceCamValues {
        // Only restore when the user opted in; on first launch we go with defaults.
        let remember = UserDefaults.standard.object(forKey: Keys.rememberFaceCam) as? Bool ?? true
        guard remember,
              let data = UserDefaults.standard.data(forKey: Keys.faceCam),
              let p = try? JSONDecoder().decode(PersistedFaceCam.self, from: data)
        else { return defaultFaceCam }

        let shape = PIPShape(rawValue: p.shape) ?? defaultFaceCam.shape
        let style = PIPBorder.Style(rawValue: p.borderStyle) ?? .none
        let c1 = Self.cgColor(from: p.borderColor) ?? defaultFaceCam.border.color
        let c2 = Self.cgColor(from: p.borderColor2) ?? defaultFaceCam.border.color2
        return FaceCamValues(
            shape: shape,
            size: CGFloat(p.size),
            position: CGPoint(x: p.positionX, y: p.positionY),
            border: PIPBorder(style: style, color: c1, color2: c2, width: CGFloat(p.borderWidth))
        )
    }

    private func saveFaceCamIfEnabled() {
        guard rememberFaceCam else { return }
        let data = PersistedFaceCam(
            shape: pipShape.rawValue,
            size: Double(pipSize),
            positionX: Double(pipPosition.x),
            positionY: Double(pipPosition.y),
            borderStyle: pipBorder.style.rawValue,
            borderColor: Self.rgbaComponents(of: pipBorder.color),
            borderColor2: Self.rgbaComponents(of: pipBorder.color2),
            borderWidth: Double(pipBorder.width)
        )
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: Keys.faceCam)
        }
    }

    private static func rgbaComponents(of color: CGColor) -> [Double] {
        guard let ns = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return [0, 0, 0, 1] }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    private static func cgColor(from comps: [Double]) -> CGColor? {
        guard comps.count >= 3 else { return nil }
        let a = comps.count >= 4 ? CGFloat(comps[3]) : 1
        return CGColor(red: CGFloat(comps[0]), green: CGFloat(comps[1]),
                       blue: CGFloat(comps[2]), alpha: a)
    }
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
