import XCTest
import AVFoundation
@testable import Markzzy

/// Smoke-tests that exercise the real AVFoundation discovery + bridge
/// detection on the host. Skipped when the host has no cameras at all
/// (e.g. headless CI runners).
///
/// These don't assert specific cameras (CI machines vary). They just
/// verify the code paths don't crash and return sensible structures.
final class CameraDetectionE2ETests: XCTestCase {

    func testCameraCaptureListDevicesDoesNotCrash() {
        let devices = CameraCapture.listAllDevices()
        // We don't care what's in the list — just that it returns one.
        XCTAssertNotNil(devices)
    }

    func testIPhoneAffinityHandlesEveryRealDevice() {
        // Run iPhoneAffinity over every actual device on the host. None
        // should crash; all should return a valid score 0...4.
        let devices = CameraCapture.listAllDevices()
        for d in devices {
            let score = DeviceFilter.iPhoneAffinity(d)
            XCTAssertGreaterThanOrEqual(score, 0)
            XCTAssertLessThanOrEqual(score, 4)
        }
    }

    func testCameraBridgeDetectionDoesNotCrash() {
        // Exercises the real /Library/CoreMediaIO/Plug-Ins/DAL/ scan plus
        // device-name match. May or may not detect anything depending on
        // host — just verify it returns a list.
        let bridges = CameraBridgeDetector.detect()
        XCTAssertNotNil(bridges)
        // Every bridge returned must be in the known list.
        let knownIDs = Set(CameraBridgeDetector.known.map(\.id))
        for b in bridges {
            XCTAssertTrue(knownIDs.contains(b.id), "Detected unknown bridge id: \(b.id)")
        }
    }

    func testBestRealIPhoneRespectsMinAffinity() {
        let devices = CameraCapture.listAllDevices()
        let strict = DeviceFilter.bestRealIPhone(in: devices, minAffinity: 2)
        let lax = DeviceFilter.bestRealIPhone(in: devices, minAffinity: 1)
        // Strict result, when present, must always be a subset of lax.
        if let s = strict {
            XCTAssertNotNil(lax)
            // Lax could pick a different one only if its score ≥ strict's
            // score. In practice with our scoring, strict's pick wins
            // both — but we don't assert identity, only that lax also has
            // something.
            XCTAssertGreaterThanOrEqual(DeviceFilter.iPhoneAffinity(lax!),
                                       DeviceFilter.iPhoneAffinity(s))
        }
    }
}
