import Foundation
import ScreenCaptureKit
import CoreMedia

public struct ScreenSource: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let width: Int
    public let height: Int
    let display: SCDisplay?
    let window: SCWindow?

    public func hash(into h: inout Hasher) { h.combine(id) }
    public static func == (a: ScreenSource, b: ScreenSource) -> Bool { a.id == b.id }
}

public enum ScreenCapture {
    public static func listSources() async -> [ScreenSource] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displays = content.displays.map { d in
                ScreenSource(
                    id: "display-\(d.displayID)",
                    title: "Display \(d.displayID) (\(d.width)×\(d.height))",
                    width: d.width, height: d.height,
                    display: d, window: nil
                )
            }
            return displays
        } catch {
            return []
        }
    }

    public static func makeStream(for source: ScreenSource,
                                  output: SCStreamOutput,
                                  queue: DispatchQueue) throws -> SCStream {
        guard let display = source.display else {
            throw NSError(domain: "Markzzy.ScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Only display sources supported in MVP"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = source.width
        config.height = source.height
        // 30fps caps both capture AND composition work — recorder writes at 30fps
        // anyway, so going higher just burned CPU on frames the encoder ignored.
        // Going to 30fps roughly halves the per-frame load for the screen leg.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        // queueDepth defaults to 8; bumping to 6 keeps a small backlog without
        // letting late frames pile up if the encoder briefly stalls.
        config.queueDepth = 6
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        return stream
    }
}
