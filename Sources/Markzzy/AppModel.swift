import Foundation
import AVFoundation
import AppKit
import Combine
import CoreGraphics

@MainActor
public final class AppModel: ObservableObject {
    public enum State: Equatable { case idle, preparing, recording, finishing, done(URL), failed(String) }

    @Published public var state: State = .idle
    @Published public var screenSources: [ScreenSource] = []
    @Published public var cameras: [AVCaptureDevice] = []
    @Published public var microphones: [AVCaptureDevice] = []

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
    @Published public var screenFit: ScreenFit = AppModel.loadScreenFit() {
        didSet { UserDefaults.standard.set(screenFit.rawValue, forKey: Keys.screenFit) }
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

    private let permissions = Permissions()
    private var pipeline: CapturePipeline?

    public let previewSession = AVCaptureSession()
    private var previewInput: AVCaptureDeviceInput?
    private let livePreview = LivePreview()
    private let micMonitor = MicMonitor()
    private var timer: Timer?
    private var recordingStart: Date?

    // MARK: - Init / lifecycle

    public init() {
        livePreview.onFrame = { [weak self] cg in
            Task { @MainActor in self?.screenPreviewImage = cg }
        }
        micMonitor.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
    }

    public func bootstrap() async {
        await permissions.requestAll()
        await refreshDevices()
        if let screen = selectedScreen {
            await livePreview.start(for: screen)
        }
        applyMicMonitor()
    }

    public func refreshDevices() async {
        screenSources = await ScreenCapture.listSources()
        cameras = CameraCapture.listDevices()
        microphones = AudioCapture.listDevices()
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
        case .recording:
            await stopRecording()
        default: break
        }
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
        stopPreview()
        await livePreview.stop()
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
                screenFit: screenFit
            )
            pipe.onComposedFrame = { [weak self] buffer in
                self?.livePreview.push(buffer)
            }
            try await pipe.start()
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
            state = .failed(error.localizedDescription)
        }
    }

    private func stopRecording() async {
        state = .finishing
        timer?.invalidate(); timer = nil
        recordingStart = nil
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
        static let screenFit         = "screenFit"
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
    private static func loadScreenFit() -> ScreenFit {
        if let raw = UserDefaults.standard.string(forKey: Keys.screenFit),
           let s = ScreenFit(rawValue: raw) { return s }
        return .fit
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
