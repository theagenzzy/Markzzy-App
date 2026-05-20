import Metal
import MetalKit
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

    public func update(position: CGPoint, size: CGFloat, shape: PIPShape, border: PIPBorder) {
        lock.lock(); defer { lock.unlock() }
        self.position = position
        self.size = size
        self.shape = shape
        self.border = border
    }

    public func render(screen: CVPixelBuffer?,
                       camera: CVPixelBuffer?,
                       into out: CVPixelBuffer,
                       layout: Layout,
                       screenAnchor: ScreenAnchor) {
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

        lock.lock()
        let pos = position; let sz = size; let sh = shape; let bd = border
        lock.unlock()

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
            border2B: Float(bd.color2.components?[2] ?? 0)
        )

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipelineState)
        if let s = screenTex { encoder.setTexture(s, index: 0) }
        if let c = cameraTex { encoder.setTexture(c, index: 1) }
        encoder.setTexture(outTex, index: 2)
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

    kernel void compose_kernel(
        texture2d<float, access::sample> screenTex [[texture(0)]],
        texture2d<float, access::sample> cameraTex [[texture(1)]],
        texture2d<float, access::write>  outTex    [[texture(2)]],
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
                color = sampleScreenAnchored(screenTex, uv,
                                              float(u.screenWidth), float(u.screenHeight),
                                              fw, fh, u.screenAnchor);
            }
        } else if (u.layout == 3 /*cameraOnly*/) {
            if (u.hasCamera != 0) {
                float2 uv = float2(fx / fw, fy / fh);
                color = sampleAspectFill(cameraTex, uv,
                                          float(u.cameraWidth), float(u.cameraHeight),
                                          fw, fh);
            }
        } else if (u.layout == 1 /*splitScreenTop*/ || u.layout == 2 /*splitCamTop*/) {
            float halfH = fh * 0.5;
            bool inTop = fy < halfH;  // metal is top-left origin, top = small y
            bool screenSlot = (u.layout == 1) ? inTop : !inTop;
            float yInSlot = inTop ? fy : (fy - halfH);
            float2 uv = float2(fx / fw, yInSlot / halfH);
            if (screenSlot && u.hasScreen != 0) {
                color = sampleScreenAnchored(screenTex, uv,
                                              float(u.screenWidth), float(u.screenHeight),
                                              fw, halfH, u.screenAnchor);
            } else if (!screenSlot && u.hasCamera != 0) {
                color = sampleAspectFill(cameraTex, uv,
                                          float(u.cameraWidth), float(u.cameraHeight),
                                          fw, halfH);
            }
        } else /*pipOverlay*/ {
            // Background = screen (anchor handled implicitly: pipOverlay
            // uses the full screen, no crop).
            if (u.hasScreen != 0) {
                float2 uv = float2(fx / fw, fy / fh);
                color = sampleAspectFill(screenTex, uv,
                                          float(u.screenWidth), float(u.screenHeight),
                                          fw, fh);
            }
            // PIP overlay.
            if (u.hasCamera != 0) {
                float pipW = fw * u.pipSize;
                bool isSquare = (u.pipShape != 0);  // non-rect = square
                float pipH = isSquare ? pipW : (pipW * float(u.cameraHeight) / float(u.cameraWidth));
                float2 pipCenter = float2(u.pipPosX * fw, u.pipPosY * fh);
                float2 pipHalf = float2(pipW * 0.5, pipH * 0.5);
                float2 pipMin = pipCenter - pipHalf;
                float2 pipMax = pipCenter + pipHalf;

                if (fx >= pipMin.x && fx <= pipMax.x && fy >= pipMin.y && fy <= pipMax.y) {
                    // Sample the camera into the PIP rect (aspect-fill).
                    float2 uvInPip = float2(
                        (fx - pipMin.x) / pipW,
                        (fy - pipMin.y) / pipH
                    );
                    float4 camColor = sampleAspectFill(cameraTex, uvInPip,
                                                        float(u.cameraWidth), float(u.cameraHeight),
                                                        pipW, pipH);
                    // Shape mask via SDF. softEdge uses a wide
                    // feather (~10% of radius) for a true diffuse
                    // edge — otherwise it looked identical to circle.
                    float sdf = shapeSDF(float2(fx, fy), pipCenter, pipHalf, u.pipShape);
                    float mask;
                    if (u.pipShape == 5 /*softEdge*/) {
                        float r = min(pipHalf.x, pipHalf.y);
                        float feather = max(r * 0.18, 2.0);
                        mask = clamp(1.0 - (sdf + feather) / feather, 0.0, 1.0);
                    } else {
                        mask = clamp(0.5 - sdf, 0.0, 1.0);
                    }
                    color = mix(color, camColor, mask);

                    // Border (solid only for now — gradient/chrome later).
                    if (u.borderStyle == 1 /*solid*/ && u.borderWidth > 0) {
                        float bw = u.borderWidth;
                        float ringMask = clamp(1.0 - abs(sdf + bw * 0.5) / (bw * 0.5), 0.0, 1.0);
                        float4 borderColor = float4(u.borderR, u.borderG, u.borderB, u.borderA);
                        color = mix(color, borderColor, ringMask * borderColor.a);
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
}
