import Foundation
import Metal
import QuartzCore
import CoreVideo
import simd

/// Zero-copy 120Hz ProMotion Metal video renderer backed by `CAMetalLayer` (`displaySyncEnabled = true`)
/// and `CVMetalTextureCache`. Drops stale queued pixel buffers so only the latest frame is presented.
public final class MetalVideoRenderer: @unchecked Sendable {
    public let metalLayer: CAMetalLayer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    private let frameLock = NSLock()
    private var pendingPixelBuffer: CVPixelBuffer?
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut videoVertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        const float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        VertexOut out;
        out.position = float4(positions[vid] * scale, 0.0, 1.0);
        out.texCoord = uvs[vid];
        return out;
    }

    fragment float4 videoFragment(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler samp [[sampler(0)]]) {
        return tex.sample(samp, in.texCoord);
    }
    """

    public init?() {
        guard let mtlDevice = MTLCreateSystemDefaultDevice(),
              let queue = mtlDevice.makeCommandQueue() else {
            return nil
        }

        let library: MTLLibrary
        do {
            library = try mtlDevice.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            return nil
        }

        guard let vertFunc = library.makeFunction(name: "videoVertex"),
              let fragFunc = library.makeFunction(name: "videoFragment") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? mtlDevice.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        guard let sampler = mtlDevice.makeSamplerState(descriptor: sampDesc) else {
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &cache) == kCVReturnSuccess else {
            return nil
        }

        let layer = CAMetalLayer()
        layer.device = mtlDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.displaySyncEnabled = true
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        self.device = mtlDevice
        self.commandQueue = queue
        self.pipelineState = pipeline
        self.samplerState = sampler
        self.textureCache = cache
        self.metalLayer = layer
    }

    /// Stores only the newest `CVPixelBuffer` (overwriting any unpresented frame to guarantee zero queue lag).
    public func submit(pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        pendingPixelBuffer = pixelBuffer
        videoWidth = CVPixelBufferGetWidth(pixelBuffer)
        videoHeight = CVPixelBufferGetHeight(pixelBuffer)
        frameLock.unlock()
    }

    /// Renders the latest pending pixel buffer onto the `CAMetalLayer` if one is available.
    public func renderLatestFrameIfAvailable() {
        autoreleasepool {
            guard let cache = textureCache,
                  metalLayer.drawableSize.width > 0,
                  metalLayer.drawableSize.height > 0 else {
                return
            }

            frameLock.lock()
            let hasPending = (pendingPixelBuffer != nil && videoWidth > 0 && videoHeight > 0)
            frameLock.unlock()

            guard hasPending,
                  let drawable = metalLayer.nextDrawable() else {
                return
            }

            frameLock.lock()
            guard let pb = pendingPixelBuffer else {
                frameLock.unlock()
                return
            }
            pendingPixelBuffer = nil
            let vw = videoWidth
            let vh = videoHeight
            frameLock.unlock()

            guard vw > 0, vh > 0 else {
                return
            }

            var cvTex: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pb,
                nil,
                .bgra8Unorm,
                vw,
                vh,
                0,
                &cvTex
            )
            guard status == kCVReturnSuccess,
                  let cvTexture = cvTex,
                  let mtlTexture = CVMetalTextureGetTexture(cvTexture) else {
                return
            }

            let dw = Float(metalLayer.drawableSize.width)
            let dh = Float(metalLayer.drawableSize.height)
            let viewAspect = dw / max(1.0, dh)
            let videoAspect = Float(vw) / Float(max(1, vh))
            var scale: SIMD2<Float>
            if viewAspect > videoAspect {
                scale = SIMD2<Float>(videoAspect / viewAspect, 1.0)
            } else {
                scale = SIMD2<Float>(1.0, viewAspect / videoAspect)
            }

            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = drawable.texture
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let cmdBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setFragmentTexture(mtlTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            cmdBuffer.present(drawable)
            cmdBuffer.commit()
        }
    }
}
