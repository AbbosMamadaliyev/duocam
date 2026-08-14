import AVFoundation
import CoreVideo
import Metal
import os
import simd

/// Composites the two streams into one frame on the GPU.
///
/// Doc 2 §15.2 draws the line this type sits on: the on-screen PiP preview uses
/// two independent preview layers for lowest latency, and **only the recorded
/// output is composited**. So this runs in the sample-buffer pipeline, not the
/// view hierarchy — its output goes to the asset writer.
///
/// Doc 3 Phase 5 task 4 sets the performance shape: no per-frame allocations,
/// `CVMetalTextureCache` for zero-copy texture creation, and a pixel buffer
/// pool for outputs. Every one of those is a rule about *not* doing something
/// each frame, so they are enforced by construction here rather than optimised
/// in later.
final class MetalCompositor: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    private let poolLock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    /// Kept alive for the lifetime of a frame so the GPU is not reading from a
    /// deallocated `CVMetalTexture`.
    private var retainedTextures: [CVMetalTexture] = []

    /// Read from the main actor by the performance HUD while the compositor is
    /// writing it from a stream queue, so it gets its own lock rather than
    /// riding on the caller's.
    private let statsLock = NSLock()
    private var _lastGPUTime: CFTimeInterval = 0
    var lastGPUTime: CFTimeInterval {
        get { statsLock.withLock { _lastGPUTime } }
        set { statsLock.withLock { _lastGPUTime = newValue } }
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CompositorError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw CompositorError.commandQueueUnavailable
        }
        self.device = device
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            throw CompositorError.shaderLibraryMissing
        }
        guard let vertexFunction = library.makeFunction(name: "compositeVertex"),
              let fragmentFunction = library.makeFunction(name: "compositeFragment")
        else {
            throw CompositorError.shaderFunctionMissing
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                == kCVReturnSuccess,
              let cache
        else {
            throw CompositorError.textureCacheUnavailable
        }
        textureCache = cache

        Log.composition.info("Metal compositor ready on \(device.name, privacy: .public)")
    }

    // MARK: Compositing

    /// Renders one composited frame.
    ///
    /// Returns `nil` rather than throwing on a per-frame failure: a dropped
    /// frame is recoverable, and throwing 30 times a second into the capture
    /// pipeline would turn a transient into a crash.
    func composite(
        primary: CVPixelBuffer,
        secondary: CVPixelBuffer?,
        uniforms: CompositionUniforms,
        outputSize: CGSize
    ) -> CVPixelBuffer? {
        let start = CACurrentMediaTime()
        retainedTextures.removeAll(keepingCapacity: true)

        guard let outputBuffer = makeOutputBuffer(size: outputSize) else {
            Log.composition.error("No output pixel buffer available")
            return nil
        }

        guard let destination = makeTexture(from: outputBuffer, plane: 0, format: .bgra8Unorm) else {
            Log.composition.error("Could not wrap output buffer as a texture")
            return nil
        }

        let primaryTextures = planeTextures(for: primary, format: uniforms.primaryFormat)
        let secondaryTextures = secondary.flatMap {
            planeTextures(for: $0, format: uniforms.secondaryFormat)
        }

        guard let primaryTextures else { return nil }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = destination
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return nil }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(primaryTextures.first, index: 0)
        encoder.setFragmentTexture(primaryTextures.second ?? primaryTextures.first, index: 1)
        encoder.setFragmentTexture(secondaryTextures?.first ?? primaryTextures.first, index: 2)
        encoder.setFragmentTexture(
            secondaryTextures?.second ?? primaryTextures.second ?? primaryTextures.first,
            index: 3
        )

        var mutableUniforms = uniforms
        // When no secondary frame was available this frame, draw primary-only.
        //
        // The fallback textures above exist solely to satisfy Metal's binding
        // requirements — they are never meant to be *read*. Leaving
        // `hasSecondary` set while they are bound makes the shader interpret an
        // r8Unorm luma texture as rg8Unorm chroma, which reads (luma, 0) and
        // renders the overlay as flat green. That is exactly the artefact this
        // guard removes.
        if secondaryTextures == nil {
            mutableUniforms.hasSecondary = 0
        }
        encoder.setFragmentBytes(
            &mutableUniforms,
            length: MemoryLayout<CompositionUniforms>.stride,
            index: 0
        )

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        lastGPUTime = CACurrentMediaTime() - start
        return outputBuffer
    }

    /// Composites without blocking the caller.
    ///
    /// The synchronous variant stalls the capture queue for the whole GPU
    /// round trip. At 1080p that is invisible; at 4K it cost 75% of the
    /// frames — measured 7 fps delivered against 30 requested, because
    /// `alwaysDiscardsLateVideoFrames` throws away everything that arrives
    /// while the delegate is still inside the previous frame.
    ///
    /// Handing the result back from `addCompletedHandler` decouples capture
    /// rate from GPU and encoder latency, which is what Doc 3's "0 main-thread
    /// hitches during recording" and 0.1% drop budget actually require.
    func compositeAsync(
        primary: CVPixelBuffer,
        secondary: CVPixelBuffer?,
        uniforms: CompositionUniforms,
        outputSize: CGSize,
        completion: @escaping @Sendable (CVPixelBuffer?) -> Void
    ) {
        let start = CACurrentMediaTime()

        // Textures are retained per encode rather than in a shared array: two
        // frames can now be in flight at once, and a shared array would let the
        // second frame release the first frame's textures out from under the
        // GPU.
        var retained: [CVMetalTexture] = []

        guard let outputBuffer = makeOutputBuffer(size: outputSize),
              let destination = makeTexture(from: outputBuffer, plane: 0, format: .bgra8Unorm, retaining: &retained),
              let primaryTextures = planeTextures(for: primary, format: uniforms.primaryFormat, retaining: &retained)
        else {
            completion(nil)
            return
        }

        let secondaryTextures = secondary.flatMap {
            planeTextures(for: $0, format: uniforms.secondaryFormat, retaining: &retained)
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = destination
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            completion(nil)
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(primaryTextures.first, index: 0)
        encoder.setFragmentTexture(primaryTextures.second ?? primaryTextures.first, index: 1)
        encoder.setFragmentTexture(secondaryTextures?.first ?? primaryTextures.first, index: 2)
        encoder.setFragmentTexture(
            secondaryTextures?.second ?? primaryTextures.second ?? primaryTextures.first,
            index: 3
        )

        var mutableUniforms = uniforms
        if secondaryTextures == nil { mutableUniforms.hasSecondary = 0 }
        encoder.setFragmentBytes(
            &mutableUniforms,
            length: MemoryLayout<CompositionUniforms>.stride,
            index: 0
        )

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            // `retained` is captured so the textures outlive the GPU's use of
            // them; the closure releasing is what frees them.
            _ = retained
            self?.lastGPUTime = CACurrentMediaTime() - start
            completion(outputBuffer)
        }
        commandBuffer.commit()
    }

    // MARK: Textures

    private struct PlanePair {
        let first: MTLTexture
        let second: MTLTexture?
    }

    private func planeTextures(for buffer: CVPixelBuffer, format: Int32) -> PlanePair? {
        planeTextures(for: buffer, format: format, retaining: &retainedTextures)
    }

    private func planeTextures(
        for buffer: CVPixelBuffer,
        format: Int32,
        retaining retained: inout [CVMetalTexture]
    ) -> PlanePair? {
        if format == StreamPixelFormat.bgra.rawValue {
            guard let texture = makeTexture(from: buffer, plane: 0, format: .bgra8Unorm, retaining: &retained)
            else { return nil }
            return PlanePair(first: texture, second: nil)
        }

        guard let luma = makeTexture(from: buffer, plane: 0, format: .r8Unorm, retaining: &retained),
              let chroma = makeTexture(from: buffer, plane: 1, format: .rg8Unorm, retaining: &retained)
        else { return nil }
        return PlanePair(first: luma, second: chroma)
    }

    /// Zero-copy: the `CVMetalTextureCache` maps the IOSurface directly rather
    /// than blitting, which is the whole reason 4K composition can hit the
    /// 6ms budget of Doc 3 Phase 5.
    private func makeTexture(
        from buffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) -> MTLTexture? {
        makeTexture(from: buffer, plane: plane, format: format, retaining: &retainedTextures)
    }

    private func makeTexture(
        from buffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        retaining retained: inout [CVMetalTexture]
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        guard width > 0, height > 0 else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            format,
            width,
            height,
            plane,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else { return nil }

        retained.append(cvTexture)
        return texture
    }

    // MARK: Output pool

    /// Recreated only when the output size changes, so steady-state recording
    /// allocates nothing.
    private func makeOutputBuffer(size: CGSize) -> CVPixelBuffer? {
        poolLock.lock()
        defer { poolLock.unlock() }
        if pool == nil || poolSize != size {
            pool = Self.makePool(size: size)
            poolSize = size
            Log.composition.info("Output pool rebuilt at \(Int(size.width))×\(Int(size.height))")
        }
        guard let pool else { return nil }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    private static func makePool(size: CGSize) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        // Triple buffering (Doc 3 Phase 5 task 4): one buffer being written by
        // the GPU, one being encoded, one free.
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess else { return nil }
        return pool
    }

    /// Called on a memory-pressure warning (Doc 3 Phase 5 task 7).
    func releaseCaches() {
        CVMetalTextureCacheFlush(textureCache, 0)
        pool = nil
        poolSize = .zero
        Log.composition.info("Compositor caches released under memory pressure")
    }
}

nonisolated enum CompositorError: LocalizedError {
    case noMetalDevice
    case commandQueueUnavailable
    case shaderLibraryMissing
    case shaderFunctionMissing
    case textureCacheUnavailable

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: "No Metal device is available."
        case .commandQueueUnavailable: "Could not create a Metal command queue."
        case .shaderLibraryMissing: "The compositing shader library is missing."
        case .shaderFunctionMissing: "A compositing shader function is missing."
        case .textureCacheUnavailable: "Could not create the Metal texture cache."
        }
    }
}
