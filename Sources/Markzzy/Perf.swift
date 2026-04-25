import os.signpost

/// Lightweight wrapper around os_signpost so cold-start work can be
/// inspected in Instruments (Time Profiler / Points of Interest) without
/// littering the call sites with subsystem boilerplate.
///
/// Usage:
///   let id = Perf.begin("AppModel.bootstrap")
///   defer { Perf.end("AppModel.bootstrap", id: id) }
///
/// Signposts are zero-cost in release builds when no profiler is
/// attached, so it's safe to leave them in.
enum Perf {
    static let log = OSLog(subsystem: "dev.markzzy.app", category: .pointsOfInterest)

    @discardableResult
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
