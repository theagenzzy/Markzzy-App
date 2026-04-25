import XCTest
@testable import Markzzy

/// Tests for `CameraBridgeDetector`. Uses the pure-data overload so we
/// don't depend on what's actually installed on the test machine.
final class CameraBridgeDetectorTests: XCTestCase {

    /// Detection only via device name: simulates Camo's virtual camera
    /// being present in AVFoundation. Plugin path is empty (no DAL hit).
    func testDetectsCamoByDeviceName() {
        let result = CameraBridgeDetector.detect(
            deviceNames: ["Camo Camera", "FaceTime HD Camera"],
            dalPluginsAt: "/nonexistent"
        )
        XCTAssertEqual(result.map(\.id), ["camo"])
    }

    /// Detection via DAL plugin: simulates EpocCam being installed but
    /// disconnected (no device in the AVFoundation list).
    func testDetectsEpocCamByDALPlugin() throws {
        let tmp = try makeTempDALWith(filenames: ["EpocCam.plugin"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = CameraBridgeDetector.detect(
            deviceNames: ["FaceTime HD Camera"],   // no devices from any bridge
            dalPluginsAt: tmp.path
        )
        XCTAssertEqual(result.map(\.id), ["epoccam"])
    }

    /// Multiple bridges installed simultaneously.
    func testDetectsMultipleBridges() throws {
        let tmp = try makeTempDALWith(filenames: ["EpocCam.plugin", "IriunWebcam.plugin"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = CameraBridgeDetector.detect(
            deviceNames: ["Camo Camera", "DroidCam"],
            dalPluginsAt: tmp.path
        )
        // Order is the static `known` order: camo, epoccam, iriun, droidcam, ndi
        XCTAssertEqual(result.map(\.id).sorted(), ["camo", "droidcam", "epoccam", "iriun"])
    }

    /// Clean Mac, no bridges anywhere.
    func testReturnsEmptyWhenNoBridges() {
        let result = CameraBridgeDetector.detect(
            deviceNames: ["FaceTime HD Camera", "iPhone Camera"],
            dalPluginsAt: "/nonexistent"
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Random external camera that doesn't match any known bridge pattern.
    func testIgnoresUnknownExternalCameras() {
        let result = CameraBridgeDetector.detect(
            deviceNames: ["Logitech BRIO 4K", "EOS Webcam Utility"],
            dalPluginsAt: "/nonexistent"
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Verify our known list has the expected vendors. If we add or remove
    /// one, this test fails loudly so we remember to update docs.
    func testKnownBridgesContainExpectedVendors() {
        let ids = Set(CameraBridgeDetector.known.map(\.id))
        XCTAssertEqual(ids, Set(["camo", "epoccam", "iriun", "droidcam", "ndi"]))
    }

    /// Each known bridge must expose a vendor URL we can show in the UI.
    func testEachKnownBridgeHasVendorURL() {
        for bridge in CameraBridgeDetector.known {
            XCTAssertNotNil(bridge.vendorURL,
                            "\(bridge.displayName) has no vendor URL — UI 'Learn more' link would be missing.")
            XCTAssertEqual(bridge.vendorURL?.scheme, "https",
                           "\(bridge.displayName) vendor URL must be HTTPS.")
        }
    }

    // MARK: - Helpers

    private func makeTempDALWith(filenames: [String]) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markzzy-bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in filenames {
            try Data().write(to: tmp.appendingPathComponent(name))
        }
        return tmp
    }
}
