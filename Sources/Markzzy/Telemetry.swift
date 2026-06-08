import Foundation
import Darwin

// MARK: - Async-signal-safe native crash handler (file-scope, no captures)

/// Pre-allocated backtrace buffer (allocating inside a signal handler is NOT
/// async-signal-safe; reading a global pointer is).
private let mzBacktraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
/// fd of the crash file, opened once at start so the handler only does
/// async-signal-safe `backtrace` + `backtrace_symbols_fd` + `write`.
private var mzCrashFD: Int32 = -1

private func mzSignalHandler(_ sig: Int32) {
    if mzCrashFD >= 0 {
        let n = backtrace(mzBacktraceBuffer, 128)
        backtrace_symbols_fd(mzBacktraceBuffer, n, mzCrashFD)   // async-signal-safe
    }
    signal(sig, SIG_DFL)
    raise(sig)   // let the OS produce its normal crash report too
}

/// Lightweight, dependency-free crash + error reporter.
///
/// - Native crashes (SIGSEGV/SIGABRT/…) and uncaught exceptions are written to a
///   file using async-signal-safe calls, then POSTed on the NEXT launch.
/// - Handled errors (`report`) are POSTed immediately, fire-and-forget.
/// - NO PII: only an anonymous install id + app/OS/model.
///
/// SERVER TODO: implement `POST https://markzzy.tech/api/telemetry` accepting the
/// JSON below ({type, event, info, trace, installId, app, build, os, model,
/// locale}) and storing it. Until it exists, sends just fail silently.
enum Telemetry {
    private static let base = "https://markzzy.tech"

    private static var isDev: Bool { (Bundle.main.bundleIdentifier ?? "").hasPrefix("dev.") }

    private static var crashPath: String {
        let root = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let dir = (root as NSString).appendingPathComponent("Markzzy")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("last-crash.txt")
    }

    /// Install handlers + flush any crash recorded on the previous launch.
    static func start() {
        flushPendingCrash()            // read BEFORE we truncate the file below
        installHandlers()
    }

    /// Report a handled error/event (fire-and-forget). Safe from any thread.
    static func report(_ event: String, _ info: [String: String] = [:]) {
        send(type: "event", event: event, info: info, trace: nil)
    }

    // MARK: - Internals

    private static func installHandlers() {
        let fd = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        mzCrashFD = fd
        for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(s, mzSignalHandler)
        }
        NSSetUncaughtExceptionHandler { ex in
            // Exception handler (not a signal handler) → allocation is allowed.
            let text = "EXCEPTION \(ex.name.rawValue): \(ex.reason ?? "")\n"
                + ex.callStackSymbols.joined(separator: "\n") + "\n"
            if mzCrashFD >= 0 { _ = text.withCString { write(mzCrashFD, $0, strlen($0)) } }
        }
    }

    private static func flushPendingCrash() {
        let path = crashPath
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = FileManager.default.contents(atPath: path),
              let trace = String(data: data, encoding: .utf8),
              !trace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        send(type: "crash", event: "native_crash", info: [:], trace: trace)
    }

    private static let installId: String = {
        let key = "MARKZZY_INSTALL_ID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private static var hwModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func send(type: String, event: String, info: [String: String], trace: String?) {
        let appV = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var payload: [String: Any] = [
            "type": type, "event": event, "info": info,
            "installId": installId, "app": appV, "build": build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": hwModel, "locale": Locale.current.identifier,
        ]
        if let trace { payload["trace"] = String(trace.prefix(20_000)) }

        // Don't spam production telemetry from dev builds — just log locally.
        if isDev { print("TELEMETRY[\(type)] \(event) \(info)"); return }

        guard let url = URL(string: base + "/api/telemetry"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req).resume()   // fire-and-forget
    }
}
