//
//  FloodController.swift
//  BAHAR QC
//
//  Owns the full-screen flood water post-process (FloodWater.metal).
//  Game logic (floor smoothing, water-level animation, uniforms) runs on the
//  main thread in RealityKit's scene update and is published to a
//  lock-protected snapshot; the postProcess callback (render thread) only
//  reads that snapshot, adds the projection from its context and dispatches
//  the kernel.
//
//  The floor height is supplied by ARContainerView's ground detection via
//  `setFloor(_:)`; the flood depth via `setDepth(_:)` / `drain()`.
//
//  iOS only.
//

#if os(iOS)

import ARKit
import Combine
import Metal
import QuartzCore
import RealityKit
import simd

final class FloodController {
    // MARK: Tuning
    var targetDepth: Float = 0.9          // m above the floor
    var riseSpeed: Float = 0.3            // m/s
    var settings = FloodController.defaultUniforms()

    // MARK: State
    private weak var arView: ARView?
    private var updateSub: Cancellable?
    private var floorTarget: Float?
    private var floorY: Float?
    private var currentDepth: Float = 0
    private var depthGoal: Float = 0
    private let startTime = CACurrentMediaTime()

    // Shared with the render thread (postProcess / prepareWithDevice), which
    // is not the main actor — every access goes through `lock`.
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var pipeline: MTLComputePipelineState?
    private nonisolated(unsafe) var snapshot = FloodUniforms()
    private nonisolated(unsafe) var depthBuffer: CVPixelBuffer?
    private nonisolated(unsafe) var textureCache: CVMetalTextureCache?
    private nonisolated(unsafe) var emptyDepth: MTLTexture?   // bound when there's no depth map

    init(arView: ARView, floodOnStart: Bool = true) {
        self.arView = arView
        if floodOnStart { depthGoal = targetDepth }
        arView.renderCallbacks.prepareWithDevice = { @Sendable [weak self] device in
            self?.makePipeline(device: device)
        }
        arView.renderCallbacks.postProcess = { @Sendable [weak self] ctx in
            self?.postProcess(ctx)
        }
        updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            self?.update(dt: Float(e.deltaTime))
        }
    }

    // MARK: Public API
    func flood() { depthGoal = targetDepth }
    func drain() { depthGoal = 0 }
    func setDepth(_ meters: Float) { targetDepth = meters; depthGoal = meters }
    /// World Y of the detected floor. Changes after the first call are
    /// smoothed so ARKit refinements don't make the water jump.
    func setFloor(_ y: Float) { floorTarget = y }

    // MARK: Main-thread update
    private func update(dt: Float) {
        guard let arView else { return }
        if let target = floorTarget {
            floorY = floorY.map { $0 + (target - $0) * (1 - exp(-4 * dt)) } ?? target
        }
        var u = settings
        if let floorY {
            currentDepth = moveTowards(currentDepth, depthGoal, riseSpeed * dt)
            u.waterHeight = floorY + currentDepth
            u.enabled = currentDepth > 0.005 ? 1 : 0
        } else {
            u.enabled = 0                 // hide until a floor is found
        }
        let camToWorld = arView.cameraTransform.matrix
        u.cameraToWorld = camToWorld
        u.cameraPosition = SIMD3(camToWorld.columns.3.x, camToWorld.columns.3.y, camToWorld.columns.3.z)
        u.time = Float(CACurrentMediaTime() - startTime)

        // LiDAR depth if available, else ARKit's people-only depth.
        var depth: CVPixelBuffer?
        if let frame = arView.session.currentFrame {
            depth = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap ?? frame.estimatedDepthData
            let orientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
            let t = frame.displayTransform(for: orientation, viewportSize: arView.bounds.size).inverted()
            u.viewToDepthUV = simd_float3x3(SIMD3(Float(t.a), Float(t.b), 0),
                                            SIMD3(Float(t.c), Float(t.d), 0),
                                            SIMD3(Float(t.tx), Float(t.ty), 1))
        }
        u.hasDepth = depth != nil ? 1 : 0
        lock.lock(); snapshot = u; depthBuffer = depth; lock.unlock()
    }

    private func moveTowards(_ a: Float, _ b: Float, _ step: Float) -> Float {
        abs(b - a) <= step ? b : a + (b > a ? step : -step)
    }

    // MARK: Render thread
    private nonisolated func makePipeline(device: MTLDevice) {
        guard let fn = device.makeDefaultLibrary()?.makeFunction(name: "floodWaterKernel") else {
            assertionFailure("floodWaterKernel not found in default Metal library"); return
        }
        let state = try? device.makeComputePipelineState(function: fn)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        let empty = device.makeTexture(descriptor: desc)
        lock.lock(); pipeline = state; textureCache = cache; emptyDepth = empty; lock.unlock()
    }

    private nonisolated func postProcess(_ ctx: ARView.PostProcessContext) {
        lock.lock()
        let pipeline = self.pipeline
        var u = snapshot
        let depthBuffer = self.depthBuffer
        let textureCache = self.textureCache
        let emptyDepth = self.emptyDepth
        lock.unlock()

        var cvDepth: CVMetalTexture?
        if let depthBuffer, let textureCache {
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, depthBuffer, nil, .r32Float,
                                                      CVPixelBufferGetWidth(depthBuffer),
                                                      CVPixelBufferGetHeight(depthBuffer),
                                                      0, &cvDepth)
        }
        let depthTex = cvDepth.flatMap(CVMetalTextureGetTexture)
        if depthTex == nil { u.hasDepth = 0 }

        guard let pipeline, let enc = ctx.commandBuffer.makeComputeCommandEncoder() else {
            // never leave the target empty (black screen): pass the frame through
            if let blit = ctx.commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: ctx.sourceColorTexture, to: ctx.targetColorTexture); blit.endEncoding()
            }
            return
        }
        u.invProjection  = ctx.projection.inverse
        u.viewProjection = ctx.projection * u.cameraToWorld.inverse

        enc.setComputePipelineState(pipeline)
        enc.setTexture(ctx.sourceColorTexture, index: 0)
        enc.setTexture(ctx.targetColorTexture, index: 1)
        enc.setTexture(depthTex ?? emptyDepth, index: 2)
        enc.setBytes(&u, length: MemoryLayout<FloodUniforms>.stride, index: 0)
        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        enc.dispatchThreads(MTLSize(width: ctx.targetColorTexture.width,
                                    height: ctx.targetColorTexture.height,
                                    depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
        // The CVMetalTexture must outlive the GPU's use of its MTLTexture.
        nonisolated(unsafe) let keepAlive = cvDepth
        ctx.commandBuffer.addCompletedHandler { _ in _ = keepAlive }
    }

    // MARK: Defaults (brief section 7, except the underwater tint/strength,
    // deepened to water blue; colours are linear RGB)
    nonisolated static func defaultUniforms() -> FloodUniforms {
        var u = FloodUniforms()
        u.waterTint = SIMD3(0.62, 0.72, 0.76)
        u.underwaterTint = SIMD3(0.05, 0.30, 0.50)
        u.skyColor = SIMD3(0.86, 0.90, 0.94)
        u.sunDirection = simd_normalize(SIMD3<Float>(0.3, 0.8, 0.2))
        u.waveAmp = 0.025
        u.waveSpeed = 1.0
        u.waveScale = 0.8
        u.rippleScale = 2.5
        u.rippleStrength = 0.6
        u.rippleSpeed = 0.35
        u.refractionStrength = 0.05
        u.waterTintStrength = 0.35
        u.reflectionStrength = 0.9
        u.reflectionBias = 0.15
        u.fresnelPower = 3.0
        u.reflectionDistance = 8
        u.specularPower = 180
        u.specularIntensity = 0.6
        u.fadeStart = 25
        u.fadeEnd = 40
        u.underwaterTintStrength = 0.9
        u.wobbleAmount = 0.012
        u.wobbleScale = 5
        u.wobbleSpeed = 0.6
        u.vignette = 0.8
        u.meniscusWidth = 0.003
        u.meniscusStrength = 0.35
        u.debugMode = 0
        return u
    }
}

#endif
