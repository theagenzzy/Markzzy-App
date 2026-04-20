import Foundation

public enum RecordingQuality: String, CaseIterable, Identifiable, Codable {
    case low, medium, high
    public var id: String { rawValue }

    public var bitrate: Int {
        switch self {
        case .low:    4_000_000
        case .medium: 8_000_000
        case .high:   15_000_000
        }
    }

    public func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .low:    L10n.t(.qualityLow, in: lang)
        case .medium: L10n.t(.qualityMedium, in: lang)
        case .high:   L10n.t(.qualityHigh, in: lang)
        }
    }
}

public extension PIPShape {
    func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .circle:      L10n.t(.shapeCircle, in: lang)
        case .rectangle:   L10n.t(.shapeRectangle, in: lang)
        case .roundedRect: L10n.t(.shapeRoundedRect, in: lang)
        case .squircle:    L10n.t(.shapeSquircle, in: lang)
        case .hexagon:     L10n.t(.shapeHexagon, in: lang)
        case .softEdge:    L10n.t(.shapeSoftEdge, in: lang)
        }
    }
}

public extension PIPBorder.Style {
    func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .none:     L10n.t(.borderNone, in: lang)
        case .solid:    L10n.t(.borderSolid, in: lang)
        case .gradient: L10n.t(.borderGradient, in: lang)
        case .chrome:   L10n.t(.borderChrome, in: lang)
        case .neon:     L10n.t(.borderNeon, in: lang)
        case .glow:     L10n.t(.borderGlow, in: lang)
        }
    }
}
