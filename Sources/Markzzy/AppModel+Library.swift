import Foundation

/// Library + output-directory helpers extracted from `AppModel`. These
/// don't touch capture pipelines or camera state — pure file I/O against
/// the user's chosen `outputDirectory`.
extension AppModel {

    /// Where the next recording will be written. Builds a UTC-timestamped
    /// filename inside the user's `outputDirectory` so two captures
    /// started in the same second can never collide.
    func defaultOutputURL() -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputDirectory.appendingPathComponent("Markzzy-\(fmt.string(from: Date())).mp4")
    }

    /// Lists every `.mp4` Markzzy has produced under the current
    /// `outputDirectory`, newest first. Hidden files are skipped.
    /// Returns an empty array on any I/O error (the Library tab handles
    /// "no recordings yet" as the same UX as "couldn't read folder").
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

    /// Resolves the persisted output directory at app launch. Falls back
    /// to `~/Desktop/Videos` (and creates it) when nothing is stored.
    static func loadStoredOutputDirectory() -> URL {
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
}
