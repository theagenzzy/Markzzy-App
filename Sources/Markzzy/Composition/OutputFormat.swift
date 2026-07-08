import Foundation
import CoreGraphics

/// Target output pixel height for the short side of the encoded video.
/// Scales linearly for all formats: for Reels (9:16) `shortSide` is the width,
/// for Post (1:1) it's both sides, for YouTube it's ignored (native display).
public enum OutputResolution: String, CaseIterable, Identifiable, Codable {
    case hd720, fullHd, qhd, uhd4k

    public var id: String { rawValue }

    public var shortSide: Int {
        switch self {
        case .hd720:  720
        case .fullHd: 1080
        case .qhd:    1440
        case .uhd4k:  2160
        }
    }

    public var label: String {
        switch self {
        case .hd720:  "720p"
        case .fullHd: "1080p"
        case .qhd:    "1440p"
        case .uhd4k:  "4K"
        }
    }

    public var tooltip: String {
        switch self {
        case .hd720:  "HD · lighter file, faster upload"
        case .fullHd: "Full HD · platform standard"
        case .qhd:    "QHD · sharper, bigger file"
        case .uhd4k:  "4K · max quality, heavy file"
        }
    }
}

private func roundEven(_ v: CGFloat) -> CGFloat {
    let n = Int(v.rounded())
    return CGFloat(n - (n % 2))
}

/// Target canvas preset for the recording.
public enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case youtube   // native screen size (current YouTube / desktop flow)
    case reel916   // 1080×1920 vertical — TikTok, Reels, Shorts, FB Reels, Stories
    case square11  // 1080×1080 square — Instagram/Facebook feed

    public var id: String { rawValue }

    /// Human aspect ratio of the output frame — what the Source badge shows
    /// (reads instantly, unlike raw cropped-source pixels). Adapts per format:
    /// YouTube 16:9, Reels 9:16, Post 1:1.
    public var aspectLabel: String {
        switch self {
        case .youtube:  return "16:9"
        case .reel916:  return "9:16"
        case .square11: return "1:1"
        }
    }

    public func canvasSize(for screen: ScreenSource,
                           resolution: OutputResolution = .fullHd) -> CGSize {
        switch self {
        case .youtube:
            // Standard 16:9 canvas at the EXACT dimensions the platform
            // expects (1280×720 / 1920×1080 / 2560×1440 / 3840×2160).
            // Using the display's raw aspect produced odd sizes like
            // 1728×1080 — not a real "1080p", and platforms re-encode
            // it worse. The Metal compositor anchors+fills the screen
            // into this frame (OBS "Fill" behaviour), so non-16:9
            // displays still fill it edge-to-edge and sharp.
            let h = CGFloat(resolution.shortSide)
            let w = h * 16 / 9
            return CGSize(width: roundEven(w), height: roundEven(h))
        case .reel916:
            let w = CGFloat(resolution.shortSide)
            return CGSize(width: w, height: w * 16 / 9)
        case .square11:
            let s = CGFloat(resolution.shortSide)
            return CGSize(width: s, height: s)
        }
    }

    public var supportsResolutionPicker: Bool { true }

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

/// Background source for the camera in split-screen / camera-only layouts (where
/// the camera fills its region, so a transparent cutout makes no sense). The
/// person stays sharp; the background behind them is replaced.
public enum FaceCamBg: String, CaseIterable, Identifiable, Codable {
    case none    // raw camera, no removal
    case blur    // the camera's own background, blurred (Zoom/Meet style)
    case color   // solid color
    case image   // custom image

    public var id: String { rawValue }
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

    /// Axis-aware presentation. The same `left/center/right` value is
    /// reinterpreted as `top/center/bottom` when the crop overflow is
    /// vertical (handled identically by the Metal shader: 0/1/2 maps
    /// to left|top / center / right|bottom depending on rama).
    public func sfSymbol(for axis: AnchorAxis) -> String {
        switch axis {
        case .horizontal: return sfSymbol
        case .vertical:
            switch self {
            case .center: return "rectangle.center.inset.filled"
            case .left:   return "rectangle.tophalf.inset.filled"     // = top
            case .right:  return "rectangle.bottomhalf.inset.filled"  // = bottom
            }
        }
    }

    public func localizedLabel(for axis: AnchorAxis, in lang: AppLanguage) -> String {
        switch axis {
        case .horizontal: return localizedLabel(lang)
        case .vertical:
            switch self {
            case .center: return L10n.t(.anchorCenter, in: lang)
            case .left:   return L10n.t(.anchorTop, in: lang)     // = top
            case .right:  return L10n.t(.anchorBottom, in: lang)  // = bottom
            }
        }
    }
}

/// Axis along which the screen crop overflows (set by the canvas vs
/// source aspect ratio). Drives anchor UI: horizontal overflow → choose
/// left/center/right; vertical overflow → top/center/bottom.
public enum AnchorAxis {
    case horizontal, vertical
}
