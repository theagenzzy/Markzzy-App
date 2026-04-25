import XCTest
import AVFoundation
@testable import Markzzy

/// Tests for `DeviceFilter`'s iPhone-detection scoring. We exercise the
/// pure-data overloads of `iPhoneAffinity` so we don't need to instantiate
/// real `AVCaptureDevice`s (which require actual hardware).
final class DeviceFilterTests: XCTestCase {

    // MARK: - iPhoneAffinity scoring

    func testNativeContinuityScoresFour() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .continuityCamera,
            modelID: "iPhone11,6",
            manufacturer: "Apple Inc.",
            localizedName: "Crisodevelop's iPhone"
        )
        XCTAssertEqual(score, 4, "Native .continuityCamera must always win.")
    }

    func testAppleModelIDScoresThree() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "iPhone11,6",
            manufacturer: "Apple Inc.",
            localizedName: "iPhone Camera"
        )
        XCTAssertEqual(score, 3, "modelID starting with 'iPhone' indicates a real iPhone bridged through.")
    }

    func testAppleManufacturerExternalScoresThree() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "MysteryDevice",   // bridge stripped the modelID
            manufacturer: "Apple Inc.",
            localizedName: "Mystery Camera"
        )
        XCTAssertEqual(score, 3, "Apple manufacturer + external = fallback when modelID is hidden.")
    }

    func testAppleManufacturerBuiltInDoesNotScoreThree() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .builtInWideAngleCamera,
            modelID: "FaceTime HD Camera",
            manufacturer: "Apple Inc.",
            localizedName: "FaceTime HD Camera"
        )
        XCTAssertEqual(score, 0, "Built-in Apple cameras (FaceTime HD) must NOT score as iPhone.")
    }

    func testNameContainsIPhoneScoresTwo() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "BridgeDevice",      // no Apple modelID
            manufacturer: "ThirdParty",   // no Apple manufacturer
            localizedName: "My iPhone via Bridge"
        )
        XCTAssertEqual(score, 2, "Name containing 'iphone' is the resilience fallback.")
    }

    func testCamoNameScoresOne() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "Camo Camera",
            manufacturer: "Reincubate",
            localizedName: "Camo Camera"
        )
        XCTAssertEqual(score, 1, "Generic bridge driver names are last resort, only via opt-in.")
    }

    func testEpocCamScoresOne() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "EpocCam HD",
            manufacturer: "Elgato",
            localizedName: "EpocCam HD"
        )
        XCTAssertEqual(score, 1)
    }

    func testFaceTimeHDScoresZero() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .builtInWideAngleCamera,
            modelID: "FaceTime HD Camera",
            manufacturer: "Apple Inc.",
            localizedName: "FaceTime HD Camera"
        )
        XCTAssertEqual(score, 0, "FaceTime HD is a built-in webcam, not an iPhone.")
    }

    func testEosWebcamScoresZero() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "EOS Webcam Utility",
            manufacturer: "Canon U.S.A., Inc.",
            localizedName: "EOS Webcam Utility"
        )
        XCTAssertEqual(score, 0, "Random external cameras are not iPhones.")
    }

    func testEmptyStringsScoresZero() {
        let score = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "",
            manufacturer: "",
            localizedName: ""
        )
        XCTAssertEqual(score, 0)
    }

    // MARK: - Tiebreaker behavior (Continuity > iPhone-via-bridge)

    func testContinuityBeatsBridgedIPhone() {
        let continuity = DeviceFilter.iPhoneAffinity(
            deviceType: .continuityCamera,
            modelID: "iPhone11,6",
            manufacturer: "Apple Inc.",
            localizedName: "iPhone"
        )
        let bridged = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "iPhone11,6",
            manufacturer: "Apple Inc.",
            localizedName: "iPhone Camera"
        )
        XCTAssertGreaterThan(continuity, bridged,
                             "Native Continuity must win when both paths exist (lower latency).")
    }

    func testRealIPhoneBeatsCamo() {
        let realIPhone = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "iPhone11,6",
            manufacturer: "Apple Inc.",
            localizedName: "iPhone Camera"
        )
        let camo = DeviceFilter.iPhoneAffinity(
            deviceType: .external,
            modelID: "Camo Camera",
            manufacturer: "Reincubate",
            localizedName: "Camo Camera"
        )
        XCTAssertGreaterThan(realIPhone, camo,
                             "Real iPhone (modelID match) must beat generic bridge.")
    }

    // MARK: - DeviceFilter struct

    func testDefaultFilterRejectsBridges() {
        let f = DeviceFilter()
        XCTAssertEqual(f.minIPhoneAffinity, 2,
                       "Default filter must require score >= 2 (rejects generic bridges).")
    }

    func testAllowVirtualCamerasFilterAcceptsBridges() {
        let f = DeviceFilter(allowVirtualCameras: true)
        XCTAssertEqual(f.minIPhoneAffinity, 1,
                       "When user opts into virtual cameras, accept score >= 1.")
    }

    func testHideVirtualDevicesFiltersByName() {
        // We can't construct AVCaptureDevices in tests, but we can verify
        // looksVirtual on names directly via the keyword helper logic.
        let virtualNames = ["OBS Virtual Camera", "BlackHole 2ch", "Loopback Audio"]
        let realNames = ["FaceTime HD Camera", "iPhone Camera", "External USB Mic"]

        for name in virtualNames {
            XCTAssertTrue(
                DeviceFilter.virtualKeywords.contains { name.lowercased().contains($0) },
                "\(name) should be classified as virtual."
            )
        }
        for name in realNames {
            XCTAssertFalse(
                DeviceFilter.virtualKeywords.contains { name.lowercased().contains($0) },
                "\(name) should NOT be classified as virtual."
            )
        }
    }

    func testIPhoneBridgeKeywordsContainsExpectedVendors() {
        let kw = DeviceFilter.iPhoneBridgeKeywords
        XCTAssertTrue(kw.contains("camo"))
        XCTAssertTrue(kw.contains("epoccam"))
        XCTAssertTrue(kw.contains("iphone"))
    }
}
