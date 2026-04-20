import CoreImage
import CoreVideo
import CoreGraphics
import Foundation

public final class PIPCompositor {
    private let ciContext: CIContext
    private let lock = NSLock()

    /// Normalized center of the PIP (0…1). (0,0) = top-left of the canvas.
    public var position: CGPoint
    /// Normalized width as fraction of canvas width (typ 0.1…0.4).
    public var size: CGFloat
    public var shape: PIPShape
    public var border: PIPBorder

    public init(position: CGPoint = CGPoint(x: 0.85, y: 0.12),
                size: CGFloat = 0.22,
                shape: PIPShape = .circle,
                border: PIPBorder = .none,
                ciContext: CIContext = CIContext()) {
        self.position = position
        self.size = size
        self.shape = shape
        self.border = border
        self.ciContext = ciContext
    }

    public func update(position: CGPoint, size: CGFloat, shape: PIPShape, border: PIPBorder) {
        lock.lock(); defer { lock.unlock() }
        self.position = position
        self.size = size
        self.shape = shape
        self.border = border
    }

    public func compose(base: CVPixelBuffer, overlay: CVPixelBuffer?) -> CIImage {
        let baseImage = CIImage(cvPixelBuffer: base)
        guard let overlay else { return baseImage }

        lock.lock()
        let pos = position; let sz = size; let sh = shape; let bd = border
        lock.unlock()

        let baseExtent = baseImage.extent
        let cam = CIImage(cvPixelBuffer: overlay)

        let pipW = baseExtent.width * sz
        // Non-rectangular shapes (circle, hexagon, etc.) expect a square PIP,
        // otherwise the alpha mask stretches into an ellipse. Center-crop the
        // camera to a square for those shapes; keep native aspect for rectangle.
        let camSource: CIImage
        let pipH: CGFloat
        if sh == .rectangle {
            let pipAspect = cam.extent.width / cam.extent.height
            pipH = pipW / pipAspect
            camSource = cam
        } else {
            pipH = pipW
            let side = min(cam.extent.width, cam.extent.height)
            let cropX = (cam.extent.width  - side) / 2
            let cropY = (cam.extent.height - side) / 2
            camSource = cam
                .cropped(to: CGRect(x: cropX, y: cropY, width: side, height: side))
                .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
        }

        // Position: user coords = (0,0) top-left. CoreImage = (0,0) bottom-left.
        let centerX = pos.x * baseExtent.width
        let centerY = (1 - pos.y) * baseExtent.height
        var originX = centerX - pipW / 2
        var originY = centerY - pipH / 2

        let pad: CGFloat = bd.cgColor != nil ? bd.lineWidth : 4
        originX = min(max(originX, pad), baseExtent.width  - pipW - pad)
        originY = min(max(originY, pad), baseExtent.height - pipH - pad)

        let scaled = camSource.transformed(by: CGAffineTransform(
            scaleX: pipW / camSource.extent.width,
            y:      pipH / camSource.extent.height
        ))

        let masked = applyShapeMask(to: scaled, shape: sh,
                                    width: pipW, height: pipH)

        let positioned = masked.transformed(by: CGAffineTransform(
            translationX: originX, y: originY
        ))

        var result = positioned.composited(over: baseImage)

        if let borderColor = bd.cgColor {
            if let strokeImage = makeStrokeImage(shape: sh, style: bd.style,
                                                 width: pipW, height: pipH,
                                                 color: borderColor,
                                                 color2: bd.color2,
                                                 lineWidth: bd.lineWidth) {
                let placed = strokeImage.transformed(by: CGAffineTransform(
                    translationX: originX, y: originY
                ))
                result = placed.composited(over: result)
            }
        }

        return result
    }

    public func render(base: CVPixelBuffer, overlay: CVPixelBuffer?, into out: CVPixelBuffer) {
        let composed = compose(base: base, overlay: overlay)
        ciContext.render(composed, to: out)
    }

    /// Render arbitrary layout into `out`. Handles YouTube PIP, vertical/square
    /// split layouts, camera-only, and screen-only — each with its own crop/fit.
    public func render(screen: CVPixelBuffer?,
                       camera: CVPixelBuffer?,
                       into out: CVPixelBuffer,
                       layout: Layout,
                       screenFit: ScreenFit) {
        let outW = CGFloat(CVPixelBufferGetWidth(out))
        let outH = CGFloat(CVPixelBufferGetHeight(out))
        let canvasRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        if layout == .pipOverlay {
            // Preserve current behavior exactly: pass through compose().
            if let screen {
                let composed = compose(base: screen, overlay: camera)
                ciContext.render(composed, to: out)
            } else {
                ciContext.render(CIImage(color: .black).cropped(to: canvasRect), to: out)
            }
            return
        }

        var result = CIImage(color: .black).cropped(to: canvasRect)

        switch layout {
        case .pipOverlay:
            break  // handled above
        case .cameraOnly:
            if let cam = camera {
                result = Self.fit(CIImage(cvPixelBuffer: cam), into: canvasRect, mode: .fill)
                    .composited(over: result)
            }
        case .screenOnly:
            if let s = screen {
                result = Self.fit(CIImage(cvPixelBuffer: s), into: canvasRect, mode: screenFit)
                    .composited(over: result)
            }
        case .splitScreenTop, .splitCamTop:
            let topRect    = CGRect(x: 0, y: outH / 2, width: outW, height: outH / 2)
            let bottomRect = CGRect(x: 0, y: 0,        width: outW, height: outH / 2)
            // NOTE: CoreImage origin is bottom-left, so "topRect" = upper half.

            let screenCI = screen.map { CIImage(cvPixelBuffer: $0) }
            let cameraCI = camera.map { CIImage(cvPixelBuffer: $0) }

            let screenSlot = layout == .splitScreenTop ? topRect : bottomRect
            let cameraSlot = layout == .splitScreenTop ? bottomRect : topRect

            if let s = screenCI {
                result = Self.fit(s, into: screenSlot, mode: screenFit).composited(over: result)
            }
            if let c = cameraCI {
                // Face cam always aspect-fill so faces are never letterboxed.
                result = Self.fit(c, into: cameraSlot, mode: .fill).composited(over: result)
            }
        }

        ciContext.render(result, to: out)
    }

    /// Scale `image` into `dest` according to `mode`, returning a positioned CIImage.
    private static func fit(_ image: CIImage, into dest: CGRect, mode: ScreenFit) -> CIImage {
        let srcW = image.extent.width
        let srcH = image.extent.height
        guard srcW > 0, srcH > 0 else { return image }

        let scaleX = dest.width / srcW
        let scaleY = dest.height / srcH
        let scale: CGFloat
        switch mode {
        case .fit:    scale = min(scaleX, scaleY)
        case .fill:   scale = max(scaleX, scaleY)
        case .center: scale = 1  // keep native pixels; center-crop below
        }

        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledW = scaled.extent.width
        let scaledH = scaled.extent.height
        let dx = dest.midX - (scaled.extent.origin.x + scaledW / 2)
        let dy = dest.midY - (scaled.extent.origin.y + scaledH / 2)
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        return positioned.cropped(to: dest)
    }

    // MARK: - Shape masking

    private func applyShapeMask(to image: CIImage, shape: PIPShape,
                                width: CGFloat, height: CGFloat) -> CIImage {
        if shape == .rectangle {
            return image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let mask = makeAlphaMaskImage(shape: shape, width: width, height: height) else {
            return image
        }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
    }

    private func makeAlphaMaskImage(shape: PIPShape,
                                    width w: CGFloat, height h: CGFloat) -> CIImage? {
        guard let buf = makeBGRABuffer(width: Int(ceil(w)), height: Int(ceil(h)), draw: { ctx in
            shape.drawAlphaMask(in: ctx, width: w, height: h)
        }) else { return nil }
        return CIImage(cvPixelBuffer: buf)
    }

    private func makeStrokeImage(shape: PIPShape, style: PIPBorder.Style,
                                 width w: CGFloat, height h: CGFloat,
                                 color: CGColor, color2: CGColor,
                                 lineWidth lw: CGFloat) -> CIImage? {
        // Styles that emit a shadow/glow need a padded canvas so the blur
        // isn't clipped at the bounding box. The image is offset back by `pad`.
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
                Self.drawConicGradientStroke(
                    in: ctx, shape: shape,
                    width: w, height: h, lineWidth: lw,
                    colors: PIPBorder.gradientPalette(from: color, to: color2)
                )
            case .chrome:
                Self.drawLinearGradientStroke(
                    in: ctx, shape: shape,
                    width: w, height: h, lineWidth: lw,
                    colors: PIPBorder.chromePalette,
                    locations: [0, 0.3, 0.5, 0.7, 1],
                    vertical: true
                )
            case .neon:
                // Wider blur + thicker core line than `glow` for a laser-tube feel.
                ctx.setShadow(offset: .zero, blur: lw * 6, color: color)
                shape.drawStroke(in: ctx, width: w, height: h, lineWidth: max(1, lw))
            case .glow:
                ctx.setShadow(offset: .zero, blur: lw * 3, color: color)
                shape.drawStroke(in: ctx, width: w, height: h, lineWidth: max(1, lw * 0.8))
            }
        }) else { return nil }

        var image = CIImage(cvPixelBuffer: buf)
        if pad > 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -pad, y: -pad))
        }
        return image
    }

    /// Draw an angular-gradient stroke of `shape` clipped to the stroke outline.
    /// Renders 180 pie wedges of interpolated colors within the shape's stroked ring.
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

        // Build a ring-shaped clip path (outer minus inner, even-odd fill).
        let ring = CGMutablePath()
        ring.addPath(shape.shapePath(in: outer))
        if inner.width > 0, inner.height > 0 {
            ring.addPath(shape.shapePath(in: inner))
        }

        ctx.saveGState()
        ctx.addPath(ring)
        ctx.clip(using: .evenOdd)

        let center = CGPoint(x: w / 2, y: h / 2)
        let radius = hypot(w, h)  // guarantees wedges cover the whole ring
        let steps = 180

        for i in 0..<steps {
            let t0 = CGFloat(i)     / CGFloat(steps)
            let t1 = CGFloat(i + 1) / CGFloat(steps)
            // Start at top (12 o'clock) and sweep clockwise.
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

    /// Draw a LINEAR gradient clipped to the shape's stroke ring.
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

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else {
            ctx.restoreGState()
            return
        }

        let start = vertical ? CGPoint(x: 0, y: 0)   : CGPoint(x: 0, y: 0)
        let end   = vertical ? CGPoint(x: 0, y: h)   : CGPoint(x: w, y: 0)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        ctx.restoreGState()
    }

    private static func interpolate(_ colors: [CGColor], at t: CGFloat) -> CGColor {
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

    private func makeBGRABuffer(width: Int, height: Int,
                                draw: (CGContext) -> Void) -> CVPixelBuffer? {
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
