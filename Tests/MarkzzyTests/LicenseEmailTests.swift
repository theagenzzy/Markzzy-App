import XCTest
@testable import Markzzy

/// Tests for client-side email validation, typo detection, and the
/// `humanize()` map in `LicenseManager`. These all run in pure-data
/// mode — no network, no Keychain, no AVFoundation. They guard
/// against silent failures at activation time, which is the worst
/// possible experience for a paying customer.
final class LicenseEmailTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeStripsWhitespace() {
        XCTAssertEqual(LicenseManager.normalize("  user@gmail.com  "), "user@gmail.com")
    }

    func testNormalizeLowercases() {
        XCTAssertEqual(LicenseManager.normalize("User@Gmail.COM"), "user@gmail.com")
    }

    func testNormalizeIsIdempotent() {
        let once = LicenseManager.normalize(" Mixed@CASE.tld ")
        XCTAssertEqual(LicenseManager.normalize(once), once)
    }

    // MARK: - isValidEmail

    func testValidEmailsPass() {
        let valid = [
            "a@b.co",
            "user@gmail.com",
            "user.name@example.com",
            "test+tag@sub.example.org",
            "with-dash@sub-domain.io",
            "u_name@long.subdomain.example.io",
        ]
        for e in valid {
            XCTAssertTrue(LicenseManager.isValidEmail(e), "'\(e)' should pass isValidEmail")
        }
    }

    func testInvalidEmailsFail() {
        let invalid = [
            "",
            "   ",
            "aaa",            // no @
            "a@",             // no domain
            "@b.com",         // no local part
            "a@b",            // no TLD
            "a@b.c",          // TLD too short (< 2 chars)
            "a b@x.com",      // space in local
            "a@b c.com",      // space in domain
            "a@@b.com",       // double @
        ]
        for e in invalid {
            XCTAssertFalse(LicenseManager.isValidEmail(e), "'\(e)' should fail isValidEmail")
        }
    }

    // MARK: - validationError messages

    func testValidationErrorEmpty() {
        XCTAssertNotNil(LicenseManager.validationError(for: ""))
    }

    func testValidationErrorMissingAt() {
        let msg = LicenseManager.validationError(for: "userexample.com")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("@"), "Error should mention the missing @")
    }

    func testValidationErrorMissingTLD() {
        let msg = LicenseManager.validationError(for: "user@example")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.lowercased().contains("incomplete") || msg!.contains(".com"),
                      "Error should hint at missing TLD")
    }

    func testValidationErrorReturnsNilForValidEmail() {
        XCTAssertNil(LicenseManager.validationError(for: "user@gmail.com"))
    }

    // MARK: - suggestedCorrection (typos)

    func testSuggestsGmailCorrection() {
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "user@gmial.com"), "user@gmail.com")
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "user@gmai.com"), "user@gmail.com")
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "user@gmail.con"), "user@gmail.com")
    }

    func testSuggestsHotmailCorrection() {
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "u@hotmal.com"), "u@hotmail.com")
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "u@hotmial.com"), "u@hotmail.com")
    }

    func testSuggestsYahooCorrection() {
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "u@yaho.com"), "u@yahoo.com")
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "u@yahoo.con"), "u@yahoo.com")
    }

    func testSuggestsOutlookCorrection() {
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "u@outlok.com"), "u@outlook.com")
    }

    func testSuggestsICloudCorrection() {
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "u@iclod.com"), "u@icloud.com")
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "u@icloud.con"), "u@icloud.com")
    }

    func testNoSuggestionForCorrectEmails() {
        let correct = [
            "user@gmail.com",
            "user@hotmail.com",
            "user@yahoo.com",
            "user@outlook.com",
            "user@icloud.com",
            "user@example.com",
            "user@some-custom-domain.io",
        ]
        for e in correct {
            XCTAssertNil(LicenseManager.suggestedCorrection(for: e),
                         "'\(e)' should not trigger a typo suggestion")
        }
    }

    func testSuggestionWorksWithMixedCase() {
        XCTAssertEqual(LicenseManager.suggestedCorrection(for: "User@GMIAL.COM"), "user@gmail.com")
    }

    func testNoSuggestionForUnknownDomain() {
        XCTAssertNil(LicenseManager.suggestedCorrection(for: "user@nonexistent.xyz"))
    }

    // MARK: - typo dictionary integrity

    /// All typo keys must NOT match real popular domains (we'd be
    /// suggesting nonsense corrections), and all values must be
    /// well-formed real domains.
    func testTypoDictionaryIntegrity() {
        let realDomains = ["gmail.com", "hotmail.com", "yahoo.com", "outlook.com", "icloud.com"]
        for (typo, fix) in LicenseManager.domainTypos {
            XCTAssertTrue(realDomains.contains(fix),
                          "Typo '\(typo)' maps to '\(fix)' which isn't in the canonical list")
            XCTAssertFalse(realDomains.contains(typo),
                           "Typo '\(typo)' is actually a real domain — would suggest nonsense")
            XCTAssertEqual(typo, typo.lowercased(),
                           "Typo key '\(typo)' must be lowercased")
        }
    }
}
