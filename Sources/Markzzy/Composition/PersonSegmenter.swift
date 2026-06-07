import Foundation
import Vision
import CoreVideo
import QuartzCore
import Metal

/// Real-time person segmentation for the face cam (background removal).
///
/// Pipeline (mirrors what Google Meet does), all fused into one GPU pass:
/// Vision segmentation → **edge refinement guided by the camera** (joint
/// bilateral) → **adaptive temporal smoothing** → clean matte that BOTH the
/// recording and preview compositors consume identically.
///
/// - Vision `VNGeneratePersonSegmentationRequest` gives a coarse, lower-res
///   person mask. Concurrency = **drop, don't queue** (skip if a request is
///   still in flight; reuse the last matte) so we never build a backlog.
/// - **Guided refinement**: a joint-bilateral upsample snaps the matte edge to
///   the REAL edges in the camera frame (hair, shoulders) and removes the
///   "cut with scissors"/halo look. This is the step that closes most of the
///   gap to Zoom/Meet, whose secret is edge post-processing, not a heavier model.
/// - **Adaptive temporal**: blends with the previous matte MORE where the image
///   is still (kills shimmer) and LESS where it's moving (kills the ghost/trail
///   you'd get from a fixed EMA). Blend of MASK PIXELS — never touches
///   size/position.
public final class PersonSegmenter {

    /// `.balanced` keeps the matte LATENCY low (~half of `.accurate`), which is
    /// what stops the "background flash" when you move fast: a fresher matte
    /// stays aligned with the live camera frame. The guided refinement downstream
    /// recovers the edge sharpness, so static quality stays high. Falls back to
    /// `.fast` once if even `.balanced` can't keep up.
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    private let queue = DispatchQueue(label: "markzzy.segmenter", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastMask: CVPixelBuffer?
    // The camera frame the current matte was computed FROM. Compositing this
    // paired frame (instead of the latest live frame) keeps the matte and the
    // camera perfectly aligned → no background flash on fast motion.
    private var lastFrame: CVPixelBuffer?

    // MARK: Quality fallback
    // If `.accurate` can't sustain a reasonable rate, drop to `.balanced` ONCE.
    private var slowCount = 0
    private var didFallback = false

    // MARK: Guided refinement + temporal (Metal)
    private let mtlDevice = MTLCreateSystemDefaultDevice()
    private var mtlQueue: MTLCommandQueue?
    private var refinePipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var refineOutA: CVPixelBuffer?    // refined matte (R8, guide res)
    private var refineOutB: CVPixelBuffer?    // ping-pong: one is "prev", one is "out"
    private var refineUseA = true
    private var hasPrevRefined = false
    private var refineW = 0
    private var refineH = 0
    private var metalReady = false
    private var metalFailed = false

    public init() { setupMetal() }

    /// The most recent (refined + temporally-stable) mask. Returns nil until the
    /// first segmentation completes.
    public func currentMask() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return lastMask
    }

    /// The most recent matte PAIRED with the exact camera frame it was computed
    /// from. Compose this frame (not the latest live one) so the matte and the
    /// pixels line up perfectly → no background flash when moving fast.
    public func currentMatte() -> (mask: CVPixelBuffer, frame: CVPixelBuffer)? {
        lock.lock(); defer { lock.unlock() }
        guard let m = lastMask, let f = lastFrame else { return nil }
        return (m, f)
    }

    /// Submit a camera frame for segmentation. Non-blocking: if a previous
    /// request is still running, this call is a no-op (the caller keeps using
    /// `currentMask()`, which still holds the last good matte).
    public func submit(_ camera: CVPixelBuffer) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock(); self.busy = false; self.lock.unlock()
            }
            let handler = VNImageRequestHandler(cvPixelBuffer: camera, options: [:])
            let t0 = CACurrentMediaTime()
            do {
                try handler.perform([self.request])
            } catch {
                return
            }
            self.maybeFallback(performTime: CACurrentMediaTime() - t0)
            guard let obs = self.request.results?.first as? VNPixelBufferObservation else {
                return
            }
            // Single GPU pass: guided edge refinement + adaptive temporal.
            // Falls back to the raw Vision matte if Metal is unavailable.
            let refined = self.refine(matte: obs.pixelBuffer, guide: camera) ?? obs.pixelBuffer
            self.lock.lock()
            self.lastMask = refined
            self.lastFrame = camera   // pair the matte with the frame it came from
            self.lock.unlock()
        }
    }

    /// Drop `.balanced` → `.fast` once if segmentation is consistently slow,
    /// so the preview never feels laggy (and the matte stays fresh) on weaker
    /// machines.
    private func maybeFallback(performTime dt: CFTimeInterval) {
        guard !didFallback else { return }
        // >45ms per segmentation ≈ under the headroom we want for a smooth live
        // preview. Require a sustained streak so a single hiccup doesn't trip it.
        if dt > 0.045 { slowCount += 1 } else { slowCount = 0 }
        if slowCount >= 15 {
            didFallback = true
            request.qualityLevel = .fast
        }
    }

    // MARK: - Metal guided refinement + adaptive temporal

    private func setupMetal() {
        guard let dev = mtlDevice else { metalFailed = true; return }
        guard let q = dev.makeCommandQueue() else { metalFailed = true; return }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard let tc = cache else { metalFailed = true; return }
        do {
            let lib = try dev.makeLibrary(source: Self.refineSource, options: nil)
            guard let fn = lib.makeFunction(name: "refine_matte") else {
                metalFailed = true; return
            }
            refinePipeline = try dev.makeComputePipelineState(function: fn)
        } catch {
            metalFailed = true; return
        }
        mtlQueue = q
        textureCache = tc
        metalReady = true
    }

    /// One GPU pass: joint-bilateral edge refinement of `matte` guided by the
    /// camera frame, then adaptive temporal blend with the previous output.
    /// Output is an R8 matte at (capped) camera resolution. Returns nil if Metal
    /// isn't available.
    private func refine(matte: CVPixelBuffer, guide: CVPixelBuffer) -> CVPixelBuffer? {
        guard metalReady, !metalFailed,
              let pipeline = refinePipeline, let queue = mtlQueue,
              let tc = textureCache else { return nil }

        let gw = CVPixelBufferGetWidth(guide)
        let gh = CVPixelBufferGetHeight(guide)
        guard gw > 0, gh > 0 else { return nil }
        let maxDim = 1280
        let scale = min(1.0, Double(maxDim) / Double(max(gw, gh)))
        let ow = max(16, Int(Double(gw) * scale))
        let oh = max(16, Int(Double(gh) * scale))

        if ow != refineW || oh != refineH || refineOutA == nil || refineOutB == nil {
            refineOutA = makeBuffer(ow, oh)
            refineOutB = makeBuffer(ow, oh)
            refineW = ow; refineH = oh
            refineUseA = true
            hasPrevRefined = false
        }
        let out = refineUseA ? refineOutA : refineOutB
        let prev = refineUseA ? refineOutB : refineOutA
        refineUseA.toggle()
        guard let out, let prev,
              let guideTex = makeTexture(guide, format: .bgra8Unorm, cache: tc),
              let matteTex = makeTexture(matte, format: .r8Unorm, cache: tc),
              let prevTex = makeTexture(prev, format: .r8Unorm, cache: tc),
              let outTex = makeTexture(out, format: .r8Unorm, cache: tc),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        enc.setComputePipelineState(pipeline)
        enc.setTexture(guideTex, index: 0)
        enc.setTexture(matteTex, index: 1)
        enc.setTexture(prevTex, index: 2)
        enc.setTexture(outTex, index: 3)
        // sigmaSpace/sigmaRange: edge-snapping strength. tempStill: blend weight
        // of the NEW frame when static (low = smooth). tempMotion: how fast that
        // weight rises with motion (high = snaps to live, no ghost trail).
        var params = RefineParams(
            sigmaSpace: 2.0, sigmaRange: 0.10, stepPx: 1.5,
            tempStill: 0.35, tempMotion: 5.0,
            hasPrev: hasPrevRefined ? 1 : 0
        )
        enc.setBytes(&params, length: MemoryLayout<RefineParams>.stride, index: 0)

        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (ow + 7) / 8, height: (oh + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        hasPrevRefined = true
        return out
    }

    private func makeTexture(_ pb: CVPixelBuffer, format: MTLPixelFormat,
                             cache: CVMetalTextureCache) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, format, w, h, 0, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            return nil
        }
        return tex
    }

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_OneComponent8,
                            attrs as CFDictionary, &pb)
        return pb
    }

    /// Drop the cached mask + temporal history (e.g. when removal is toggled
    /// off, or the camera changes) so a stale matte can't briefly flash.
    public func reset() {
        lock.lock()
        lastMask = nil
        lastFrame = nil
        busy = false
        refineW = 0; refineH = 0
        refineOutA = nil; refineOutB = nil
        refineUseA = true
        hasPrevRefined = false
        lock.unlock()
    }

    // Metal params struct — must match `RefineParams` in the shader source.
    private struct RefineParams {
        var sigmaSpace: Float
        var sigmaRange: Float
        var stepPx: Float
        var tempStill: Float
        var tempMotion: Float
        var hasPrev: UInt32
    }

    /// Joint-bilateral upsample (edge refinement) + adaptive temporal blend.
    private static let refineSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RefineParams {
        float sigmaSpace; float sigmaRange; float stepPx;
        float tempStill; float tempMotion; uint hasPrev;
    };

    kernel void refine_matte(
        texture2d<float, access::sample> guideTex [[texture(0)]],
        texture2d<float, access::sample> matteTex [[texture(1)]],
        texture2d<float, access::sample> prevTex  [[texture(2)]],
        texture2d<float, access::write>  outTex   [[texture(3)]],
        constant RefineParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
        float2 uv = (float2(gid) + 0.5) /
                    float2(outTex.get_width(), outTex.get_height());
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        // --- Joint-bilateral spatial refinement (guided by the camera) ---
        float3 centerC = guideTex.sample(s, uv).rgb;
        float dx = p.stepPx / float(outTex.get_width());
        float dy = p.stepPx / float(outTex.get_height());
        const int R = 3;        // 7x7 bilateral window
        const int ERODE_R = 2;  // morphological-erosion radius (kills white rim)
        float wsum = 0.0;
        float asum = 0.0;
        float erodeMin = 1.0;   // min of the matte over the erosion window
        float invSpace = 1.0 / (2.0 * p.sigmaSpace * p.sigmaSpace);
        float invRange = 1.0 / (2.0 * p.sigmaRange * p.sigmaRange);
        for (int j = -R; j <= R; j++) {
            for (int i = -R; i <= R; i++) {
                float2 o = float2(float(i) * dx, float(j) * dy);
                float3 c = guideTex.sample(s, uv + o).rgb;
                float a = matteTex.sample(s, uv + o).r;
                float sd = float(i * i + j * j);
                float cd = distance(c, centerC);
                float w = exp(-sd * invSpace) * exp(-(cd * cd) * invRange);
                wsum += w;
                asum += w * a;
                if (abs(i) <= ERODE_R && abs(j) <= ERODE_R) {
                    erodeMin = min(erodeMin, a);
                }
            }
        }
        float spatial = wsum > 0.0 ? (asum / wsum) : matteTex.sample(s, uv).r;
        // Erode: pull the edge INSIDE the person so the bright background rim
        // (the white halo) is excluded. Interior stays ~1 (both terms ~1).
        spatial = min(spatial, erodeMin);

        // --- Adaptive temporal: smooth when still, snap when moving ---
        float a = spatial;
        if (p.hasPrev != 0) {
            float prev = prevTex.sample(s, uv).r;
            float motion = abs(spatial - prev);
            // weight of the NEW frame: low when static, → 1 with any real motion.
            float tAlpha = clamp(p.tempStill + p.tempMotion * motion, p.tempStill, 1.0);
            a = mix(prev, spatial, tAlpha);
        }
        outTex.write(float4(a, a, a, 1.0), gid);
    }
    """
}
