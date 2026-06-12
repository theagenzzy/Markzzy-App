import Foundation
import AVFoundation

/// Camera + microphone device management extracted from `AppModel`.
///
/// Includes:
/// - KVO observation of `AVCaptureDevice.DiscoverySession`
/// - Notification observers for `.AVCaptureDeviceWasConnected/Disconnected`
/// - The Continuity-Camera "wake session" (a hidden `AVCaptureSession`
///   that keeps AVFoundation's discovery scanner alive while the user
///   has the iPhone slot active but no real iPhone is yet bound)
/// - `refreshDevices`, `handleDeviceChange`, `applyPreviewCamera`
///
/// All of this used to live in `AppModel.swift` (~250 lines). Splitting
/// here keeps the main file focused on recording orchestration and lets
/// us test these surfaces in isolation.
extension AppModel {

    // MARK: - Discovery KVO

    /// KVO-observe the persistent discovery session. Far more reliable
    /// than `.AVCaptureDeviceWasConnected`, which doesn't always fire for
    /// Continuity Camera arrivals (especially when the iPhone wakes back
    /// up nearby after being asleep).
    func observeDiscoveryDevices() {
        // Always invalidate the previous observation first, so this is
        // safe to call after `CameraCapture.recreateDiscovery()` rebinds
        // the static `sharedDiscovery`.
        discoveryDevicesObservation?.invalidate()
        discoveryDevicesObservation = CameraCapture.sharedDiscovery.observe(
            \.devices, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.scheduleDeviceRescan() }
        }
    }


    /// Listens for cameras / mics being plugged or unplugged at runtime
    /// (USB cams, Continuity Camera, AirPods…). macOS sometimes fires
    /// the notifications a few times in a row, so we debounce.
    func observeDeviceChanges() {
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

    // MARK: - Reconnect recovery

    /// Best-effort one-shot recovery triggered automatically when the
    /// iPhone disappears mid-session (typically because the user tapped
    /// "Disconnect" on the iPhone). Recreates the discovery session and
    /// restarts the wake session so AVFoundation gets a chance to see
    /// the iPhone if iOS already lifted its post-disconnect cool-down.
    ///
    /// This usually does NOT fix the disconnect by itself — iOS
    /// suppresses re-advertising for a window only the user can clear
    /// (lock+unlock the iPhone, or proximity action). The persistent
    /// fix is the user-facing "Reconnect iPhone" button, which calls
    /// `forceIPhoneReconnect()` after the user has done the manual
    /// step on the phone.
    func triggerIPhoneReconnectRecovery() {
        iPhoneRecentlyDisconnected = true
        stopContinuityWakeSession()
        CameraCapture.recreateDiscovery()
        observeDiscoveryDevices()
        startContinuityWakeSession()
        if #available(macOS 13.0, *) {
            let pref = AVCaptureDevice.systemPreferredCamera
            AVCaptureDevice.userPreferredCamera = nil
            AVCaptureDevice.userPreferredCamera = pref
        }
    }

    /// Manual reconnect — invoked when the user taps "Reconnect iPhone"
    /// in the disconnect banner. Does ONE clean rebuild of the camera
    /// stack and then **3 wait+check rounds**, giving iOS up to ~10 s
    /// total to lift its post-Disconnect cool-down and re-advertise.
    ///
    /// Why one rebuild instead of three: AVFoundation rate-limits
    /// rapid `DiscoverySession` recreates and can stop scanning entirely
    /// if hammered. One clean rebuild + patient checks is more reliable
    /// than three aggressive ones.
    ///
    /// Whether or not we exit successfully, the background poll loop
    /// (`updateContinuityPolling`) keeps watching for the iPhone — so
    /// even after `reconnectExhausted = true`, the iPhone WILL be
    /// auto-bound the moment it reappears. The exhausted banner just
    /// gives the user manual-recovery hints in the meantime.
    public func forceIPhoneReconnect() async {
        // Phase 0 — one clean teardown + rebuild. Empirically a 0.5 s
        // pause is enough for AVFoundation/iOS to see the prior
        // session as closed; longer pauses just add latency the user
        // notices.
        selectedCamera = nil
        applyPreviewCamera(nil)
        stopContinuityWakeSession()
        if #available(macOS 13.0, *) {
            AVCaptureDevice.userPreferredCamera = nil
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        CameraCapture.recreateDiscovery()
        observeDiscoveryDevices()
        startContinuityWakeSession()
        updateContinuityPolling()

        // Phase 1 — three quick wait+check rounds, ~1 s each.
        // If iOS is going to honor the request, it does so within
        // ~1 s of the rebuild; longer waits don't add hit rate but
        // do add user-perceived lag.
        let rounds = 3
        for round in 1...rounds {
            reconnectAttemptStatus = "\(round)/\(rounds)"
            scheduleDeviceRescan()
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let cams = CameraCapture.listDevices(filter: deviceFilter)
            if let phone = DeviceFilter.bestRealIPhone(in: cams,
                                                       minAffinity: deviceFilter.minIPhoneAffinity) {
                selectedCamera = phone
                iPhoneRecentlyDisconnected = false
                reconnectAttemptStatus = nil
                reconnectExhausted = false
                applyPreviewCamera(phone)
                return
            }
        }

        // ~3.5 s total for the user-visible attempt cycle (down from ~9 s).
        // The background poll loop continues watching after this.
        reconnectAttemptStatus = nil
        reconnectExhausted = true
    }

    // MARK: - Continuity wake session

    /// While the user has the iPhone slot selected but no Continuity
    /// device is bound, hold a hidden `AVCaptureSession` in the running
    /// state. This forces macOS to actively scan for nearby iPhones and
    /// surface them to our discovery session — without it, AVFoundation
    /// gives up on Continuity after the OS drops the connection once and
    /// won't re-announce the iPhone for the rest of the process lifetime.
    /// Stops the moment we bind to a real device or the user picks
    /// another slot.
    func updateContinuityPolling() {
        let alreadyBound = selectedCamera.map { DeviceFilter.looksLikeIPhone($0) } ?? false
        let needsWake = wantsContinuityCamera && !alreadyBound

        if !needsWake {
            continuityPollTask?.cancel()
            continuityPollTask = nil
            stopContinuityWakeSession()
            return
        }

        startContinuityWakeSession()

        // Belt-and-suspenders: poke macOS to re-evaluate which camera is
        // "preferred". This is the documented dance Continuity-aware apps
        // perform to nudge the system into re-scanning when the iPhone
        // hasn't shown up yet. Safe to call whether or not anything changes.
        if #available(macOS 13.0, *) {
            let pref = AVCaptureDevice.systemPreferredCamera
            AVCaptureDevice.userPreferredCamera = nil
            AVCaptureDevice.userPreferredCamera = pref
        }

        guard continuityPollTask == nil else { return }
        // Adaptive backstop poll. Fast (500 ms) for the first ~10 s
        // while the user is actively waiting; then 2 s after that.
        // No automatic wake-session restarts in this loop — they
        // interrupt AVFoundation's natural scan and don't help when
        // the cause is iOS imposing a post-disconnect cool-down.
        // For that case, we expose a manual "Reconnect iPhone" button
        // (`forceIPhoneReconnect`) — manual control is more reliable
        // than auto-retries iOS will just ignore.
        continuityPollTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled, let self {
                guard self.wantsContinuityCamera,
                      !(self.selectedCamera.map { DeviceFilter.looksLikeIPhone($0) } ?? false) else {
                    break
                }
                let fresh = CameraCapture.listDevices(filter: self.deviceFilter)
                if fresh.contains(where: { DeviceFilter.looksLikeIPhone($0) }) {
                    self.handleDeviceChange()
                    break
                }
                tick += 1
                let fastPhase = tick < 20    // first 10 s = 20 × 500 ms
                let sleepNanos: UInt64 = fastPhase ? 500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
            self?.continuityPollTask = nil
        }
    }

    /// Picks a cheap, always-available camera for the wake session.
    /// Returns nil if no built-in or non-bridge external camera exists.
    func wakeSessionPlaceholder() -> AVCaptureDevice? {
        // Prefer the built-in FaceTime HD; fall back to any non-Continuity,
        // non-iPhone-bridge camera. We deliberately avoid `.continuityCamera`
        // (we'd already have what we're trying to wake up) AND iPhone
        // bridges like Camo/EpocCam (using one as wake input would just
        // re-engage the bridge that's blocking native Continuity).
        let candidates = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        return candidates.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? candidates.first(where: { !DeviceFilter.looksLikeIPhone($0) })
    }

    func startContinuityWakeSession() {
        let device = wakeSessionPlaceholder()
        let session = continuityWakeSession
        wakeSessionQueue.async {
            guard !session.isRunning else { return }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if let device, let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.sessionPreset = .low
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stopContinuityWakeSession() {
        let session = continuityWakeSession
        wakeSessionQueue.async {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }

    // MARK: - Device rescan / change handling

    func scheduleDeviceRescan() {
        deviceChangeTask?.cancel()
        deviceChangeTask = Task { @MainActor [weak self] in
            // Debounce — give macOS a moment to settle when several
            // devices appear at once (e.g. picking up a USB hub).
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.handleDeviceChange()
        }
    }

    func handleDeviceChange() {
        let previousCameraID = selectedCamera?.uniqueID
        let previousCameraWasIPhone = selectedCamera.map { DeviceFilter.looksLikeIPhone($0) } ?? false
        let previousMicID = selectedMic?.uniqueID

        let newCameras = CameraCapture.listDevices(filter: deviceFilter)
        let newMicrophones = AudioCapture.listDevices(filter: deviceFilter)
        let hadPhone = DeviceFilter.bestRealIPhone(in: cameras,
                                                   minAffinity: deviceFilter.minIPhoneAffinity) != nil
        let hasPhoneNow = DeviceFilter.bestRealIPhone(in: newCameras,
                                                      minAffinity: deviceFilter.minIPhoneAffinity) != nil

        cameras = newCameras
        microphones = newMicrophones
        // Refresh the unfiltered caches that Settings reads from.
        // Cheap (one AVFoundation call each) and only happens on real
        // device changes, not on every UI re-render.
        allConnectedCameras = CameraCapture.listAllDevices()
        allConnectedMicrophones = AudioCapture.listAllDevices()

        let phone = DeviceFilter.bestRealIPhone(in: newCameras,
                                                minAffinity: deviceFilter.minIPhoneAffinity)

        // Detect "iPhone just got disconnected" — we previously had an
        // iPhone bound and it just disappeared from the device list while
        // the user is still on the iPhone slot. This catches the
        // "Disconnect from iPhone" flow that otherwise leaves the user
        // in a permanent waiting state.
        if wantsContinuityCamera, previousCameraWasIPhone, phone == nil {
            triggerIPhoneReconnectRecovery()
        }
        // Clear the disconnect flag the moment we see the iPhone back.
        if phone != nil, iPhoneRecentlyDisconnected {
            iPhoneRecentlyDisconnected = false
        }

        // Camera selection logic.
        if wantsContinuityCamera {
            // User parked themselves on the iPhone slot. Bind to the live
            // iPhone-like device if present, otherwise wait (selectedCamera nil).
            if selectedCamera?.uniqueID != phone?.uniqueID {
                selectedCamera = phone
            }
            if case .recording = state, previousCameraID != nil, phone == nil {
                state = .failed("The selected camera was disconnected.")
                Task { await stopRecording() }
            }
        } else if let prevID = previousCameraID,
                  let stillThere = newCameras.first(where: { $0.uniqueID == prevID }) {
            // Auto-promote an iPhone-like device that just appeared, but
            // only if the user wasn't actively recording.
            if !hadPhone, hasPhoneNow, case .recording = state {
                selectedCamera = stillThere
            } else if !hadPhone, hasPhoneNow {
                selectedCamera = phone
                wantsContinuityCamera = true
            } else {
                selectedCamera = stillThere
            }
        } else {
            // Previously selected camera disappeared (or none). Pick the best.
            let next = phone ?? newCameras.first
            selectedCamera = next
            if let n = next, DeviceFilter.looksLikeIPhone(n) { wantsContinuityCamera = true }
            if case .recording = state, previousCameraID != nil {
                state = .failed("The selected camera was disconnected.")
                Task { await stopRecording() }
            }
        }

        // Mic selection — keep current if present, otherwise pick first.
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
        updateContinuityPolling()
    }

    public func refreshDevices() async {
        screenSources = await ScreenCapture.listSources()
        cameras = CameraCapture.listDevices(filter: deviceFilter)
        microphones = AudioCapture.listDevices(filter: deviceFilter)
        allConnectedCameras = CameraCapture.listAllDevices()
        allConnectedMicrophones = AudioCapture.listAllDevices()
        if selectedScreen == nil { selectedScreen = screenSources.first }
        let phone = DeviceFilter.bestRealIPhone(in: cameras,
                                                minAffinity: deviceFilter.minIPhoneAffinity)
        // Clear a stale disconnect flag if the iPhone is actually present at
        // launch/refresh. `handleDeviceChange` only fires on a device CHANGE, so
        // an iPhone already connected when the app opens would otherwise leave the
        // persisted flag set → the "iPhone disconnected" banner stuck on a working
        // camera.
        if phone != nil, iPhoneRecentlyDisconnected {
            iPhoneRecentlyDisconnected = false
        }
        if wantsContinuityCamera {
            selectedCamera = phone
        } else if selectedCamera == nil {
            selectedCamera = phone ?? cameras.first
            if let s = selectedCamera, DeviceFilter.looksLikeIPhone(s) { wantsContinuityCamera = true }
        }
        if selectedMic == nil { selectedMic = microphones.first }
        applyPreviewCamera(selectedCamera)
        updateContinuityPolling()
    }

    // MARK: - Preview session binding

    public func applyPreviewCamera(_ device: AVCaptureDevice?) {
        previewSession.beginConfiguration()
        previewSession.sessionPreset = .medium
        if let existing = previewInput {
            previewSession.removeInput(existing)
            previewInput = nil
        }
        if let device {
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if previewSession.canAddInput(input) {
                    previewSession.addInput(input)
                    previewInput = input
                    // External cams (iPhone Continuity) ignore the preset and
                    // ship huge frames → cap the LIVE PREVIEW to ~720p so it
                    // stays smooth (no lag). Recording re-raises it to 1080p.
                    CameraFormatCap.apply(to: device, maxWidth: 1280)
                } else {
                    PerfLog.log("CAM-RESTORE: canAddInput=false for \(device.localizedName)")
                }
            } catch {
                PerfLog.log("CAM-RESTORE: AVCaptureDeviceInput threw: \(error.localizedDescription)")
            }
        }
        previewSession.commitConfiguration()
        PerfLog.log("CAM-RESTORE: immediate bound=\(previewInput != nil) running=\(previewSession.isRunning) device=\(device?.localizedName ?? "nil")")
        if previewInput != nil, !previewSession.isRunning {
            let session = previewSession
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                // Attach the background-removal data output ONLY after the
                // session is actually running, else the delegate gets no frames
                // (the "transparent only works after toggling Color" race).
                DispatchQueue.main.async { [weak self] in self?.updatePreviewEffectPipeline() }
            }
        } else if previewInput == nil, previewSession.isRunning {
            previewSession.stopRunning()
        } else {
            // Already running (e.g. swapping the camera while live) — re-assert
            // the effect pipeline so it re-wires for the new input.
            updatePreviewEffectPipeline()
        }

        // Resilience: if we wanted a device but couldn't bind it (input
        // creation/add failed — usually the device is still releasing from the
        // recording pipeline's camSession right after a stop), retry a few times
        // with backoff. Device cleanup can take 0.5–1s on some Macs, so a single
        // 0.25s retry wasn't enough → the camera slot stayed black after stop.
        if let device, previewInput == nil {
            retryBindPreviewCamera(device, attempt: 1)
        }
    }

    /// Retry binding the preview camera every 0.4s for up to ~6s. The recording
    /// session can keep the device "in use" for a while after stop, so we keep
    /// trying until it's free, then start the session + rebuild the NSView.
    private func retryBindPreviewCamera(_ device: AVCaptureDevice, attempt: Int) {
        let maxAttempts = 15   // ~6s total at 0.4s spacing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            // Stop retrying if the camera already came back or the user switched.
            guard self.previewInput == nil,
                  self.selectedCamera?.uniqueID == device.uniqueID else { return }
            self.previewSession.beginConfiguration()
            var lastError: String?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.previewSession.canAddInput(input) {
                    self.previewSession.addInput(input)
                    self.previewInput = input
                    CameraFormatCap.apply(to: device, maxWidth: 1280)
                } else { lastError = "canAddInput=false" }
            } catch { lastError = error.localizedDescription }
            self.previewSession.commitConfiguration()
            if self.previewInput != nil {
                if !self.previewSession.isRunning {
                    let session = self.previewSession
                    DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
                }
                self.previewSessionGeneration &+= 1
                self.updatePreviewEffectPipeline()
                PerfLog.log("CAM-RESTORE: bound on retry #\(attempt)")
            } else if attempt < maxAttempts {
                self.retryBindPreviewCamera(device, attempt: attempt + 1)
            } else {
                PerfLog.log("⚠️ CAM-RESTORE: still unavailable after \(maxAttempts) retries (last: \(lastError ?? "?"))")
            }
        }
    }
}
