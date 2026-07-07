import CoreGraphics

extension CGColor {
    /// Always returns 4 sRGB components as a tuple, converting from any source
    /// color space (RGB, grayscale `[white, alpha]`, CMYK, …). Guards against the
    /// index-out-of-range crash from indexing `.components` on a non-RGBA color —
    /// e.g. black/white picked via the color panel's Grayscale slider tab, which
    /// yields a 2-component gray CGColor.
    var srgbRGBA: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let conv = converted(to: space, intent: .defaultIntent, options: nil),
           let c = conv.components, c.count >= 4 {
            return (c[0], c[1], c[2], c[3])
        }
        // Fallback for color spaces that fail conversion.
        if let c = components {
            switch c.count {
            case 2: return (c[0], c[0], c[0], c[1])   // gray + alpha
            case 3: return (c[0], c[1], c[2], 1)
            case 4...: return (c[0], c[1], c[2], c[3])
            default: break
            }
        }
        return (0, 0, 0, 1)
    }
}
