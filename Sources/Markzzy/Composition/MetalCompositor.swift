import Metal
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import CoreImage
import Foundation

/// Metal compute shader compositor. Renders the entire output canvas
/// in ONE GPU pass (vs CIImage chain's N composites + final render).
///
/// Same `render(screen:camera:into:layout:screenAnchor:)` API as
/// `PIPCompositor` — drop-in replacement gated behind a feature flag.
///
/// This is what OBS / professional screen recorders do for compose.
/// Per-frame GPU time drops from ~15-30ms (CIImage) to ~3-5ms (Metal).
public final class MetalCompositor {

    // Compose settings — match `PIPCompositor` for parity.
    public var position: CGPoint
    public var size: CGFloat
    public var shape: PIPShape
    public var border: PIPBorder
    /// Mirror the camera horizontally (selfie flip).
    public var mirror: Bool = false

    // Cached border ring texture (rendered by BorderRenderer → uploaded once,
    // reused per-frame). Regenerated only when style/color/size/shape change so
    // there's zero per-frame cost. Keeps the recorded ring identical to the
    // CIImage preview + the floating bubble, for ALL styles (not just solid).
    private var borderTex: MTLTexture?
    private var borderTexBuffer: CVPixelBuffer?   // retains the backing buffer
    private var borderPad: CGFloat = 0
    private var borderKey: String = ""

    // Background removal (person segmentation). `bgTransparent` true = cut the
    // person out over the screen; false = replace the camera background with
    // `bgColor` inside the shape.
    public var removeBackground: Bool = false
    public var bgModeValue: Int = 0       // 0=transparent 1=color 2=blur 3=image
    public var bgFreeform: Bool = false   // skip the shape clip (free silhouette)
    public var bgColor: CGColor = CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
    public var bgBlurRadius: CGFloat = 0
    public var bgImage: CVPixelBuffer?
    private var blurDest: MTLTexture?     // reused MPS blur destination (camera bg)
    private var screenBlurDest: MTLTexture?   // reused MPS blur destination (screen Fit bg)

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()

    /// Falls back to nil if Metal is unavailable on the host. Callers
    /// should use `PIPCompositor` (CIImage path) in that case.
    public init?(position: CGPoint = CGPoint(x: 0.85, y: 0.12),
                 size: CGFloat = 0.22,
                 shape: PIPShape = .circle,
                 border: PIPBorder = .none) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            PerfLog.log("METAL-INIT-FAIL: MTLCreateSystemDefaultDevice() returned nil")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            PerfLog.log("METAL-INIT-FAIL: makeCommandQueue() returned nil (device=\(device.name))")
            return nil
        }
        self.device = device
        self.commandQueue = queue

        // Compile shader source at runtime — keeps the SPM target free
        // of .metal build steps. Costs ~100ms once at init.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            print("MetalCompositor: shader compile failed: \(error)"); PerfLog.log("METAL-INIT-FAIL: shader compile: \(error)")
            return nil
        }
        guard let kernel = library.makeFunction(name: "compose_kernel") else {
            print("MetalCompositor: compose_kernel not found"); PerfLog.log("METAL-INIT-FAIL: compose_kernel not found")
            return nil
        }
        do {
            self.pipelineState = try device.makeComputePipelineState(function: kernel)
        } catch {
            print("MetalCompositor: pipeline state failed: \(error)"); PerfLog.log("METAL-INIT-FAIL: pipeline state: \(error)")
            return nil
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache

        self.position = position
        self.size = size
        self.shape = shape
        self.border = border
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

    public func render(screen: CVPixelBuffer?,
                       camera: CVPixelBuffer?,
                       mask: CVPixelBuffer? = nil,
                       into out: CVPixelBuffer,
                       layout: Layout,
                       screenAnchor: ScreenAnchor,
                       screenFit: Bool = false) {
        guard let textureCache else { return }

        let outW = CVPixelBufferGetWidth(out)
        let outH = CVPixelBufferGetHeight(out)
        guard let outTex = makeTexture(from: out, cache: textureCache,
                                       format: .bgra8Unorm, usage: [.shaderRead, .shaderWrite])
        else { return }

        let screenTex = screen.flatMap {
            makeTexture(from: $0, cache: textureCache, format: .bgra8Unorm, usage: [.shaderRead])
        }
        let cameraTex = camera.flatMap {
            makeTexture(from: $0, cache: textureCache, format: .bgra8Unorm, usage: [.shaderRead])
        }
        // Segmentation matte — single-channel. Only built when removal is on
        // and a mask exists.
        let maskTex = mask.flatMap {
            makeTexture(from: $0, cache: textureCache, format: .r8Unorm, usage: [.shaderRead])
        }

        lock.lock()
        let pos = position; let sz = size; let sh = shape; let bd = border
        let rmBg = removeBackground; let bgM = bgModeValue; let bgCol = bgColor
        let bgFree = bgFreeform; let blurR = bgBlurRadius; let img = bgImage
        let mir = mirror
        lock.unlock()
        let bgComps = bgCol.components ?? [0, 0, 0, 1]

        // Border ring texture (pipOverlay only; the shader draws it just there).
        // Skip for the transparent cutout (a ring around a cut-out looks wrong).
        var hasBorderTex: UInt32 = 0
        var borderTexW: UInt32 = 0, borderTexH: UInt32 = 0
        var borderPadPx: Float = 0
        var borderTexture: MTLTexture?
        let transparentCutout = (rmBg && maskTex != nil && bgM == 0)
        if layout == .pipOverlay, bd.style != .none, bd.width > 0, !transparentCutout {
            let pipWpx = max(1, Int((CGFloat(outW) * sz).rounded()))
            let pipHpx: Int
            if sh != .rectangle {
                pipHpx = pipWpx
            } else if let cw = cameraTex?.width, let ch = cameraTex?.height, cw > 0 {
                pipHpx = max(1, Int((CGFloat(pipWpx) * CGFloat(ch) / CGFloat(cw)).rounded()))
            } else {
                pipHpx = pipWpx
            }
            func comps(_ c: CGColor) -> String {
                (c.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
            }
            let lw = bd.strokeWidth(forDiameter: CGFloat(min(pipWpx, pipHpx)))
            let key = "\(sh.rawValue)|\(bd.style.rawValue)|\(comps(bd.color))|\(comps(bd.color2))|\(lw)|\(pipWpx)x\(pipHpx)"
            if key != borderKey || borderTex == nil {
                if let (buf, pad) = BorderRenderer.makeRing(
                    shape: sh, style: bd.style, width: CGFloat(pipWpx), height: CGFloat(pipHpx),
                    color: bd.color, color2: bd.color2, lineWidth: lw),
                   let tex = makeTexture(from: buf, cache: textureCache,
                                         format: .bgra8Unorm, usage: [.shaderRead]) {
                    borderTexBuffer = buf
                    borderTex = tex
                    borderPad = pad
                    borderKey = key
                } else {
                    borderTex = nil; borderTexBuffer = nil; borderKey = ""
                }
            }
            if let bt = borderTex {
                borderTexture = bt
                hasBorderTex = 1
                borderTexW = UInt32(bt.width)
                borderTexH = UInt32(bt.height)
                borderPadPx = Float(borderPad)
            }
        }

        // Background source textures for split/camera-only: blurred camera (MPS)
        // for blur mode, the user image for image mode. Always have SOMETHING
        // bound at idx 4/5 (the shader only samples them per bgMode).
        let imageTex = (bgM == 3) ? img.flatMap {
            makeTexture(from: $0, cache: textureCache, format: .bgra8Unorm, usage: [.shaderRead])
        } : nil

        var uniforms = ComposeUniforms(
            outWidth: UInt32(outW),
            outHeight: UInt32(outH),
            layout: layoutCode(layout),
            screenAnchor: anchorCode(screenAnchor),
            hasScreen: screenTex != nil ? 1 : 0,
            hasCamera: cameraTex != nil ? 1 : 0,
            screenWidth: UInt32(screenTex?.width ?? 0),
            screenHeight: UInt32(screenTex?.height ?? 0),
            cameraWidth: UInt32(cameraTex?.width ?? 0),
            cameraHeight: UInt32(cameraTex?.height ?? 0),
            pipPosX: Float(pos.x),
            pipPosY: Float(pos.y),
            pipSize: Float(sz),
            pipShape: shapeCode(sh),
            borderStyle: borderCode(bd.style),
            borderWidth: Float(bd.width),
            borderR: Float(bd.color.components?[0] ?? 0),
            borderG: Float(bd.color.components?[1] ?? 0),
            borderB: Float(bd.color.components?[2] ?? 0),
            borderA: Float(bd.color.components?[3] ?? 1),
            border2R: Float(bd.color2.components?[0] ?? 0),
            border2G: Float(bd.color2.components?[1] ?? 0),
            border2B: Float(bd.color2.components?[2] ?? 0),
            removeBg: (rmBg && maskTex != nil) ? 1 : 0,
            bgMode: UInt32(max(0, min(3, bgM))),
            hasMask: maskTex != nil ? 1 : 0,
            freeform: bgFree ? 1 : 0,
            bgR: Float(bgComps.count > 0 ? bgComps[0] : 0),
            bgG: Float(bgComps.count > 1 ? bgComps[1] : 0),
            bgB: Float(bgComps.count > 2 ? bgComps[2] : 0),
            imgWidth: UInt32(imageTex?.width ?? 0),
            imgHeight: UInt32(imageTex?.height ?? 0),
            mirror: mir ? 1 : 0,
            hasBorderTex: hasBorderTex,
            borderTexW: borderTexW,
            borderTexH: borderTexH,
            borderPad: borderPadPx,
            screenFit: (screenFit && layout.usesScreen) ? 1 : 0
        )

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Blur mode: pre-blur the camera into a reused destination texture with
        // MPS, then the kernel samples it as the background behind the person.
        var blurTex: MTLTexture?
        if bgM == 2, let cam = cameraTex, blurR > 0.5 {
            if blurDest?.width != cam.width || blurDest?.height != cam.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: cam.width, height: cam.height, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                blurDest = device.makeTexture(descriptor: d)
            }
            if let dest = blurDest {
                MPSImageGaussianBlur(device: device, sigma: Float(blurR))
                    .encode(commandBuffer: cmdBuf, sourceTexture: cam, destinationTexture: dest)
                blurTex = dest
            }
        }

        // Fit mode: pre-blur the SCREEN into a reused texture; the kernel uses it
        // as the background behind the aspect-fit (whole) desktop. Only when the
        // layout actually shows the screen.
        var screenBlurTex: MTLTexture?
        if screenFit, layout.usesScreen, let s = screenTex {
            if screenBlurDest?.width != s.width || screenBlurDest?.height != s.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: s.width, height: s.height, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                screenBlurDest = device.makeTexture(descriptor: d)
            }
            if let dest = screenBlurDest {
                MPSImageGaussianBlur(device: device, sigma: max(20, Float(s.width) / 40))
                    .encode(commandBuffer: cmdBuf, sourceTexture: s, destinationTexture: dest)
                screenBlurTex = dest
            }
        }

        guard let encoder = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipelineState)
        if let s = screenTex { encoder.setTexture(s, index: 0) }
        if let c = cameraTex { encoder.setTexture(c, index: 1) }
        encoder.setTexture(outTex, index: 2)
        if let m = maskTex { encoder.setTexture(m, index: 3) }
        // idx 4 = blurred camera, idx 5 = bg image. Bind a valid placeholder
        // (cameraTex) when unused so the kernel never samples an unbound texture.
        encoder.setTexture(blurTex ?? cameraTex ?? outTex, index: 4)
        encoder.setTexture(imageTex ?? cameraTex ?? outTex, index: 5)
        encoder.setTexture(borderTexture ?? cameraTex ?? outTex, index: 6)
        encoder.setTexture(screenBlurTex ?? screenTex ?? outTex, index: 7)   // screen Fit bg
        encoder.setBytes(&uniforms, length: MemoryLayout<ComposeUniforms>.size, index: 0)

        let w = pipelineState.threadExecutionWidth
        let h = pipelineState.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadgroups = MTLSize(
            width: (outW + w - 1) / w,
            height: (outH + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    // MARK: - Helpers

    private func makeTexture(from buf: CVPixelBuffer,
                             cache: CVMetalTextureCache,
                             format: MTLPixelFormat,
                             usage: MTLTextureUsage) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        var texRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buf, nil, format, w, h, 0, &texRef
        )
        guard status == kCVReturnSuccess, let texRef else { return nil }
        let tex = CVMetalTextureGetTexture(texRef)
        // Note: CVMetalTexture default usage doesn't always include
        // .shaderWrite even when requested. Output texture works
        // because BGRA8Unorm + IOSurface usually grants both.
        return tex
    }

    private func layoutCode(_ l: Layout) -> UInt32 {
        switch l {
        case .pipOverlay: return 0
        case .splitScreenTop: return 1
        case .splitCamTop: return 2
        case .cameraOnly: return 3
        case .screenOnly: return 4
        }
    }

    private func anchorCode(_ a: ScreenAnchor) -> UInt32 {
        switch a {
        case .left: return 0
        case .center: return 1
        case .right: return 2
        }
    }

    private func shapeCode(_ s: PIPShape) -> UInt32 {
        switch s {
        case .rectangle: return 0
        case .roundedRect: return 1
        case .squircle: return 2
        case .circle: return 3
        case .hexagon: return 4
        case .softEdge: return 5
        }
    }

    private func borderCode(_ s: PIPBorder.Style) -> UInt32 {
        switch s {
        case .none: return 0
        case .solid: return 1
        case .gradient: return 2
        case .chrome: return 3
        case .neon: return 4
        case .glow: return 5
        }
    }

    // MARK: - Shader source

    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        uint outWidth;
        uint outHeight;
        uint layout;          // 0=pip 1=splitScrTop 2=splitCamTop 3=camOnly 4=scrOnly
        uint screenAnchor;    // 0=left 1=center 2=right
        uint hasScreen;
        uint hasCamera;
        uint screenWidth;
        uint screenHeight;
        uint cameraWidth;
        uint cameraHeight;
        float pipPosX;        // 0..1 normalized
        float pipPosY;
        float pipSize;        // fraction of canvas width
        uint pipShape;        // 0=rect 1=rounded 2=squircle 3=circle 4=hex 5=soft
        uint borderStyle;     // 0=none 1=solid 2=gradient ...
        float borderWidth;
        float borderR; float borderG; float borderB; float borderA;
        float border2R; float border2G; float border2B;
        uint removeBg;        // 1 = background removal active
        uint bgMode;          // 0=transparent 1=color 2=blur 3=image
        uint hasMask;         // 1 = segmentation mask bound at texture(3)
        uint freeform;        // 1 = skip shape clip (free silhouette)
        float bgR; float bgG; float bgB;
        uint imgWidth; uint imgHeight;   // bg image dims (aspect-fill); 0 if none
        uint mirror;          // 1 = flip camera horizontally (selfie)
        uint hasBorderTex;    // 1 = sample borderTex at texture(6)
        uint borderTexW; uint borderTexH;  // border texture px (incl. pad)
        float borderPad;      // px of padding baked into the border texture
        uint screenFit;       // 1 = aspect-fit whole screen over a blurred bg
    };

    // Sample with aspect-fill semantics — image fills the rect, cropping overflow.
    static float4 sampleAspectFill(texture2d<float, access::sample> tex,
                                    float2 uvInRect, float texW, float texH,
                                    float rectW, float rectH) {
        if (texW <= 0 || texH <= 0) return float4(0, 0, 0, 1);
        float scaleX = rectW / texW;
        float scaleY = rectH / texH;
        float scale = max(scaleX, scaleY);
        float scaledW = texW * scale;
        float scaledH = texH * scale;
        // Center crop in source space.
        float srcX = (uvInRect.x * rectW + (scaledW - rectW) * 0.5) / scale;
        float srcY = (uvInRect.y * rectH + (scaledH - rectH) * 0.5) / scale;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return tex.sample(s, float2(srcX / texW, srcY / texH));
    }

    // Anchor-aware crop+sample for the screen.
    static float4 sampleScreenAnchored(texture2d<float, access::sample> tex,
                                        float2 uvInRect, float texW, float texH,
                                        float rectW, float rectH, uint anchor) {
        if (texW <= 0 || texH <= 0) return float4(0, 0, 0, 1);
        // Crop source to rect's aspect, anchored.
        float srcAspect = texW / texH;
        float dstAspect = rectW / rectH;
        float cropW, cropH, offX, offY;
        if (srcAspect > dstAspect) {
            // Source wider than dest — crop horizontally.
            cropH = texH;
            cropW = texH * dstAspect;
            offY = 0;
            if (anchor == 0)      offX = 0;
            else if (anchor == 2) offX = texW - cropW;
            else                  offX = (texW - cropW) * 0.5;
        } else {
            // Source taller than dest — crop vertically. Anchor uses
            // the same 0/1/2 encoding: 0 = top, 1 = center, 2 = bottom.
            cropW = texW;
            cropH = texW / dstAspect;
            offX = 0;
            if (anchor == 0)      offY = 0;
            else if (anchor == 2) offY = texH - cropH;
            else                  offY = (texH - cropH) * 0.5;
        }
        float srcX = offX + uvInRect.x * cropW;
        float srcY = offY + uvInRect.y * cropH;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return tex.sample(s, float2(srcX / texW, srcY / texH));
    }

    // SDF for the supported PIP shapes. Returns negative inside, positive outside.
    static float shapeSDF(float2 p, float2 center, float2 halfSize, uint shape) {
        float2 q = abs(p - center);
        if (shape == 3 /*circle*/ || shape == 5 /*softEdge*/) {
            float r = min(halfSize.x, halfSize.y);
            return length(p - center) - r;
        }
        if (shape == 0 /*rect*/) {
            float2 d = q - halfSize;
            return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
        }
        if (shape == 1 /*roundedRect*/) {
            float r = min(halfSize.x, halfSize.y) * 0.24;
            float2 d = q - (halfSize - r);
            return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
        }
        if (shape == 2 /*squircle*/) {
            float r = min(halfSize.x, halfSize.y) * 0.48;
            float2 d = q - (halfSize - r);
            return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
        }
        if (shape == 4 /*hexagon*/) {
            const float k = 0.866025404;  // sqrt(3)/2
            q -= float2(0, 0);
            q.x = abs(q.x);
            q.y = abs(q.y);
            // Approximate hex SDF.
            float d = max(dot(q, float2(k, 0.5)), q.y) - min(halfSize.x, halfSize.y) * k;
            return d;
        }
        return length(p - center) - min(halfSize.x, halfSize.y);
    }

    // Sample the person-segmentation matte for a camera UV (0..1 within the
    // camera frame). The matte is lower-res than the frame; the linear sampler
    // upscales it. smoothstep tightens + feathers the edge so hair doesn't look
    // stair-stepped. Returns 1 = person, 0 = background.
    static float personAlpha(texture2d<float, access::sample> maskTex,
                              float2 camUV, uint hasMask) {
        // No matte yet (segmentation still warming up at the very start of a
        // recording) → treat as fully BACKGROUND so the raw camera (with its
        // real background) never flashes. Only ever called when removeBg is on.
        if (hasMask == 0) return 0.0;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // The matte arrives ALREADY edge-refined (joint-bilateral guided by the
        // camera in PersonSegmenter), so its edge hugs the real hair/shoulder
        // contour. No aggressive erode here (that would eat the refined hair
        // detail) — just a gentle anti-alias ramp for a soft, natural Zoom-like
        // edge. The temporal EMA upstream keeps it stable frame-to-frame.
        float a = maskTex.sample(s, camUV).r;
        // Edge already refined upstream; a slightly tighter ramp drops the thin
        // contaminated (halo) rim without eating the refined hair detail.
        return smoothstep(0.42, 0.60, a);
    }

    // Convert an aspect-fill PIP UV back into the camera's own UV space so the
    // segmentation matte (which is in camera space) lines up with the cropped,
    // scaled camera pixels drawn in the PIP.
    static float2 aspectFillCamUV(float2 uvInRect, float texW, float texH,
                                  float rectW, float rectH) {
        if (texW <= 0 || texH <= 0) return uvInRect;
        float scale = max(rectW / texW, rectH / texH);
        float scaledW = texW * scale;
        float scaledH = texH * scale;
        float srcX = (uvInRect.x * rectW + (scaledW - rectW) * 0.5) / scale;
        float srcY = (uvInRect.y * rectH + (scaledH - rectH) * 0.5) / scale;
        return float2(srcX / texW, srcY / texH);
    }

    // Aspect-FIT mapping (the whole camera frame fits inside the slot — nothing
    // is cropped, so the head can never be cut). `outside` is set when the slot
    // point falls in the transparent letterbox margin (no camera content).
    static float2 aspectFitCamUV(float2 uvInRect, float texW, float texH,
                                 float rectW, float rectH, thread bool &outside) {
        outside = false;
        if (texW <= 0 || texH <= 0) { outside = true; return float2(0); }
        float scale = min(rectW / texW, rectH / texH);  // FIT = min
        float scaledW = texW * scale;
        float scaledH = texH * scale;
        float offX = (rectW - scaledW) * 0.5;
        float offY = (rectH - scaledH) * 0.5;
        float px = uvInRect.x * rectW - offX;
        float py = uvInRect.y * rectH - offY;
        if (px < 0.0 || py < 0.0 || px > scaledW || py > scaledH) outside = true;
        return float2(px / max(scaledW, 1.0), py / max(scaledH, 1.0));
    }

    // Background color/source for split & camera-only (person stays sharp, this
    // fills behind them). bgMode: 1=solid, 2=blurred camera, 3=image.
    static float3 bgSource(uint bgMode,
                           texture2d<float, access::sample> blurTex,
                           texture2d<float, access::sample> imageTex,
                           float2 camUV, float2 slotUV,
                           float rectW, float rectH,
                           float imgW, float imgH,
                           float3 solid) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        if (bgMode == 2) {            // blurred camera (aligned with the person)
            return blurTex.sample(s, camUV).rgb;
        }
        if (bgMode == 3 && imgW > 0.0 && imgH > 0.0) {   // image, aspect-fill
            return sampleAspectFill(imageTex, slotUV, imgW, imgH, rectW, rectH).rgb;
        }
        return solid;                 // solid color
    }

    // Screen for a slot: Fit (whole desktop aspect-fit over a blurred-screen
    // background) when `fit`, else the current anchored aspect-fill crop.
    static float4 screenSlotColor(texture2d<float, access::sample> screenTex,
                                  texture2d<float, access::sample> screenBlurTex,
                                  float2 uv, float texW, float texH,
                                  float rectW, float rectH, uint anchor, uint fit) {
        if (fit == 0) {
            return sampleScreenAnchored(screenTex, uv, texW, texH, rectW, rectH, anchor);
        }
        // Fit: blurred screen fills the slot; the whole screen sits on top.
        float3 bg = sampleAspectFill(screenBlurTex, uv, texW, texH, rectW, rectH).rgb;
        bool outside = false;
        float2 fitUV = aspectFitCamUV(uv, texW, texH, rectW, rectH, outside);
        if (outside) return float4(bg, 1.0);
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(screenTex.sample(s, fitUV).rgb, 1.0);
    }

    kernel void compose_kernel(
        texture2d<float, access::sample> screenTex [[texture(0)]],
        texture2d<float, access::sample> cameraTex [[texture(1)]],
        texture2d<float, access::write>  outTex    [[texture(2)]],
        texture2d<float, access::sample> maskTex   [[texture(3)]],
        texture2d<float, access::sample> blurTex   [[texture(4)]],
        texture2d<float, access::sample> imageTex  [[texture(5)]],
        texture2d<float, access::sample> borderTex [[texture(6)]],
        texture2d<float, access::sample> screenBlurTex [[texture(7)]],
        constant Uniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.outWidth || gid.y >= u.outHeight) return;

        float fx = float(gid.x);
        float fy = float(gid.y);
        float fw = float(u.outWidth);
        float fh = float(u.outHeight);

        float4 color = float4(0, 0, 0, 1);

        // --- Layout-specific composition ---
        if (u.layout == 4 /*screenOnly*/) {
            if (u.hasScreen != 0) {
                float2 uv = float2(fx / fw, fy / fh);
                color = screenSlotColor(screenTex, screenBlurTex, uv,
                                        float(u.screenWidth), float(u.screenHeight),
                                        fw, fh, u.screenAnchor, u.screenFit);
            }
        } else if (u.layout == 3 /*cameraOnly*/) {
            if (u.hasCamera != 0) {
                float2 uv = float2(fx / fw, fy / fh);
                float2 cuv = uv; if (u.mirror != 0) cuv.x = 1.0 - cuv.x;
                color = sampleAspectFill(cameraTex, cuv,
                                          float(u.cameraWidth), float(u.cameraHeight),
                                          fw, fh);
                // Background removal: replace the camera background with the
                // chosen color (transparent has no meaning full-frame, so it
                // also falls back to the solid color here).
                if (u.removeBg != 0) {
                    float2 camUV = aspectFillCamUV(cuv,
                        float(u.cameraWidth), float(u.cameraHeight), fw, fh);
                    float pa = personAlpha(maskTex, camUV, u.hasMask);
                    float3 bg = bgSource(u.bgMode, blurTex, imageTex, camUV, uv,
                                         fw, fh, float(u.imgWidth), float(u.imgHeight),
                                         float3(u.bgR, u.bgG, u.bgB));
                    color = float4(mix(bg, color.rgb, pa), 1.0);
                }
            }
        } else if (u.layout == 1 /*splitScreenTop*/ || u.layout == 2 /*splitCamTop*/) {
            float halfH = fh * 0.5;
            bool inTop = fy < halfH;  // metal is top-left origin, top = small y
            bool screenSlot = (u.layout == 1) ? inTop : !inTop;
            float yInSlot = inTop ? fy : (fy - halfH);
            float2 uv = float2(fx / fw, yInSlot / halfH);
            if (screenSlot && u.hasScreen != 0) {
                color = screenSlotColor(screenTex, screenBlurTex, uv,
                                        float(u.screenWidth), float(u.screenHeight),
                                        fw, halfH, u.screenAnchor, u.screenFit);
            } else if (!screenSlot && u.hasCamera != 0) {
                float2 cuv = uv; if (u.mirror != 0) cuv.x = 1.0 - cuv.x;
                color = sampleAspectFill(cameraTex, cuv,
                                          float(u.cameraWidth), float(u.cameraHeight),
                                          fw, halfH);
                if (u.removeBg != 0) {
                    float2 camUV = aspectFillCamUV(cuv,
                        float(u.cameraWidth), float(u.cameraHeight), fw, halfH);
                    float pa = personAlpha(maskTex, camUV, u.hasMask);
                    float3 bg = bgSource(u.bgMode, blurTex, imageTex, camUV, uv,
                                         fw, halfH, float(u.imgWidth), float(u.imgHeight),
                                         float3(u.bgR, u.bgG, u.bgB));
                    color = float4(mix(bg, color.rgb, pa), 1.0);
                }
            }
        } else /*pipOverlay*/ {
            // Background = screen (anchor handled implicitly: pipOverlay
            // uses the full screen, no crop).
            if (u.hasScreen != 0) {
                float2 uv = float2(fx / fw, fy / fh);
                color = screenSlotColor(screenTex, screenBlurTex, uv,
                                        float(u.screenWidth), float(u.screenHeight),
                                        fw, fh, u.screenAnchor, u.screenFit);
            }
            // PIP overlay.
            if (u.hasCamera != 0) {
                float pipW = fw * u.pipSize;
                // Slot height: freeform uses native camera aspect (constant —
                // size is slider-controlled, never derived from the person's
                // pose); shaped PIP stays square.
                float pipH;
                if (u.pipShape != 0 && u.freeform == 0) {
                    pipH = pipW;  // square
                } else {
                    pipH = pipW * float(u.cameraHeight) / float(u.cameraWidth);
                }
                float2 pipCenter = float2(u.pipPosX * fw, u.pipPosY * fh);
                float2 pipHalf = float2(pipW * 0.5, pipH * 0.5);
                // Mirror the preview's pipRect clamp EXACTLY so recording ==
                // preview. Freeform: head-safe top (centre ≥ pipHalf.y, head
                // never cut), bottom + sides may overflow (edges/corners,
                // standing-person look); the canvas clips it. Shaped PIP stays
                // fully on-canvas.
                if (u.freeform != 0) {
                    float overX = pipW * 0.45;
                    float overY = pipH * 0.45;
                    pipCenter.x = clamp(pipCenter.x, pipHalf.x - overX, fw - pipHalf.x + overX);
                    pipCenter.y = clamp(pipCenter.y, pipHalf.y, fh - pipHalf.y + overY);
                } else {
                    pipCenter.x = clamp(pipCenter.x, pipHalf.x, fw - pipHalf.x);
                    pipCenter.y = clamp(pipCenter.y, pipHalf.y, fh - pipHalf.y);
                }
                float2 pipMin = pipCenter - pipHalf;
                float2 pipMax = pipCenter + pipHalf;

                if (fx >= pipMin.x && fx <= pipMax.x && fy >= pipMin.y && fy <= pipMax.y) {
                    float2 uvInPip = float2(
                        (fx - pipMin.x) / pipW,
                        (fy - pipMin.y) / pipH
                    );

                    float2 pipUV = uvInPip;
                    if (u.mirror != 0) pipUV.x = 1.0 - pipUV.x;  // selfie flip
                    float4 camColor;
                    float2 camUV;
                    bool fitOutside = false;
                    if (u.freeform != 0) {
                        // Freeform silhouette: aspect-FIT so the whole frame
                        // (head included) always shows; letterbox margin is
                        // transparent.
                        camUV = aspectFitCamUV(pipUV,
                            float(u.cameraWidth), float(u.cameraHeight),
                            pipW, pipH, fitOutside);
                        constexpr sampler s(filter::linear, address::clamp_to_edge);
                        camColor = fitOutside ? float4(0.0) : cameraTex.sample(s, camUV);
                    } else {
                        camColor = sampleAspectFill(cameraTex, pipUV,
                                                    float(u.cameraWidth), float(u.cameraHeight),
                                                    pipW, pipH);
                        camUV = aspectFillCamUV(pipUV,
                            float(u.cameraWidth), float(u.cameraHeight), pipW, pipH);
                    }

                    float sdf = shapeSDF(float2(fx, fy), pipCenter, pipHalf, u.pipShape);
                    float mask;
                    if (u.freeform != 0) {
                        mask = 1.0;  // no shape clip; matte decides visibility
                    } else if (u.pipShape == 5 /*softEdge*/) {
                        float r = min(pipHalf.x, pipHalf.y);
                        float feather = max(r * 0.18, 2.0);
                        mask = clamp(1.0 - (sdf + feather) / feather, 0.0, 1.0);
                    } else {
                        mask = clamp(0.5 - sdf, 0.0, 1.0);
                    }
                    // Background removal inside the PIP.
                    if (u.removeBg != 0) {
                        // In the fit letterbox margin there's no camera content,
                        // so the person matte must read 0 (fully transparent).
                        float pa = fitOutside ? 0.0 : personAlpha(maskTex, camUV, u.hasMask);
                        if (u.bgMode == 0 /*transparent*/) {
                            mask *= pa;
                        } else {
                            camColor.rgb = mix(float3(u.bgR, u.bgG, u.bgB), camColor.rgb, pa);
                        }
                    }
                    color = mix(color, camColor, mask);
                }

                // Border ring as a texture (ALL styles, exact selected color +
                // glow/shadow). Sampled over the pip rect EXPANDED by borderPad
                // so neon/glow that overflow the shape still render. Outside the
                // pip-region `if` above so the padded margin is reachable.
                if (u.hasBorderTex != 0) {
                    float padW = u.borderPad;
                    float totW = pipW + 2.0 * padW;
                    float totH = pipH + 2.0 * padW;
                    float bx = (fx - (pipMin.x - padW)) / totW;
                    float by = (fy - (pipMin.y - padW)) / totH;
                    if (bx >= 0.0 && bx <= 1.0 && by >= 0.0 && by <= 1.0) {
                        constexpr sampler s(filter::linear, address::clamp_to_edge);
                        // CGContext buffer is bottom-left origin → flip V.
                        float4 ring = borderTex.sample(s, float2(bx, 1.0 - by));
                        color.rgb = ring.rgb + color.rgb * (1.0 - ring.a);  // premultiplied over
                    }
                }
            }
        }

        outTex.write(color, gid);
    }
    """
}

/// Shader uniforms — must match the `struct Uniforms` in the shader
/// byte-for-byte. All fields are 4-byte aligned.
struct ComposeUniforms {
    var outWidth: UInt32
    var outHeight: UInt32
    var layout: UInt32
    var screenAnchor: UInt32
    var hasScreen: UInt32
    var hasCamera: UInt32
    var screenWidth: UInt32
    var screenHeight: UInt32
    var cameraWidth: UInt32
    var cameraHeight: UInt32
    var pipPosX: Float
    var pipPosY: Float
    var pipSize: Float
    var pipShape: UInt32
    var borderStyle: UInt32
    var borderWidth: Float
    var borderR: Float
    var borderG: Float
    var borderB: Float
    var borderA: Float
    var border2R: Float
    var border2G: Float
    var border2B: Float
    var removeBg: UInt32    // 1 = background removal active
    var bgMode: UInt32      // 0=transparent 1=color 2=blur 3=image
    var hasMask: UInt32     // 1 = segmentation mask texture bound
    var freeform: UInt32    // 1 = skip shape clip (free silhouette)
    var bgR: Float
    var bgG: Float
    var bgB: Float
    var imgWidth: UInt32    // bg image dims (for aspect-fill); 0 if none
    var imgHeight: UInt32
    var mirror: UInt32      // 1 = flip camera horizontally (selfie)
    var hasBorderTex: UInt32   // 1 = sample borderTex at texture(6)
    var borderTexW: UInt32     // border texture px (incl. pad)
    var borderTexH: UInt32
    var borderPad: Float       // px of padding baked into the border texture
    var screenFit: UInt32      // 1 = whole screen (aspect-fit) over blurred screen bg
}
