import XCTest
@testable import Markzzy

@MainActor
final class LibraryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markzzy-lib-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: "outputDirectoryPath")
    }

    func testListRecordedVideos_filtersMP4AndSortsByDateDesc() async throws {
        try makeFile("Markzzy-2026-01-01-100000.mp4", date: Date().addingTimeInterval(-3600))
        try makeFile("Markzzy-2026-01-02-100000.mp4", date: Date().addingTimeInterval(-60))
        try makeFile("README.txt", date: Date())
        try makeFile("Markzzy-2026-01-03-100000.mp4", date: Date())

        let model = AppModel()
        model.outputDirectory = tempDir

        let items = model.listRecordedVideos()
        XCTAssertEqual(items.count, 3, "only .mp4 files should be listed")
        XCTAssertTrue(items.allSatisfy { $0.url.pathExtension == "mp4" })

        let dates = items.map { $0.date }
        XCTAssertEqual(dates, dates.sorted(by: >), "newest first")
    }

    func testListRecordedVideos_includesSizeAndName() async throws {
        let url = try makeFile("Markzzy-test.mp4", date: Date(), bytes: 1234)
        let model = AppModel()
        model.outputDirectory = tempDir

        let items = model.listRecordedVideos()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.url.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(item.name, "Markzzy-test.mp4")
        XCTAssertEqual(item.size, 1234)
    }

    func testDeleteVideo_removesFile() async throws {
        let url = try makeFile("Markzzy-delete-me.mp4", date: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let model = AppModel()
        model.outputDirectory = tempDir
        try model.deleteVideo(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(model.listRecordedVideos().isEmpty)
    }

    func testOutputDirectory_persistsAndCreatesFolder() async throws {
        let newDir = tempDir.appendingPathComponent("nested/videos", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))

        let model = AppModel()
        model.outputDirectory = newDir

        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path),
                      "setter should create the folder")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "outputDirectoryPath"),
                       newDir.path,
                       "setter should persist path to UserDefaults")

        // A fresh AppModel reads from UserDefaults.
        let reloaded = AppModel()
        XCTAssertEqual(reloaded.outputDirectory.path, newDir.path)
    }

    func testDefaultOutputURL_isInsideCurrentOutputDirectory() async throws {
        let model = AppModel()
        model.outputDirectory = tempDir
        let out = model.defaultOutputURL()
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL,
                       tempDir.standardizedFileURL)
        XCTAssertEqual(out.pathExtension, "mp4")
        XCTAssertTrue(out.lastPathComponent.hasPrefix("Markzzy-"))
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ name: String, date: Date, bytes: Int = 0) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let data = Data(repeating: 0, count: bytes)
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
        return url
    }
}
