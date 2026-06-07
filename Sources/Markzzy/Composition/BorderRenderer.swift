import CoreVideo
import CoreGraphics
import Foundation

/// Renders the PIP border/ring into a BGRA pixel buffer with CoreGraphics.
///
/// One source of truth for the ring, shared by:
/// - `PIPCompositor` (CIImage preview / fallback path),
/// - `MetalCompositor` (uploaded as a texture so the RECORDING shows the EXACT
///   same ring for ALL styles — solid/gradient/chrome/neon/glow — not just solid),
/// - the floating camera bubble (so what you drag matches what you record).
enum BorderRenderer {

    /// Render the ring for `shape`/`style` at `w`×`h` (the PIP pixel size).
    /// Returns the buffer (sized `w+2·pad × h+2·pad` so glow/neon shadow isn't
    /// clipped at the edge) and the `pad` it added. The ring is drawn offset by
    /// `pad`, premultiplied BGRA.
    static func makeRing(shape: PIPShape, style: PIPBorder.Style,
                         width w: CGFloat, height h: CGFloat,
                         color: CGColor, color2: CGColor,
                         lineWidth lw: CGFloat) -> (buffer: CVPixelBuffer, pad: CGFloat)? {
        guard style != .none, w >= 1, h >= 1, lw > 0 else { return nil }
        let pad: CGFloat
        switch style {
        case .glow: pad = lw * 3
        case .neon: pad = lw * 6
        default:    pad = 0
        }
        let bufW = Int(ceil(w + 2 * pad))
        let bufH = Int(ceil(h + 2 * pad))
        guard let buf = makeBGRABuffer(width: bufW, height: bufH, draw: { ctx in
            ctx.translateBy(x: pad, y: pad)
            ctx.setStrokeColor(color)
            switch style {
            case .none:
                break
            case .solid:
                shape.drawStroke(in: ctx, width: w, height: h, lineWidth: lw)
            case .gradient:
                drawConicGradientStroke(
                    in: ctx, shape: shape, width: w, height: h, lineWidth: lw,
                    colors: PIPBorder.gradientPalette(from: color, to: color2))
            case .chrome:
                drawLinearGradientStroke(
                    in: ctx, shape: shape, width: w, height: h, lineWidth: lw,
                    colors: PIPBorder.chromePalette,
                    locations: [0, 0.25, 0.5, 0.75, 1], vertical: true)
            case .neon:
                // Wider blur + thicker core line than `glow` for a laser-tube feel.
                ctx.setShadow(offset: .zero, blur: lw * 6, color: color)
                shape.drawStroke(in: ctx, width: w, height: h, lineWidth: max(1, lw))
            case .glow:
                ctx.setShadow(offset: .zero, blur: lw * 3, color: color)
                shape.drawStroke(in: ctx, width: w, height: h, lineWidth: max(1, lw * 0.8))
            }
        }) else { return nil }
        return (buf, pad)
    }

    /// Angular-gradient stroke clipped to the shape's stroke ring (180 wedges).
    static func drawConicGradientStroke(in ctx: CGContext, shape: PIPShape,
                                        width w: CGFloat, height h: CGFloat,
                                        lineWidth lw: CGFloat, colors: [CGColor]) {
        let inset = lw / 2
        let outer = CGRect(x: inset, y: inset, width: w - lw, height: h - lw)
        let innerInset = inset + lw
        let inner = CGRect(
            x: innerInset, y: innerInset,
            width: max(0, w - 2 * innerInset),
            height: max(0, h - 2 * innerInset)
        )
        let ring = CGMutablePath()
        ring.addPath(shape.shapePath(in: outer))
        if inner.width > 0, inner.height > 0 {
            ring.addPath(shape.shapePath(in: inner))
        }
        ctx.saveGState()
        ctx.addPath(ring)
        ctx.clip(using: .evenOdd)

        let center = CGPoint(x: w / 2, y: h / 2)
        let radius = hypot(w, h)
        let steps = 180
        for i in 0..<steps {
            let t0 = CGFloat(i)     / CGFloat(steps)
            let t1 = CGFloat(i + 1) / CGFloat(steps)
            let a0 = t0 * 2 * .pi - .pi / 2
            let a1 = t1 * 2 * .pi - .pi / 2
            let color = interpolate(colors, at: t0)
            ctx.setFillColor(color)
            ctx.beginPath()
            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius,
                       startAngle: a0, endAngle: a1, clockwise: false)
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Linear gradient clipped to the shape's stroke ring.
    static func drawLinearGradientStroke(in ctx: CGContext, shape: PIPShape,
                                         width w: CGFloat, height h: CGFloat,
                                         lineWidth lw: CGFloat,
                                         colors: [CGColor],
                                         locations: [CGFloat],
                                         vertical: Bool) {
        let inset = lw / 2
        let outer = CGRect(x: inset, y: inset, width: w - lw, height: h - lw)
        let innerInset = inset + lw
        let inner = CGRect(
            x: innerInset, y: innerInset,
            width: max(0, w - 2 * innerInset),
            height: max(0, h - 2 * innerInset)
        )
        let ring = CGMutablePath()
        ring.addPath(shape.shapePath(in: outer))
        if inner.width > 0, inner.height > 0 {
            ring.addPath(shape.shapePath(in: inner))
        }
        ctx.saveGState()
        ctx.addPath(ring)
        ctx.clip(using: .evenOdd)

        // CGGradient requires every color in the SAME space as `colorsSpace`,
        // else it returns nil (this is what made the gray chrome palette draw
        // nothing). Convert defensively to DeviceRGB.
        let rgb = CGColorSpaceCreateDeviceRGB()
        let rgbColors = colors.map { $0.converted(to: rgb, intent: .defaultIntent, options: nil) ?? $0 }
        guard let gradient = CGGradient(
            colorsSpace: rgb,
            colors: rgbColors as CFArray,
            locations: locations
        ) else {
            ctx.restoreGState()
            return
        }
        let start = CGPoint(x: 0, y: 0)
        let end   = vertical ? CGPoint(x: 0, y: h) : CGPoint(x: w, y: 0)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        ctx.restoreGState()
    }

    static func interpolate(_ colors: [CGColor], at t: CGFloat) -> CGColor {
        guard colors.count > 1 else {
            return colors.first ?? CGColor(gray: 0, alpha: 1)
        }
        let segments = CGFloat(colors.count - 1)
        let scaled = max(0, min(t, 1)) * segments
        let i = min(Int(scaled), colors.count - 2)
        let frac = scaled - CGFloat(i)
        let c1 = colors[i].components ?? [0, 0, 0, 1]
        let c2 = colors[i + 1].components ?? [0, 0, 0, 1]
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * frac }
        let a1 = c1.count > 3 ? c1[3] : 1
        let a2 = c2.count > 3 ? c2[3] : 1
        return CGColor(
            red:   lerp(c1[0], c2[0]),
            green: lerp(c1[1], c2[1]),
            blue:  lerp(c1[2], c2[2]),
            alpha: a1 + (a2 - a1) * frac
        )
    }

    /// Allocate a zeroed premultiplied-BGRA pixel buffer and draw into it.
    static func makeBGRABuffer(width: Int, height: Int,
                               draw: (CGContext) -> Void) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, stride * height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        draw(ctx)
        return buffer
    }
}
