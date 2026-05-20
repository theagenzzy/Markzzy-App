import Foundation
import AVFoundation

/// Programmatic recording self-test. Drives the same code path as the
/// user clicking Record → wait → Stop, then verifies the produced MP4
/// is a valid video file.
///
/// Contract: if `run()` returns success, then a manual recording with
/// the same settings will also produce a valid MP4 in the user's
/// library. Invoked via the `--self-test` CLI flag.
@MainActor
public enum SelfTest {

    public struct Result {
        public let passed: Bool
        public let message: String
        public let recordingURL: URL?
    }

    public static func run() async -> Result {
        clearProgressLog()
        log("Starting self-test")

        let model = AppModel()
        log("Bootstrapping AppModel (enumerating devices)")
        await model.bootstrap()

        guard model.selectedScreen != nil else {
            return .failure("no screen detected — Screen Recording permission missing?")
        }
        guard model.selectedCamera != nil else {
            return .failure("no camera detected — grant Camera permission and connect one")
        }
        // Prefer built-in FaceTime HD: Continuity Camera reports
        // "available" even when the iPhone is asleep, producing black
        // frames. Built-in is always warm and reliable for the test.
        if let builtin = model.cameras.first(where: { dev in
            !DeviceFilter.looksLikeIPhone(dev) && dev.deviceType == .builtInWideAngleCamera
        }), model.selectedCamera?.uniqueID != builtin.uniqueID {
            log("Switching from \(model.selectedCamera?.localizedName ?? "?") to built-in \(builtin.localizedName)")
            model.wantsContinuityCamera = false
            model.selectedCamera = builtin
            model.applyPreviewCamera(builtin)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        log("Devices OK: screen=\(model.selectedScreen?.title ?? "?"), camera=\(model.selectedCamera?.localizedName ?? "?"), mic=\(model.selectedMic?.localizedName ?? "none")")

        model.countdownEnabled = false
        log("Calling startRecording")
        await model.toggleRecording()

        let started = await waitFor(model: model, timeout: 8.0) { state in
            switch state {
            case .recording, .failed: return true
            default: return false
            }
        }
        guard started else {
            return .failure("did not reach .recording within 8s; state=\(stateLabel(model.state))")
        }
        if case .failed(let msg) = model.state {
            return .failure("recording failed during start: \(AppModel.cleanFailureMessage(msg))")
        }
        log("State: .recording — capturing 3s now")

        try? await Task.sleep(nanoseconds: 3_000_000_000)

        log("Calling stopRecording")
        await model.toggleRecording()

        let finished = await waitFor(model: model, timeout: 60.0) { state in
            if case .done = state { return true }
            if case .failed = state { return true }
            return false
        }
        guard finished else {
            return .failure("did not reach .done within 60s; state=\(stateLabel(model.state))")
        }
        if case .failed(let msg) = model.state {
            return .failure("recording finalize failed: \(AppModel.cleanFailureMessage(msg))")
        }
        guard case .done(let url) = model.state else {
            return .failure("unexpected final state \(stateLabel(model.state))")
        }
        log("Done at \(url.lastPathComponent), verifying file…")

        return await verifyMP4(at: url)
    }

    private static func verifyMP4(at url: URL) async -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("final MP4 missing at \(url.path)")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? -1
        guard size > 1024 else {
            return .failure("final MP4 too small (\(size) bytes)")
        }
        let asset = AVURLAsset(url: url)
        let duration: Double
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration).seconds
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            return .failure("AVAsset failed to open MP4: \(error.localizedDescription)")
        }
        guard !videoTracks.isEmpty else {
            return .failure("no video track in produced MP4")
        }
        guard duration > 1.0 else {
            return .failure("MP4 too short (\(String(format: "%.2f", duration))s)")
        }
        let dim = (try? await videoTracks[0].load(.naturalSize))
            .map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"
        return .success(
            message: "duration=\(String(format: "%.1f", duration))s, dim=\(dim), size=\(size / 1024)KB",
            url: url
        )
    }

    private static func waitFor(model: AppModel,
                                timeout: TimeInterval,
                                until predicate: @escaping (AppModel.State) -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if predicate(model.state) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static func stateLabel(_ state: AppModel.State) -> String {
        switch state {
        case .idle: return ".idle"
        case .preparing: return ".preparing"
        case .recording: return ".recording"
        case .paused: return ".paused"
        case .finishing: return ".finishing"
        case .done(let url): return ".done(\(url.lastPathComponent))"
        case .failed(let m): return ".failed(\(m))"
        }
    }

    private static func log(_ msg: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "MARKZZY_SELFTEST_LOG \(stamp) \(msg)"
        print(line)
        fflush(stdout)
        let path = "/tmp/markzzy-selftest-progress.log"
        if let data = (line + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func clearProgressLog() {
        try? FileManager.default.removeItem(atPath: "/tmp/markzzy-selftest-progress.log")
    }
}

extension SelfTest.Result {
    static func success(message: String, url: URL) -> SelfTest.Result {
        SelfTest.Result(passed: true, message: message, recordingURL: url)
    }
    static func failure(_ msg: String) -> SelfTest.Result {
        SelfTest.Result(passed: false, message: msg, recordingURL: nil)
    }
}

@MainActor
public enum SelfTestRunner {
    public static func isRequested() -> Bool {
        if CommandLine.arguments.contains("--self-test") { return true }
        if ProcessInfo.processInfo.environment["MARKZZY_SELFTEST"] == "1" { return true }
        return false
    }

    public static func writeResultFile(_ result: SelfTest.Result) {
        let line = (result.passed ? "PASS: " : "FAIL: ") + result.message
            + (result.recordingURL.map { "\nFILE: \($0.path)" } ?? "")
        try? line.write(toFile: "/tmp/markzzy-selftest-result.txt",
                        atomically: true, encoding: .utf8)
    }
}
