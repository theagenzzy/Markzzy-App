import CoreGraphics

/// Shared face-cam defaults so the value isn't re-declared in AppModel and each
/// compositor (where a brand-color tweak would inevitably miss one and the
/// pre-first-push default would differ per render path).
enum FaceCamDefaults {
    /// Default face-cam background color (brand blue), used before the first
    /// `pushBackground()` and as each compositor's initial `bgColor`.
    static let bgColor = CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
}
