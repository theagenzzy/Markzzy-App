import Foundation
import AppKit
import CoreGraphics

/// FaceCam state serialization extracted from `AppModel`. The PIP shape,
/// size, position and border are loaded once at launch (when the user
/// has `rememberFaceCam` on) and saved on every change.
extension AppModel {

    /// JSON shape for the persisted face cam — `Codable` so we can round-trip
    /// through `UserDefaults` without writing a custom serializer.
    struct PersistedFaceCam: Codable {
        var shape: String
        var size: Double
        var positionX: Double
        var positionY: Double
        var borderStyle: String
        var borderColor: [Double]
        var borderColor2: [Double]
        var borderWidth: Double
        // Background removal — optional so older payloads still decode.
        var removeBackground: Bool?
        var bgTransparent: Bool?
        var bgColor: [Double]?
        var freeform: Bool?
        // Transparent mode has its OWN size+position sub-slot (color uses the
        // top-level size/positionX/Y). Optional → old payloads default.
        var transparentSize: Double?
        var transparentPosX: Double?
        var transparentPosY: Double?
    }

    /// In-memory snapshot of the four face cam attributes the app cares
    /// about. Used as the return type of `loadedFaceCam()` so we can wire
    /// each `@Published` property cleanly at init time.
    struct FaceCamValues {
        let shape: PIPShape
        let size: CGFloat
        let position: CGPoint
        let border: PIPBorder
        let removeBackground: Bool
        let bgTransparent: Bool
        let bgColor: CGColor
        let freeform: Bool
        // Transparent sub-slot (independent from color size/position).
        let transparentSize: CGFloat
        let transparentPosition: CGPoint
    }

    static let defaultBgColor = CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
    /// Transparent silhouette default: bottom-center, flush to the floor
    /// (y=1.0 clamps to the bottom edge), ~55% width.
    static let defaultTransparentSize: CGFloat = 0.55
    static let defaultTransparentPosition = CGPoint(x: 0.5, y: 1.0)

    static let defaultFaceCam = FaceCamValues(
        shape: .circle,
        size: 0.22,
        position: CGPoint(x: 0.85, y: 0.88),
        border: PIPBorder(),
        removeBackground: false,
        bgTransparent: true,
        bgColor: defaultBgColor,
        freeform: false,
        transparentSize: defaultTransparentSize,
        transparentPosition: defaultTransparentPosition
    )

    /// Per-format face-cam settings. Each output format (YouTube / Reel /
    /// Square) keeps its own camera size, position, shape, border and
    /// background-removal style so they don't bleed into each other.
    struct PersistedFaceCamSet: Codable {
        var byFormat: [String: PersistedFaceCam]
    }

    /// Decode the per-format set, migrating the legacy single-blob key the
    /// first time (seed it into all formats so existing config carries over).
    private static func loadFaceCamSet() -> PersistedFaceCamSet {
        if let data = UserDefaults.standard.data(forKey: Keys.faceCamByFormat),
           let set = try? JSONDecoder().decode(PersistedFaceCamSet.self, from: data) {
            return set
        }
        // Migration: seed every format from the old global blob if present.
        if let legacy = UserDefaults.standard.data(forKey: Keys.faceCam),
           let p = try? JSONDecoder().decode(PersistedFaceCam.self, from: legacy) {
            var byFormat: [String: PersistedFaceCam] = [:]
            for f in OutputFormat.allCases { byFormat[f.rawValue] = p }
            return PersistedFaceCamSet(byFormat: byFormat)
        }
        return PersistedFaceCamSet(byFormat: [:])
    }

    private static func decode(_ p: PersistedFaceCam) -> FaceCamValues {
        let shape = PIPShape(rawValue: p.shape) ?? defaultFaceCam.shape
        let style = PIPBorder.Style(rawValue: p.borderStyle) ?? .none
        let c1 = cgColor(from: p.borderColor) ?? defaultFaceCam.border.color
        let c2 = cgColor(from: p.borderColor2) ?? defaultFaceCam.border.color2
        let bgColor = p.bgColor.flatMap { cgColor(from: $0) } ?? defaultBgColor
        let tPos = CGPoint(x: p.transparentPosX ?? Double(defaultTransparentPosition.x),
                           y: p.transparentPosY ?? Double(defaultTransparentPosition.y))
        return FaceCamValues(
            shape: shape,
            size: CGFloat(p.size),
            position: CGPoint(x: p.positionX, y: p.positionY),
            border: PIPBorder(style: style, color: c1, color2: c2, width: CGFloat(p.borderWidth)),
            removeBackground: p.removeBackground ?? false,
            bgTransparent: p.bgTransparent ?? true,
            bgColor: bgColor,
            freeform: p.freeform ?? false,
            transparentSize: CGFloat(p.transparentSize ?? Double(defaultTransparentSize)),
            transparentPosition: tPos
        )
    }

    /// Reads the persisted face cam for a given format, or defaults when
    /// nothing's stored or the user opted out via `rememberFaceCam`.
    static func loadedFaceCam(for format: OutputFormat) -> FaceCamValues {
        let remember = UserDefaults.standard.object(forKey: Keys.rememberFaceCam) as? Bool ?? true
        guard remember, let p = loadFaceCamSet().byFormat[format.rawValue] else {
            return defaultFaceCam
        }
        return decode(p)
    }

    /// The LIVE size/position to load for a format, choosing the sub-slot that
    /// matches its saved mode (transparent vs color).
    static func liveSizePosition(for v: FaceCamValues) -> (CGFloat, CGPoint) {
        let transparentMode = v.removeBackground && v.bgTransparent
        return transparentMode ? (v.transparentSize, v.transparentPosition)
                               : (v.size, v.position)
    }

    /// Encode the current in-memory face cam into a `PersistedFaceCam`, writing
    /// the live size/position into the CURRENT mode's sub-slot and preserving the
    /// other sub-slot from what's already stored for `format`.
    private func currentPersistedFaceCam(for format: OutputFormat,
                                         transparentMode: Bool) -> PersistedFaceCam {
        let prior = Self.loadFaceCamSet().byFormat[format.rawValue]

        // Color sub-slot: live when in color mode, else keep prior.
        let colorSize = transparentMode ? (prior?.size ?? Double(pipSize)) : Double(pipSize)
        let colorPosX = transparentMode ? (prior?.positionX ?? Double(pipPosition.x)) : Double(pipPosition.x)
        let colorPosY = transparentMode ? (prior?.positionY ?? Double(pipPosition.y)) : Double(pipPosition.y)
        // Transparent sub-slot: live when in transparent mode, else keep prior.
        let tSize = transparentMode ? Double(pipSize) : (prior?.transparentSize ?? Double(Self.defaultTransparentSize))
        let tPosX = transparentMode ? Double(pipPosition.x) : (prior?.transparentPosX ?? Double(Self.defaultTransparentPosition.x))
        let tPosY = transparentMode ? Double(pipPosition.y) : (prior?.transparentPosY ?? Double(Self.defaultTransparentPosition.y))

        return PersistedFaceCam(
            shape: pipShape.rawValue,
            size: colorSize, positionX: colorPosX, positionY: colorPosY,
            borderStyle: pipBorder.style.rawValue,
            borderColor: Self.rgbaComponents(of: pipBorder.color),
            borderColor2: Self.rgbaComponents(of: pipBorder.color2),
            borderWidth: Double(pipBorder.width),
            removeBackground: removeBackground,
            bgTransparent: faceCamBgTransparent,
            bgColor: Self.rgbaComponents(of: faceCamBgColor),
            freeform: faceCamFreeform,
            transparentSize: tSize, transparentPosX: tPosX, transparentPosY: tPosY
        )
    }

    /// Write the current face cam into the slot for the given format (defaults
    /// to the live `outputFormat`). Gated by `rememberFaceCam`. The
    /// `isReconcilingFaceCam` guard suppresses saves mid format-swap.
    func saveFaceCamIfEnabled(for format: OutputFormat? = nil,
                              transparentMode: Bool? = nil) {
        guard rememberFaceCam, !isReconcilingFaceCam, !pipLiveEditing else { return }
        let fmt = format ?? outputFormat
        let mode = transparentMode ?? (removeBackground && faceCamBgTransparent)
        var set = Self.loadFaceCamSet()
        set.byFormat[fmt.rawValue] = currentPersistedFaceCam(for: fmt, transparentMode: mode)
        if let encoded = try? JSONEncoder().encode(set) {
            UserDefaults.standard.set(encoded, forKey: Keys.faceCamByFormat)
        }
    }

    /// Swap the in-memory face cam to another format's saved values. Called
    /// from `outputFormat.didSet`: saves the OUTGOING format first, then loads
    /// the incoming one, suppressing per-property saves during the bulk assign.
    func reconcileFaceCam(from oldFormat: OutputFormat, to newFormat: OutputFormat) {
        guard oldFormat != newFormat else { return }
        saveFaceCamIfEnabled(for: oldFormat)
        let v = Self.loadedFaceCam(for: newFormat)
        let (liveSize, livePos) = Self.liveSizePosition(for: v)
        isReconcilingFaceCam = true
        pipShape = v.shape
        pipBorder = v.border
        removeBackground = v.removeBackground
        faceCamBgTransparent = v.bgTransparent
        faceCamBgColor = v.bgColor
        faceCamFreeform = v.freeform
        pipSize = liveSize
        pipPosition = livePos
        isReconcilingFaceCam = false
    }

    /// Swap the live size+position between the transparent and color sub-slots
    /// when the Background mode flips. Persists the outgoing mode's values, loads
    /// the incoming mode's. Guarded against didSet feedback.
    func reconcileFaceCamMode(enteringTransparent: Bool) {
        guard !isReconcilingFaceCam else { return }
        // Persist the OUTGOING mode's live size+pos into ITS slot. The flag has
        // already flipped (didSet), so pass the old mode explicitly — otherwise
        // the live values leak into the wrong slot and merge the two modes.
        saveFaceCamIfEnabled(transparentMode: !enteringTransparent)

        let stored = Self.loadFaceCamSet().byFormat[outputFormat.rawValue]
        let size: CGFloat
        let pos: CGPoint
        if enteringTransparent {
            size = CGFloat(stored?.transparentSize ?? Double(Self.defaultTransparentSize))
            pos = CGPoint(x: stored?.transparentPosX ?? Double(Self.defaultTransparentPosition.x),
                          y: stored?.transparentPosY ?? Double(Self.defaultTransparentPosition.y))
        } else {
            size = CGFloat(stored?.size ?? Double(pipSize))
            pos = CGPoint(x: stored?.positionX ?? Double(pipPosition.x),
                          y: stored?.positionY ?? Double(pipPosition.y))
        }
        isReconcilingFaceCam = true
        pipSize = size
        pipPosition = pos
        isReconcilingFaceCam = false
        pushPIP()
        // Persist incoming mode (now the live mode).
        saveFaceCamIfEnabled(transparentMode: enteringTransparent)
    }

    // MARK: - Color round-trip helpers

    static func rgbaComponents(of color: CGColor) -> [Double] {
        guard let ns = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return [0, 0, 0, 1] }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    static func cgColor(from comps: [Double]) -> CGColor? {
        guard comps.count >= 3 else { return nil }
        let a = comps.count >= 4 ? CGFloat(comps[3]) : 1
        return CGColor(red: CGFloat(comps[0]), green: CGFloat(comps[1]),
                       blue: CGFloat(comps[2]), alpha: a)
    }
}
