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
    }

    /// In-memory snapshot of the four face cam attributes the app cares
    /// about. Used as the return type of `loadedFaceCam()` so we can wire
    /// each `@Published` property cleanly at init time.
    struct FaceCamValues {
        let shape: PIPShape
        let size: CGFloat
        let position: CGPoint
        let border: PIPBorder
    }

    static let defaultFaceCam = FaceCamValues(
        shape: .circle,
        size: 0.22,
        position: CGPoint(x: 0.85, y: 0.88),
        border: PIPBorder()
    )

    /// Reads the persisted face cam from UserDefaults, or returns defaults
    /// when nothing's stored or the user has opted out via `rememberFaceCam`.
    /// Tolerant of malformed/old payloads — every decode step has a fallback.
    static func loadedFaceCam() -> FaceCamValues {
        let remember = UserDefaults.standard.object(forKey: Keys.rememberFaceCam) as? Bool ?? true
        guard remember,
              let data = UserDefaults.standard.data(forKey: Keys.faceCam),
              let p = try? JSONDecoder().decode(PersistedFaceCam.self, from: data)
        else { return defaultFaceCam }

        let shape = PIPShape(rawValue: p.shape) ?? defaultFaceCam.shape
        let style = PIPBorder.Style(rawValue: p.borderStyle) ?? .none
        let c1 = cgColor(from: p.borderColor) ?? defaultFaceCam.border.color
        let c2 = cgColor(from: p.borderColor2) ?? defaultFaceCam.border.color2
        return FaceCamValues(
            shape: shape,
            size: CGFloat(p.size),
            position: CGPoint(x: p.positionX, y: p.positionY),
            border: PIPBorder(style: style, color: c1, color2: c2, width: CGFloat(p.borderWidth))
        )
    }

    /// Writes the current face cam back to UserDefaults, but only when
    /// the user has `rememberFaceCam` enabled. No-op otherwise.
    func saveFaceCamIfEnabled() {
        guard rememberFaceCam else { return }
        let data = PersistedFaceCam(
            shape: pipShape.rawValue,
            size: Double(pipSize),
            positionX: Double(pipPosition.x),
            positionY: Double(pipPosition.y),
            borderStyle: pipBorder.style.rawValue,
            borderColor: Self.rgbaComponents(of: pipBorder.color),
            borderColor2: Self.rgbaComponents(of: pipBorder.color2),
            borderWidth: Double(pipBorder.width)
        )
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: Keys.faceCam)
        }
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
