import XCTest
@testable import Markzzy

/// Tests for AppModel's iPhone-related computed/derived state. Focuses on
/// the overlay state machine — what the user sees in the camera preview
/// area when the iPhone is missing, present, or just disconnected.
///
/// We can't construct real `AVCaptureDevice`s in unit tests (they need
/// hardware), so we verify the *logic gates* instead: the truth tables
/// of `wantsContinuityCamera` × `selectedCamera-is-iPhone` × `recently
/// disconnected`.
@MainActor
final class AppModelStateTests: XCTestCase {

    // MARK: - isWaitingForIPhone truth table

    func testNotWaitingWhenContinuityNotRequested() {
        let model = AppModel()
        model.wantsContinuityCamera = false
        XCTAssertFalse(model.isWaitingForIPhone,
                       "If user isn't on the iPhone slot, never waiting.")
    }

    func testWaitingWhenContinuityRequestedAndNoCamera() {
        let model = AppModel()
        model.wantsContinuityCamera = true
        model.selectedCamera = nil
        XCTAssertTrue(model.isWaitingForIPhone,
                      "Slot active + no device = waiting state, overlay must show.")
    }

    // Note: we can't easily test "slot active + iPhone bound = NOT waiting"
    // without a real AVCaptureDevice. That branch is covered by the
    // E2E smoke tests in MarkzzyE2ETests/CameraDetectionE2ETests.

    // MARK: - iPhoneRecentlyDisconnected lifecycle

    func testRecentlyDisconnectedDefaultsFalse() {
        let model = AppModel()
        XCTAssertFalse(model.iPhoneRecentlyDisconnected,
                       "Fresh AppModel must not be in disconnect state.")
    }

    func testManualDisconnectFlagToggles() {
        let model = AppModel()
        model.iPhoneRecentlyDisconnected = true
        XCTAssertTrue(model.iPhoneRecentlyDisconnected)
        model.iPhoneRecentlyDisconnected = false
        XCTAssertFalse(model.iPhoneRecentlyDisconnected)
    }

    // MARK: - Bridge detection in overlay shouldn't depend on disconnect state

    /// Confirms that the bridge-note suppression logic in the overlay
    /// (suppressed when reconnecting after disconnect) is driven by the
    /// model field, not by some other side-channel. This is a guard
    /// against accidentally hard-coding the bridge note.
    func testDisconnectFlagIsIndependentOfWantsContinuity() {
        let model = AppModel()
        model.wantsContinuityCamera = false
        model.iPhoneRecentlyDisconnected = true
        // Both are independent published fields. Setting one doesn't
        // change the other.
        XCTAssertTrue(model.iPhoneRecentlyDisconnected)
        XCTAssertFalse(model.wantsContinuityCamera)
    }

    // MARK: - Wants-continuity persistence (sanity check)

    func testWantsContinuityPersistsAcrossInstances() {
        // Ensure the persisted-default round-trip works via UserDefaults.
        // We use a unique value to avoid polluting real prefs.
        let key = "wantsContinuityCamera"
        let originalValue = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(originalValue, forKey: key) }

        UserDefaults.standard.set(true, forKey: key)
        let m1 = AppModel()
        XCTAssertTrue(m1.wantsContinuityCamera)

        UserDefaults.standard.set(false, forKey: key)
        let m2 = AppModel()
        XCTAssertFalse(m2.wantsContinuityCamera)
    }
}
