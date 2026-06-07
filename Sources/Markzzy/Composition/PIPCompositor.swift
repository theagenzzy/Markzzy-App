import CoreImage
import CoreVideo
import CoreGraphics
import Foundation
import Metal

public final class PIPCompositor {
    private let ciContext: CIContext
    private let lock = NSLock()

    /// Default CIContext backed by Metal so per-frame composition runs on the
    /// GPU instead of the CPU. `cacheIntermediates` is off because every frame
    /// is unique — caching would just balloon memory.
    public static func makeDefaultContext() -> CIContext {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [
                .cacheIntermediates: false,
                .useSoftwareRenderer: false,
            ])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }

    /// Normalized center of the PIP (0…1). (0,0) = top-left of the canvas.
    public var position: CGPoint
    /// Normalized width as fraction of canvas width (typ 0.1…0.4).
    public var size: CGFloat
    public var shape: PIPShape
    public var border: PIPBorder
    /// Mirror the camera horizontally (selfie flip).
    public var mirror: Bool = false

    // Background removal (parity with MetalCompositor).
    public var removeBackground: Bool = false
    public var bgModeValue: Int = 0      // 0=transparent 1=color 2=blur 3=image
    public var bgFreeform: Bool = false
    public var bgColor: CGColor = CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
    public var bgBlurRadius: CGFloat = 0
    public var bgImage: CVPixelBuffer?
    /// Convenience for the pipOverlay cutout path (transparent vs anything else).
    public var bgTransparent: Bool { bgModeValue == 0 }

    public init(position: CGPoint = CGPoint(x: 0.85, y: 0.12),
                size: CGFloat = 0.22,
                shape: PIPShape = .circle,
                border: PIPBorder = .none,
                ciContext: CIContext? = nil) {
        self.position = position
        self.size = size
        self.shape = shape
        self.border = border
        self.ciContext = ciContext ?? Self.makeDefaultContext()
    }

    public func update(position: CGPoint, size: CGFloat, shape: PIPShape,
                       border: PIPBorder, mirror: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.position = position
        self.size = size
        self.shape = shape
        self.border = border
        self.mirror = mirror
    }

    /// Flip a CIImage horizontally around its own vertical center.
    private func mirroredX(_ img: CIImage) -> CIImage {
        let e = img.extent
        return img.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                     tx: e.minX + e.maxX, ty: 0))
    }

    public func updateBackground(removal: Bool, bgMode: Int, freeform: Bool,
                                 color: CGColor, blurRadius: CGFloat, image: CVPixelBuffer?) {
        lock.lock(); defer { lock.unlock() }
        self.removeBackground = removal
        self.bgModeValue = bgMode
        self.bgFreeform = freeform
        self.bgColor = color
        self.bgBlurRadius = blurRadius
        self.bgImage = image
    }

    /// Apply the person-segmentation matte to a camera CIImage. `mask` is the
    /// low-res matte (person=white); we scale it to the camera extent. In
    /// transparent mode the background becomes clear (alpha); in color mode it's
    /// replaced by `bgColor`. Returns the camera image unchanged if no mask.
    /// `bgMode`: 0=transparent (clear) 1=color 2=blur(camera) 3=image.
    private func applyBackgroundRemoval(to cam: CIImage, mask: CVPixelBuffer?,
                                        bgMode: Int, color: CGColor,
                                        blurRadius: CGFloat, image: CVPixelBuffer?) -> CIImage {
        guard let mask else { return cam }
        var maskImg = CIImage(cvPixelBuffer: mask)
        let mx = cam.extent.width / max(maskImg.extent.width, 1)
        let my = cam.extent.height / max(maskImg.extent.height, 1)
        maskImg = maskImg.transformed(by: CGAffineTransform(scaleX: mx, y: my))
        // The matte is ALREADY edge-refined (joint-bilateral guided by the
        // camera in PersonSegmenter), so its edge hugs the real hair/shoulder
        // contour. Just a gentle anti-alias ramp ≈ smoothstep(0.35, 0.65) so the
        // preview edge matches the Metal recording path: out = clamp((a-0.35)/0.30).
        let mExtent = maskImg.extent
        let lo: CGFloat = 0.42, hi: CGFloat = 0.60
        let s: CGFloat = 1.0 / (hi - lo)
        maskImg = maskImg
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -lo * s, y: -lo * s, z: -lo * s, w: 0),
            ])
            .applyingFilter("CIColorClamp")
            .cropped(to: mExtent)
        // Mirror the matte to match the mirrored camera (they must stay aligned).
        if mirror { maskImg = mirroredX(maskImg).cropped(to: mExtent) }
        let bg: CIImage
        switch bgMode {
        case 2:   // blurred camera (Zoom-style) — clamp edges so blur doesn't darken
            bg = cam.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: cam.extent)
        case 3 where image != nil:   // custom image, aspect-fill the camera extent
            bg = Self.placeAspectFill(CIImage(cvPixelBuffer: image!), into: cam.extent)
        case 1:   // solid color
            bg = CIImage(color: CIColor(cgColor: color)).cropped(to: cam.extent)
        default:  // transparent (clear)
            bg = CIImage.empty().cropped(to: cam.extent)
        }
        // CIBlendWithMask can return an infinite extent — clamp to the camera
        // so downstream createCGImage / placement never gets an infinite rect.
        return cam.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: maskImg,
        ]).cropped(to: cam.extent)
    }

    /// Build a camera-only image with the background removed, for the LIVE
    /// PREVIEW. `freeform` → no shape mask (free silhouette, native aspect);
    /// otherwise the camera is square-cropped and clipped to `shape`.
    /// `transparent` → clear background (composites over the screen); else the
    /// background becomes the solid `color`. Returns a CGImage with alpha, or
    /// nil if no mask is available yet (~20fps on the preview queue).
    /// Result of a preview compose: the image plus its aspect (W/H) so the slot
    /// can be sized to a tight (bbox-cropped) silhouette.
    public struct PreviewImage { public let cgImage: CGImage; public let aspect: CGFloat }

    public func composeCameraOnly(camera: CVPixelBuffer, mask: CVPixelBuffer?,
                                  shape: PIPShape, freeform: Bool, split: Bool,
                                  bgMode: Int, color: CGColor,
                                  blurRadius: CGFloat, image: CVPixelBuffer?) -> PreviewImage? {
        guard mask != nil else { return nil }
        var cam = CIImage(cvPixelBuffer: camera)
        if mirror { cam = mirroredX(cam) }
        // Camera extent is FINITE and known; everything below is anchored to it.
        // CIBlendWithMask can yield an INFINITE extent, and createCGImage with an
        // infinite rect returns nil → the effect silently never appears. Clamp.
        let camExtent = cam.extent

        // Apply the matte on the full-resolution camera first so the mask stays
        // pixel-aligned with the person, then clamp back to the camera extent.
        let removed = applyBackgroundRemoval(to: cam, mask: mask, bgMode: bgMode,
                                             color: color, blurRadius: blurRadius, image: image)
            .cropped(to: camExtent)

        // Rasterize with an EXPLICIT RGBA8 + sRGB format so the matte's alpha
        // survives. The default createCGImage(_:from:) flattens alpha → the
        // transparent cutout came out opaque/black and hid the screen.
        let fmt = CIFormat.RGBA8
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Split / camera-only: the camera fills its slot, so show the FULL frame
        // with its background replaced (no shape, no cutout).
        if freeform || split || shape == .rectangle {
            // Freeform silhouette: FULL camera frame at native aspect. Size is
            // fixed by the user's slider — NOT derived from the person's bbox —
            // so changing pose (hands up/out) never rescales the cutout.
            guard let cg = ciContext.createCGImage(removed, from: camExtent, format: fmt, colorSpace: cs)
            else { return nil }
            let aspect = camExtent.height > 0 ? camExtent.width / camExtent.height : 1
            return PreviewImage(cgImage: cg, aspect: aspect)
        }

        // Center square-crop the already-removed image, then clip to the shape.
        let side = min(camExtent.width, camExtent.height)
        let cropX = camExtent.minX + (camExtent.width  - side) / 2
        let cropY = camExtent.minY + (camExtent.height - side) / 2
        let square = removed
            .cropped(to: CGRect(x: cropX, y: cropY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
        let masked = applyShapeMask(to: square, shape: shape, width: side, height: side)
        guard let cg = ciContext.createCGImage(masked, from: CGRect(x: 0, y: 0, width: side, height: side),
                                               format: fmt, colorSpace: cs) else { return nil }
        return PreviewImage(cgImage: cg, aspect: 1)  // shaped = square
    }

    public func compose(base: CVPixelBuffer, overlay: CVPixelBuffer?,
                        mask: CVPixelBuffer? = nil) -> CIImage {
        let baseImage = CIImage(cvPixelBuffer: base)
        guard let overlay else { return baseImage }

        lock.lock()
        let pos = position; let sz = size; let sh = shape; let bd = border
        let rmBg = removeBackground; let bgM = bgModeValue; let bgCol = bgColor
        let blurR = bgBlurRadius; let bgImg = bgImage; let mir = mirror
        lock.unlock()

        let baseExtent = baseImage.extent
        // Background removal on but the matte isn't ready yet (warm-up at the
        // start of recording) → hide the camera entirely so the raw background
        // never flashes; just return the screen until the first matte arrives.
        if rmBg, mask == nil { return baseImage }
        var cam = CIImage(cvPixelBuffer: overlay)
        if mir { cam = mirroredX(cam) }
        if rmBg, let mask {
            cam = applyBackgroundRemoval(to: cam, mask: mask, bgMode: bgM,
                                         color: bgCol, blurRadius: blurR, image: bgImg)
        }

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

        // Border width is proportional to the pip diameter (see PIPBorder).
        let strokeW = bd.strokeWidth(forDiameter: min(pipW, pipH))
        let pad: CGFloat = bd.cgColor != nil ? strokeW : 4
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
                                                 lineWidth: strokeW) {
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
    /// split layouts, camera-only, and screen-only. The screen is pre-cropped
    /// to the slot's aspect using `anchor` so it fills its area without
    /// letterboxing or stretching.
    public func render(screen: CVPixelBuffer?,
                       camera: CVPixelBuffer?,
                       mask: CVPixelBuffer? = nil,
                       into out: CVPixelBuffer,
                       layout: Layout,
                       screenAnchor: ScreenAnchor) {
        let outW = CGFloat(CVPixelBufferGetWidth(out))
        let outH = CGFloat(CVPixelBufferGetHeight(out))
        let canvasRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        lock.lock()
        let rmBg = removeBackground; let bgM = bgModeValue; let bgCol = bgColor
        let blurR = bgBlurRadius; let bgImg = bgImage; let mir = mirror
        lock.unlock()
        // For full-frame layouts (split) transparent has no backdrop, so fall
        // back to the solid color there.
        func camImage(_ buf: CVPixelBuffer, fullFrame: Bool) -> CIImage {
            var img = CIImage(cvPixelBuffer: buf)
            if mir { img = mirroredX(img) }
            if rmBg {
                let mode = (fullFrame && bgM == 0) ? 1 : bgM
                img = applyBackgroundRemoval(to: img, mask: mask, bgMode: mode,
                                             color: bgCol, blurRadius: blurR, image: bgImg)
            }
            return img
        }

        if layout == .pipOverlay {
            // Preserve current behavior exactly: pass through compose().
            if let screen {
                let composed = compose(base: screen, overlay: camera, mask: mask)
                ciContext.render(composed, to: out)
            } else {
                ciContext.render(CIImage(color: .black).cropped(to: canvasRect), to: out)
            }
            return
        }

        var result = CIImage(color: .black).cropped(to: canvasRect)

        switch layout {
        case .pipOverlay:
            break
        case .cameraOnly:
            if let cam = camera {
                result = Self.placeAspectFill(camImage(cam, fullFrame: true), into: canvasRect)
                    .composited(over: result)
            }
        case .screenOnly:
            if let s = screen {
                let src = CIImage(cvPixelBuffer: s)
                let cropped = Self.cropToAspect(src, targetAspect: canvasRect.width / canvasRect.height,
                                                anchor: screenAnchor)
                result = Self.placeInSlot(cropped, into: canvasRect).composited(over: result)
            }
        case .splitScreenTop, .splitCamTop:
            let topRect    = CGRect(x: 0, y: outH / 2, width: outW, height: outH / 2)
            let bottomRect = CGRect(x: 0, y: 0,        width: outW, height: outH / 2)
            // NOTE: CoreImage origin is bottom-left, so "topRect" = upper half.

            let screenSlot = layout == .splitScreenTop ? topRect : bottomRect
            let cameraSlot = layout == .splitScreenTop ? bottomRect : topRect

            if let s = screen {
                let src = CIImage(cvPixelBuffer: s)
                let cropped = Self.cropToAspect(src,
                                                targetAspect: screenSlot.width / screenSlot.height,
                                                anchor: screenAnchor)
                result = Self.placeInSlot(cropped, into: screenSlot).composited(over: result)
            }
            if let c = camera {
                result = Self.placeAspectFill(camImage(c, fullFrame: false), into: cameraSlot)
                    .composited(over: result)
            }
        }

        ciContext.render(result, to: out)
    }

    /// Compute the source-space crop rect that would make `source` match `targetAspect`.
    /// Useful for overlay previews that need to highlight the excluded region.
    public static func cropRect(sourceWidth srcW: CGFloat, sourceHeight srcH: CGFloat,
                                targetAspect: CGFloat, anchor: ScreenAnchor) -> CGRect {
        guard srcW > 0, srcH > 0 else { return .zero }
        let srcAspect = srcW / srcH
        var cropW = srcW
        var cropH = srcH
        if srcAspect > targetAspect {
            cropW = srcH * targetAspect
        } else {
            cropH = srcW / targetAspect
        }
        let offX: CGFloat
        switch anchor {
        case .left:   offX = 0
        case .center: offX = (srcW - cropW) / 2
        case .right:  offX = srcW - cropW
        }
        let offY = (srcH - cropH) / 2
        return CGRect(x: offX, y: offY, width: cropW, height: cropH)
    }

    /// Crop `image` to the target aspect using the anchor, returning a CIImage
    /// whose extent starts at (0, 0).
    private static func cropToAspect(_ image: CIImage,
                                     targetAspect: CGFloat,
                                     anchor: ScreenAnchor) -> CIImage {
        let crop = cropRect(sourceWidth: image.extent.width,
                            sourceHeight: image.extent.height,
                            targetAspect: targetAspect, anchor: anchor)
        let absCrop = CGRect(x: image.extent.origin.x + crop.origin.x,
                             y: image.extent.origin.y + crop.origin.y,
                             width: crop.width, height: crop.height)
        return image.cropped(to: absCrop)
            .transformed(by: CGAffineTransform(translationX: -absCrop.origin.x,
                                                y: -absCrop.origin.y))
    }

    /// Scale an already-correctly-cropped image so it fills `slot` exactly.
    private static func placeInSlot(_ image: CIImage, into slot: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        let scale = slot.width / image.extent.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = slot.midX - scaled.extent.midX
        let dy = slot.midY - scaled.extent.midY
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: slot)
    }

    /// Scale `image` to fill `dest`, cropping overflow on the longer axis.
    private static func placeAspectFill(_ image: CIImage, into dest: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        let scaleX = dest.width / image.extent.width
        let scaleY = dest.height / image.extent.height
        let scale = max(scaleX, scaleY)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = dest.midX - scaled.extent.midX
        let dy = dest.midY - scaled.extent.midY
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: dest)
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
        // Shared renderer (same ring as the Metal recording path + the bubble).
        guard let (buf, pad) = BorderRenderer.makeRing(
            shape: shape, style: style, width: w, height: h,
            color: color, color2: color2, lineWidth: lw) else { return nil }
        var image = CIImage(cvPixelBuffer: buf)
        if pad > 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -pad, y: -pad))
        }
        return image
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
