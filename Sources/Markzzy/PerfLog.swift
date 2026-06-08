import Foundation

/// Append-only diagnostic log written to a fixed file path so it can be
/// inspected regardless of how the app was launched (GUI double-click,
/// `open`, self-test). `print()` goes to stdout which `log show` does
/// not capture for GUI apps — this does.
///
/// File: /tmp/markzzy-perf.log  (truncated on each recording start)
enum PerfLog {
    static let path = "/tmp/markzzy-perf.log"

    /// Diagnostics are ON for dev builds (bundle id `dev.`) and OFF in production
    /// unless the user opts in (`defaults write tech.markzzy.Markzzy
    /// MARKZZY_DIAGNOSTICS -bool YES`) — so a release build doesn't write device
    /// names / timing to /tmp by default. Support can ask a user to enable it.
    private static let enabled: Bool = {
        if (Bundle.main.bundleIdentifier ?? "").hasPrefix("dev.") { return true }
        return UserDefaults.standard.bool(forKey: "MARKZZY_DIAGNOSTICS")
    }()

    private static let queue = DispatchQueue(label: "dev.markzzy.perflog")
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Truncate + write a header. Call once when a recording starts.
    static func begin(_ header: String) {
        guard enabled else { return }
        queue.async {
            let line = "=== \(df.string(from: Date())) \(header) ===\n"
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
    }

    static func log(_ message: String) {
        guard enabled else { return }
        queue.async {
            let line = "\(df.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
