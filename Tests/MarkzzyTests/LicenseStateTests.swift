import XCTest
@testable import Markzzy

/// Tests the LicenseManager state-machine + computed properties that
/// drive the trial banner / lock view / payment-issue UIs.
///
/// All tests run in pure-data mode — we set the @Published fields
/// directly to simulate a server response, then assert the computed
/// properties react correctly. No network, no Keychain.
@MainActor
final class LicenseStateTests: XCTestCase {

    // MARK: - Trial countdown

    func testTrialDaysRemainingHigh() {
        let m = LicenseManager()
        m._setTestState(subStatus: .trialing, currentPeriodEnd: Date().addingTimeInterval(7 * 86_400))
        XCTAssertTrue(m.isTrialing)
        XCTAssertEqual(m.trialDaysRemaining, 6, "rounds down: ~7 days minus a sec = 6")
    }

    func testTrialEndsToday() {
        let m = LicenseManager()
        m._setTestState(subStatus: .trialing, currentPeriodEnd: Date().addingTimeInterval(3600))
        XCTAssertEqual(m.trialDaysRemaining, 0, "anything < 24h is 'today'")
    }

    func testTrialAlreadyEnded() {
        let m = LicenseManager()
        m._setTestState(subStatus: .trialing, currentPeriodEnd: Date().addingTimeInterval(-3600))
        XCTAssertEqual(m.trialDaysRemaining, 0)
    }

    func testNoTrialDaysWhenNotTrialing() {
        let m = LicenseManager()
        m._setTestState(subStatus: .active, currentPeriodEnd: Date().addingTimeInterval(86_400))
        XCTAssertNil(m.trialDaysRemaining)
    }

    // MARK: - Past due

    func testPaymentPastDue() {
        let m = LicenseManager()
        m._setTestState(subStatus: .pastDue, paymentFailedCount: 2)
        XCTAssertTrue(m.paymentPastDue)
    }

    func testNotPastDueWhenActive() {
        let m = LicenseManager()
        m._setTestState(subStatus: .active)
        XCTAssertFalse(m.paymentPastDue)
    }

    // MARK: - Canceled mid-period

    func testWillEndAtWhenCanceledMidPeriod() {
        let endsAt = Date().addingTimeInterval(5 * 86_400)
        let m = LicenseManager()
        m._setTestState(subStatus: .active, currentPeriodEnd: endsAt, cancelAtPeriodEnd: true)
        XCTAssertEqual(m.willEndAt?.timeIntervalSince1970, endsAt.timeIntervalSince1970)
    }

    func testWillEndAtNilWhenNotCanceled() {
        let m = LicenseManager()
        m._setTestState(subStatus: .active, currentPeriodEnd: Date().addingTimeInterval(86_400))
        XCTAssertNil(m.willEndAt)
    }

    // MARK: - Plan flavor checks

    func testIsTrialingTrue() {
        let m = LicenseManager()
        m._setTestState(subStatus: .trialing)
        XCTAssertTrue(m.isTrialing)
    }

    // MARK: - Cancel/upgrade capability matrix
    //
    // These mirror the web dashboard's UX decisions: lifetime can't be
    // canceled (it's one-time), already-canceled can't be canceled again,
    // and upgrade only makes sense from trial.

    func testCanCancelWhenTrialing() {
        let m = LicenseManager()
        m._setTestState(subStatus: .trialing)
        // Trial users can cancel before they're charged.
        XCTAssertTrue(canCancel(m))
    }

    func testCanCancelWhenMonthly() {
        let m = LicenseManager()
        m._setTestState(subStatus: .active)
        // Monthly users can cancel any time.
        XCTAssertTrue(canCancel(m))
    }

    func testCannotCancelWhenAlreadyCanceledMidPeriod() {
        let m = LicenseManager()
        m._setTestState(
            subStatus: .active,
            currentPeriodEnd: Date().addingTimeInterval(5 * 86_400),
            cancelAtPeriodEnd: true
        )
        // Already canceled — show Reactivate instead, not another Cancel.
        XCTAssertFalse(canCancel(m))
    }

    func testReactivateAvailableWhenCanceledMidPeriod() {
        let m = LicenseManager()
        m._setTestState(
            subStatus: .active,
            currentPeriodEnd: Date().addingTimeInterval(5 * 86_400),
            cancelAtPeriodEnd: true
        )
        XCTAssertNotNil(m.willEndAt)
    }

    func testUpgradeOnlyForTrial() {
        let trial = LicenseManager()
        trial._setTestState(subStatus: .trialing)
        XCTAssertTrue(shouldShowUpgrade(trial))

        let monthly = LicenseManager()
        monthly._setTestState(subStatus: .active)
        XCTAssertFalse(shouldShowUpgrade(monthly), "Monthly users have nothing to upgrade to from this CTA")
    }

    // MARK: - URL builders

    func testOpenUpgradeBuildsCorrectURL() {
        // We can't open URLs from a unit test, but we can verify the URL
        // shape by replicating the construction. If the format changes,
        // this test reminds us to update the docs / web handler.
        var components = URLComponents(string: "https://markzzy.tech/dashboard")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "upgrade"),
            URLQueryItem(name: "email", value: "user@example.com"),
        ]
        let url = components?.url
        XCTAssertNotNil(url)
        let str = url?.absoluteString ?? ""
        XCTAssertTrue(str.contains("action=upgrade"))
        XCTAssertTrue(str.contains("user@example.com"))
        XCTAssertTrue(str.hasPrefix("https://markzzy.tech/dashboard?"))
    }

    func testOpenCancelBuildsCorrectURL() {
        var components = URLComponents(string: "https://markzzy.tech/dashboard")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "cancel"),
            URLQueryItem(name: "email", value: "user@example.com"),
        ]
        XCTAssertTrue(components?.url?.absoluteString.contains("action=cancel") ?? false)
    }

    /// `webBase` is the single source of truth for every "Open in browser"
    /// link in the app. If this contract drifts, dev builds will jump to
    /// production every time the user clicks Upgrade / Manage / Website.
    func testWebBaseFollowsApiBaseEnv() {
        let m = LicenseManager()
        let envBase = ProcessInfo.processInfo.environment["MARKZZY_API_BASE"]
        let expected = envBase ?? "https://markzzy.tech"
        XCTAssertEqual(
            m.webBase.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            expected.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "webBase must derive from MARKZZY_API_BASE so dev builds stay on localhost"
        )
    }

    func testWebBaseProducesValidDashboardURL() {
        let m = LicenseManager()
        // Mirror what openDashboard() builds — verifies the shape held by
        // every web-link action method (openUpgrade, openCancel, etc.).
        var c = URLComponents(url: m.webBase.appendingPathComponent("dashboard"),
                              resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "email", value: "user@example.com")]
        let str = c?.url?.absoluteString ?? ""
        XCTAssertTrue(str.contains("/dashboard"))
        XCTAssertTrue(str.contains("email=user@example.com"))
    }

    // MARK: - Helpers (mirror the SettingsView gating logic)

    private func canCancel(_ m: LicenseManager) -> Bool {
        // From SettingsView.licenseActionsCard: !lifetime && !cancelAtPeriodEnd
        !m.isLifetime && !m.cancelAtPeriodEnd
    }

    private func shouldShowUpgrade(_ m: LicenseManager) -> Bool {
        // From SettingsView.licenseActionsCard: only when trialing
        m.isTrialing
    }
}

// MARK: - Test-only state injector
//
// Avoids exposing setters in production while still letting tests
// drive the state machine deterministically. Marked internal so
// `@testable import Markzzy` can reach it.
extension LicenseManager {
    func _setTestState(
        subStatus: SubStatus,
        currentPeriodEnd: Date? = nil,
        cancelAtPeriodEnd: Bool = false,
        paymentFailedAt: Date? = nil,
        paymentFailedCount: Int = 0
    ) {
        // We can't write to private(set) properties from outside; the
        // setters are added below as a private extension.
        self._test_setSubStatus(subStatus)
        self._test_setCurrentPeriodEnd(currentPeriodEnd)
        self._test_setCancelAtPeriodEnd(cancelAtPeriodEnd)
        self._test_setPaymentFailedAt(paymentFailedAt)
        self._test_setPaymentFailedCount(paymentFailedCount)
    }
}
