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

    /// Pre-flight before recording: the output folder must exist + be writable
    /// and there must be a minimum of free disk space. Returns a user-facing
    /// error message (localized), or nil if everything's OK.
    func preflightRecording() -> String? {
        let es = (language == .es)
        let dir = outputDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return es ? "No se puede escribir en la carpeta de salida. Elige otra en Ajustes."
                      : "Can't write to the output folder. Pick another in Settings."
        }
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            return es ? "La carpeta de salida no permite escritura. Elige otra en Ajustes."
                      : "The output folder isn't writable. Pick another in Settings."
        }
        // Purgeable-aware free space on the target volume.
        if let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let avail = vals.volumeAvailableCapacityForImportantUsage,
           avail < 500 * 1024 * 1024 {   // 500 MB minimum headroom
            return es ? "Poco espacio en disco para grabar. Libera espacio e inténtalo de nuevo."
                      : "Not enough free disk space to record. Free up space and try again."
        }
        return nil
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
