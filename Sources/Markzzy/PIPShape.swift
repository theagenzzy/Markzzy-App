import SwiftUI
import CoreGraphics

public enum PIPShape: String, CaseIterable, Identifiable {
    case circle, rectangle, roundedRect, squircle, hexagon, softEdge
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .circle:      "Circle"
        case .rectangle:   "Rectangle"
        case .roundedRect: "Rounded"
        case .squircle:    "Squircle"
        case .hexagon:     "Hexagon"
        case .softEdge:    "Soft"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .circle:      "circle.fill"
        case .rectangle:   "rectangle.fill"
        case .roundedRect: "square.fill"
        case .squircle:    "app.fill"
        case .hexagon:     "hexagon.fill"
        case .softEdge:    "circle.dotted.circle.fill"
        }
    }

    public func anyShape() -> AnyShape {
        switch self {
        case .circle:      AnyShape(Circle())
        case .rectangle:   AnyShape(Rectangle())
        case .roundedRect: AnyShape(RoundedRectangle(cornerRadius: 14))
        case .squircle:    AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        case .hexagon:     AnyShape(HexagonShape())
        case .softEdge:    AnyShape(Circle())
        }
    }

    public var usesSoftMask: Bool { self == .softEdge }

    /// Draws the *fill* of this shape as a white alpha mask into a CGContext of size w×h.
    public func drawAlphaMask(in ctx: CGContext, width: CGFloat, height: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        switch self {
        case .circle:
            ctx.fillEllipse(in: rect)
        case .rectangle:
            ctx.fill(rect)
        case .roundedRect:
            let r = min(width, height) * 0.12
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        case .squircle:
            let r = min(width, height) * 0.24
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        case .hexagon:
            ctx.addPath(Self.hexPath(rect: rect))
            ctx.fillPath()
        case .softEdge:
            let colors = [
                CGColor(gray: 1, alpha: 1),
                CGColor(gray: 1, alpha: 1),
                CGColor(gray: 1, alpha: 0)
            ] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: colors, locations: [0, 0.72, 1.0])!
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = min(rect.width, rect.height) / 2
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: r, options: [])
        }
    }

    /// Strokes the *outline* of this shape into a CGContext of size w×h.
    public func drawStroke(in ctx: CGContext, width w: CGFloat, height h: CGFloat, lineWidth lw: CGFloat) {
        let inset = lw / 2
        let rect = CGRect(x: inset, y: inset, width: w - lw, height: h - lw)
        drawStroke(in: ctx, rect: rect, lineWidth: lw)
    }

    /// Strokes the outline inside a custom rect — used for inset second strokes (e.g. double border).
    public func drawStroke(in ctx: CGContext, rect: CGRect, lineWidth lw: CGFloat) {
        ctx.setLineWidth(lw)
        switch self {
        case .circle:
            ctx.strokeEllipse(in: rect)
        case .rectangle:
            ctx.stroke(rect)
        case .roundedRect:
            let r = min(rect.width, rect.height) * 0.12
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.strokePath()
        case .squircle:
            let r = min(rect.width, rect.height) * 0.24
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.strokePath()
        case .hexagon:
            ctx.addPath(Self.hexPath(rect: rect))
            ctx.strokePath()
        case .softEdge:
            break
        }
    }

    /// Filled outline as a CGPath — used to compute clip regions (e.g. gradient stroke).
    public func shapePath(in rect: CGRect) -> CGPath {
        switch self {
        case .circle, .softEdge:
            return CGPath(ellipseIn: rect, transform: nil)
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRect:
            let r = min(rect.width, rect.height) * 0.12
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .squircle:
            let r = min(rect.width, rect.height) * 0.24
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .hexagon:
            return Self.hexPath(rect: rect)
        }
    }

    static func hexPath(rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let cx = rect.midX; let cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3 - .pi / 2
            let x = cx + r * Foundation.cos(angle)
            let y = cy + r * Foundation.sin(angle)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else      { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }
}

public struct HexagonShape: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(PIPShape.hexPath(rect: rect)) }
}

public struct PIPBorder: Equatable {
    public var style: Style
    public var color: CGColor
    public var color2: CGColor
    public var width: CGFloat

    public init(style: Style = .none,
                color: CGColor = CGColor(red: 0, green: 0.48, blue: 1.0, alpha: 1),
                color2: CGColor = CGColor(red: 0.93, green: 0.29, blue: 0.47, alpha: 1),
                width: CGFloat = 3) {
        self.style = style
        self.color = color
        self.color2 = color2
        self.width = width
    }

    public enum Style: String, CaseIterable, Identifiable {
        case none, solid, gradient, chrome, neon, glow
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .none:     "None"
            case .solid:    "Solid"
            case .gradient: "Gradient"
            case .chrome:   "Chrome"
            case .neon:     "Neon"
            case .glow:     "Glow"
            }
        }

        public var sfSymbol: String {
            switch self {
            case .none:     "nosign"
            case .solid:    "circle"
            case .gradient: "rainbow"
            case .chrome:   "circle.lefthalf.striped.horizontal"
            case .neon:     "bolt.fill"
            case .glow:     "sparkles"
            }
        }

        /// True when the style uses both `color` and `color2`.
        public var usesSecondColor: Bool { self == .gradient }
    }

    /// Smooth 2-color angular palette for `.gradient`. The ring opens on color1,
    /// sweeps through color2 on the opposite side, and returns to color1 — so
    /// the end of the ring connects seamlessly.
    public static func gradientPalette(from c1: CGColor, to c2: CGColor) -> [CGColor] {
        [c1, c2, c1]
    }

    /// Metallic chrome palette for `.chrome` — highlight/mid/shadow/mid/highlight
    /// linear gradient that creates a realistic silver ring.
    // NOTE: RGB (not `CGColor(gray:)`) on purpose — `CGGradient(colorsSpace:
    // DeviceRGB, ...)` returns nil if the colors are in the gray color space,
    // which made the chrome ring silently invisible in the CIImage/Metal paths.
    // Higher-contrast metallic so the ring reads as chrome AND stays visible on
    // BOTH light and dark backgrounds (the old near-white palette vanished over
    // bright content). A bright highlight, light silver, dark steel core, silver,
    // highlight — the dark core anchors it on white backgrounds.
    public static let chromePalette: [CGColor] = [
        CGColor(red: 0.97, green: 0.97, blue: 1.0,  alpha: 1),   // top highlight
        CGColor(red: 0.62, green: 0.64, blue: 0.70, alpha: 1),   // silver
        CGColor(red: 0.24, green: 0.26, blue: 0.32, alpha: 1),   // dark steel core
        CGColor(red: 0.62, green: 0.64, blue: 0.70, alpha: 1),   // silver
        CGColor(red: 0.97, green: 0.97, blue: 1.0,  alpha: 1),   // bottom highlight
    ]

    // Back-compat presets (used in unit tests).
    public static let none   = PIPBorder(style: .none)
    public static let white  = PIPBorder(style: .solid, color: CGColor(gray: 1, alpha: 1))
    public static let black  = PIPBorder(style: .solid, color: CGColor(gray: 0, alpha: 1))
    public static let accent = PIPBorder(style: .solid, color: CGColor(red: 0, green: 0.48, blue: 1, alpha: 1))

    /// Non-nil CGColor only when the border actually draws something.
    public var cgColor: CGColor? { style == .none ? nil : color }
    public var lineWidth: CGFloat { width }

    /// Stroke width PROPORTIONAL to the ring diameter, so the border looks the
    /// same thickness in the small preview, the floating bubble AND the (much
    /// larger) recording canvas. `width` (slider 1…8) is treated as a percent of
    /// the diameter. Without this, an absolute 2px width vanished on the ~480px
    /// recording pip ("the metallic border doesn't appear when recording").
    public func strokeWidth(forDiameter d: CGFloat) -> CGFloat {
        guard style != .none, d > 0 else { return 0 }
        return max(1.5, width * 0.01 * d)
    }

    public var swiftUIColor: Color? {
        style == .none ? nil : Color(cgColor: color)
    }
}
