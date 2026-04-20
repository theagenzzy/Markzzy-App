import Foundation
import CoreGraphics

/// Target canvas preset for the recording.
public enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case youtube   // native screen size (current YouTube / desktop flow)
    case reel916   // 1080×1920 vertical — TikTok, Reels, Shorts, FB Reels, Stories
    case square11  // 1080×1080 square — Instagram/Facebook feed

    public var id: String { rawValue }

    public func canvasSize(for screen: ScreenSource) -> CGSize {
        switch self {
        case .youtube:  return CGSize(width: screen.width, height: screen.height)
        case .reel916:  return CGSize(width: 1080, height: 1920)
        case .square11: return CGSize(width: 1080, height: 1080)
        }
    }

    public var allowsFloatingPIP: Bool { self == .youtube }

    public var sfSymbol: String {
        switch self {
        case .youtube:  "rectangle"
        case .reel916:  "rectangle.portrait"
        case .square11: "square"
        }
    }

    public func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .youtube:  L10n.t(.formatYouTube, in: lang)
        case .reel916:  L10n.t(.formatReel, in: lang)
        case .square11: L10n.t(.formatSquare, in: lang)
        }
    }
}

/// How screen + camera are arranged on the canvas.
public enum Layout: String, CaseIterable, Identifiable, Codable {
    case pipOverlay      // screen full + floating PIP (YouTube style)
    case splitScreenTop  // screen top half, camera bottom half
    case splitCamTop     // camera top half, screen bottom half
    case cameraOnly
    case screenOnly

    public var id: String { rawValue }

    public var usesScreen: Bool {
        self == .pipOverlay || self == .splitScreenTop || self == .splitCamTop || self == .screenOnly
    }

    public var usesCamera: Bool {
        self == .pipOverlay || self == .splitScreenTop || self == .splitCamTop || self == .cameraOnly
    }

    public var sfSymbol: String {
        switch self {
        case .pipOverlay:     "rectangle.inset.topleading.filled"
        case .splitScreenTop: "rectangle.split.1x2"
        case .splitCamTop:    "rectangle.split.1x2.fill"
        case .cameraOnly:     "person.crop.rectangle"
        case .screenOnly:     "display"
        }
    }

    public func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .pipOverlay:     L10n.t(.layoutPipOverlay, in: lang)
        case .splitScreenTop: L10n.t(.layoutSplitScreenTop, in: lang)
        case .splitCamTop:    L10n.t(.layoutSplitCamTop, in: lang)
        case .cameraOnly:     L10n.t(.layoutCameraOnly, in: lang)
        case .screenOnly:     L10n.t(.layoutScreenOnly, in: lang)
        }
    }
}

/// Where on the captured display the crop is anchored when the source aspect
/// differs from the destination slot aspect. Source is cropped to match the
/// slot so it always fills cleanly without letterboxing or stretching.
public enum ScreenAnchor: String, CaseIterable, Identifiable, Codable {
    case center, left, right

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .center: "rectangle.center.inset.filled"
        case .left:   "rectangle.leftthird.inset.filled"
        case .right:  "rectangle.rightthird.inset.filled"
        }
    }

    public func localizedLabel(_ lang: AppLanguage) -> String {
        switch self {
        case .center: L10n.t(.anchorCenter, in: lang)
        case .left:   L10n.t(.anchorLeft, in: lang)
        case .right:  L10n.t(.anchorRight, in: lang)
        }
    }
}
