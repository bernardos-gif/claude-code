// Metal renderer: consumes a platform-independent RenderFrame.
//
// Frame graph (each group is its own command buffer so the debug overlay can show GPU
// time per stage):
//   Setup     sky cubemap bake (on change), GPU particle spawn + simulation
//   Shadows   3 cascades into a depth texture array
//   Prepass   depth + view normals/roughness + motion vectors + linear depth; tiled light
//             culling (compute); SSAO + bilateral blur
//   Opaque    Forward+ PBR shading, procedural sky, projected decals
//   Effects   half-res volumetric fog, SSR (additive), fog composite
//   Transp.   afterimages, weapon trails, particles
//   Resolve   TAA or MetalFX temporal upscaling
//   Post      motion blur, depth of field, bloom chain, tonemap/grade composite,
//             debug lines, UI, screenshot, present
import Foundation
import Metal
import MetalKit
import MetalFX
import BladeCore

struct RenderStats {
    var drawCalls = 0
    var triangles = 0
    var particles = 0
    var renderSize = Vec2.zero
    var gpuPasses: [(String, Double)] = []
    var gpuTotal: Double = 0
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let shaders: ShaderLibrary
    let font: FontAtlas
    let meshes: MeshCache
    let outputFormat: MTLPixelFormat

    private var rings: [UploadRing]
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameCounter = 0
    private var pipelines = PipelineSet()
    private var pipelinesVersion = -1
    private var dsWrite: MTLDepthStencilState
    private var dsTest: MTLDepthStencilState
    private var dsAlways: MTLDepthStencilState
    private var targets: RenderTargets?
    private var detailA: MTLTexture?
    private var detailN: MTLTexture?
    private var skyCube: MTLTexture?
    private var skyBakedVersion = -1
    private var skyBakedTime: Float = -100
    private var shadowMap: MTLTexture?
    private var shadowSize = 0
    private var particlePool: MTLBuffer?
    private var particleCapacity = 0
    private var particleHead = 0
    private var particlePoolFresh = false
    private var historyIndex = 0
    private var historyValid = false
    private var prevViewProj = Mat4.identity
    private var prevViewProjNoJitter = Mat4.identity
    private var mfxScaler: MTLFXTemporalScaler?
    private var mfxKey = ""
    private var screenshotPending = false
    var onScreenshot: ((URL?) -> Void)?

    private let statsLock = NSLock()
    private var gpuTimes: [String: Double] = [:]
    private var gpuOrder: [String] = []
    private(set) var stats = RenderStats()

    static let cascadeSplits: [Float] = [7, 20, 55]
    static let maxLights = 256

    init?(device: MTLDevice, outputFormat: MTLPixelFormat) {
        self.device = device
        self.outputFormat = outputFormat
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        queue.label = "BladeRush"
        shaders = ShaderLibrary(device: device)
        font = FontAtlas(device: device)
        UIMetrics.provider = font
        meshes = MeshCache(device: device)
        rings = (0..<3).map { UploadRing(device: device, capacity: 24 * 1024 * 1024, label: "UploadRing\($0)") }

        func ds(_ f: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = f
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        dsWrite = ds(.less, true)
        dsTest = ds(.lessEqual, false)
        dsAlways = ds(.always, false)

        let (a, n) = timed("detail textures", "render") { TextureGen.detailTextures() }
        detailA = TextureFactory.upload(device, queue: queue, "DetailA", width: a.width, height: a.height, rgba: a.pixels)
        detailN = TextureFactory.upload(device, queue: queue, "DetailN", width: n.width, height: n.height, rgba: n.pixels)

        let cd = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: 128, mipmapped: true)
        cd.usage = [.shaderRead, .shaderWrite]
        cd.storageMode = .private
        skyCube = device.makeTexture(descriptor: cd)
        skyCube?.label = "SkyCube"

        let expected = FrameUniformsGPU.expectedSize
        if MemoryLayout<FrameUniformsGPU>.size != expected {
            logError("FrameUniformsGPU is \(MemoryLayout<FrameUniformsGPU>.size) bytes, shader expects \(expected)", "render")
        }
        rebuildPipelinesIfNeeded()
        logInfo("Renderer ready on \(device.name)", "render")
    }

    private func rebuildPipelinesIfNeeded() {
        guard shaders.version != pipelinesVersion else { return }
        pipelinesVersion = shaders.version
        let t0 = Date()
        pipelines = PipelineSet.build(device: device, shaders: shaders, output: outputFormat)
        let missing = pipelines.missing
        logInfo(String(format: "Pipelines built in %.0f ms%@", Date().timeIntervalSince(t0) * 1000,
                       missing.isEmpty ? "" : " (unavailable: \(missing.joined(separator: ", ")))"), "render")
        skyBakedVersion = -1
    }

    func requestScreenshot() { screenshotPending = true }

    var shaderErrors: [String: String] { shaders.errors }

    // MARK: - Resources

    private func ensureTargets(renderW: Int, renderH: Int, outW: Int, outH: Int, metalFX: Bool) {
        if let t = targets, t.renderW == renderW, t.renderH == renderH, t.outW == outW, t.outH == outH, t.metalFX == metalFX { return }
        targets = RenderTargets(device: device, renderW: renderW, renderH: renderH, outW: outW, outH: outH, metalFX: metalFX)
        historyValid = false
        mfxScaler = nil
        mfxKey = ""
        if let t = targets {
            logInfo(String(format: "Render targets %dx%d -> %dx%d (%@), ~%.0f MB", renderW, renderH, outW, outH,
                           metalFX ? "MetalFX" : "TAA", t.memoryMB), "render")
        }
    }

    private func ensureShadowMap(_ size: Int) {
        guard size != shadowSize || shadowMap == nil else { return }
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = Formats.depth
        d.width = size
        d.height = size
        d.arrayLength = 3
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        shadowMap = device.makeTexture(descriptor: d)
        shadowMap?.label = "ShadowCascades"
        shadowSize = size
    }

    private func ensureParticles(_ capacity: Int, cb: MTLCommandBuffer) {
        let cap = max(1024, capacity)
        guard cap != particleCapacity || particlePool == nil else { return }
        particlePool = device.makeBuffer(length: cap * MemoryLayout<ParticleGPU>.stride, options: .storageModePrivate)
        particlePool?.label = "ParticlePool"
        particleCapacity = cap
        particleHead = 0
        if let pool = particlePool, let blit = cb.makeBlitCommandEncoder() {
            blit.fill(buffer: pool, range: 0..<pool.length, value: 0)
            blit.endEncoding()
        }
        particlePoolFresh = true
    }

    private func ensureMetalFX(_ t: RenderTargets) -> MTLFXTemporalScaler? {
        let key = "\(t.renderW)x\(t.renderH)>\(t.outW)x\(t.outH)"
        if key == mfxKey { return mfxScaler }
        mfxKey = key
        let d = MTLFXTemporalScalerDescriptor()
        d.inputWidth = t.renderW
        d.inputHeight = t.renderH
        d.outputWidth = t.outW
        d.outputHeight = t.outH
        d.colorTextureFormat = Formats.hdr
        d.depthTextureFormat = Formats.depth
        d.motionTextureFormat = Formats.velocity
        d.outputTextureFormat = Formats.hdr
        d.isAutoExposureEnabled = false
        mfxScaler = d.makeTemporalScaler(device: device)
        if mfxScaler == nil { logWarn("MetalFX temporal scaler unavailable; using TAA", "render") }
        return mfxScaler
    }

    // MARK: - GPU timing

    private func track(_ cb: MTLCommandBuffer, _ name: String) {
        cb.label = name
        cb.addCompletedHandler { [weak self] c in
            guard let self = self else { return }
            let ms = (c.gpuEndTime - c.gpuStartTime) * 1000
            self.statsLock.lock()
            if self.gpuTimes[name] == nil { self.gpuOrder.append(name) }
            self.gpuTimes[name] = (self.gpuTimes[name] ?? ms) * 0.9 + ms * 0.1
            self.statsLock.unlock()
        }
    }

    // MARK: - Prepared draws

    private struct Prepared {
        var vb: MTLBuffer
        var vbOffset: Int
        var ib: MTLBuffer
        var ibOffset: Int
        var indexCount: Int
        var inst: MTLBuffer
        var instOffset: Int
        var instanceCount: Int
        var mats: MTLBuffer
        var matsOffset: Int
        var palette: (MTLBuffer, Int)?
        var prevPalette: (MTLBuffer, Int)?
        var castShadow: Bool
        var ghost: Bool
        var doubleSided: Bool
        var visible: Bool
    }

    private func prepare(_ f: RenderFrame, ring: UploadRing, planes: [Vec4]) -> [Prepared] {
        var out: [Prepared] = []
        out.reserveCapacity(f.draws.count)
        var palettes: [Int: (MTLBuffer, Int)] = [:]
        var prevPalettes: [Int: (MTLBuffer, Int)] = [:]
        let defaultMat = MaterialDesc()
        for d in f.draws where !d.instances.isEmpty {
            let vbPair: (MTLBuffer, Int)
            let ibPair: (MTLBuffer, Int)
            let count: Int
            if d.dynamic {
                guard !d.mesh.vertices.isEmpty, !d.mesh.indices.isEmpty else { continue }
                vbPair = ring.push(d.mesh.vertices)
                ibPair = ring.push(d.mesh.indices)
                count = d.mesh.indices.count
            } else {
                guard let e = meshes.get(d.mesh, frame: frameCounter) else { continue }
                vbPair = (e.vertices, 0)
                ibPair = (e.indices, 0)
                count = e.indexCount
            }
            // Visibility: union of instance bounding spheres against the camera frustum.
            var visible = false
            for inst in d.instances {
                let (c, r) = RenderMath.boundingSphere(center: d.mesh.center, radius: d.mesh.boundingRadius * (d.skin != nil ? 1.6 : 1) + 0.1,
                                                       model: inst.model)
                if RenderMath.sphereVisible(planes, center: c, radius: r) { visible = true; break }
            }
            if !visible && !d.castShadow { continue }
            let (ibuf, ioff) = ring.push(d.instances)
            var packed: [Vec4] = []
            packed.reserveCapacity(32)
            for i in 0..<8 { packed += (i < d.materials.count ? d.materials[i] : (d.materials.last ?? defaultMat)).packed }
            let (mbuf, moff) = ring.push(packed)
            var pal: (MTLBuffer, Int)?
            var prevPal: (MTLBuffer, Int)?
            if let s = d.skin, s < f.skinPalettes.count, !f.skinPalettes[s].isEmpty {
                if palettes[s] == nil { palettes[s] = ring.push(f.skinPalettes[s]) }
                if prevPalettes[s] == nil {
                    let prev = s < f.prevSkinPalettes.count && f.prevSkinPalettes[s].count == f.skinPalettes[s].count ? f.prevSkinPalettes[s] : f.skinPalettes[s]
                    prevPalettes[s] = ring.push(prev)
                }
                pal = palettes[s]
                prevPal = prevPalettes[s]
            }
            out.append(Prepared(vb: vbPair.0, vbOffset: vbPair.1, ib: ibPair.0, ibOffset: ibPair.1, indexCount: count, inst: ibuf, instOffset: ioff,
                                instanceCount: d.instances.count, mats: mbuf, matsOffset: moff, palette: pal, prevPalette: prevPal,
                                castShadow: d.castShadow && d.layer == .opaque, ghost: d.layer == .ghost, doubleSided: d.doubleSided,
                                visible: visible))
        }
        return out
    }

    private func bindMesh(_ enc: MTLRenderCommandEncoder, _ d: Prepared, _ u: (MTLBuffer, Int)) {
        enc.setVertexBuffer(d.vb, offset: d.vbOffset, index: 0)
        enc.setVertexBuffer(d.inst, offset: d.instOffset, index: 1)
        enc.setVertexBuffer(u.0, offset: u.1, index: 2)
        if let p = d.palette, let pp = d.prevPalette {
            enc.setVertexBuffer(p.0, offset: p.1, index: 3)
            enc.setVertexBuffer(pp.0, offset: pp.1, index: 4)
        }
    }

    private func drawMesh(_ enc: MTLRenderCommandEncoder, _ d: Prepared) {
        enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32, indexBuffer: d.ib,
                                  indexBufferOffset: d.ibOffset, instanceCount: d.instanceCount)
    }

    // MARK: - Frame

    func render(_ f: RenderFrame, view: MTKView) {
        _ = inFlight.wait(timeout: .distantFuture)
        frameCounter += 1
        let ring = rings[frameCounter % rings.count]
        ring.reset()
        if shaders.poll(dt: Double(max(f.dt, 1.0 / 120))) || shaders.version != pipelinesVersion {
            rebuildPipelinesIfNeeded()
        }
        meshes.evict(frame: frameCounter)
        let P = pipelines
        let s = f.settings

        // Sizes.
        let outW = max(1, Int(view.drawableSize.width)), outH = max(1, Int(view.drawableSize.height))
        let wantMFX = s.metalFX && MTLFXTemporalScalerDescriptor.supportsDevice(device)
        let scale = clampf(s.resolutionScale, wantMFX ? 0.5 : 0.5, 1)
        let renderW = max(64, Int(Float(outW) * scale)), renderH = max(64, Int(Float(outH) * scale))
        ensureTargets(renderW: renderW, renderH: renderH, outW: outW, outH: outH, metalFX: wantMFX)
        ensureShadowMap(max(512, s.shadowSize))
        guard let T = targets, let setupCB = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        track(setupCB, "Setup")
        ensureParticles(s.particleBudget, cb: setupCB)
        let scaler: MTLFXTemporalScaler? = wantMFX ? ensureMetalFX(T) : nil
        let temporal = scaler != nil || (s.taa && P.taa != nil)

        // Camera + jitter.
        let jitterPx = temporal ? RenderMath.jitter(frame: frameCounter) : Vec2.zero
        let projJ = RenderMath.jittered(f.proj, pixels: jitterPx, width: Float(renderW), height: Float(renderH))
        let vpNoJ = f.proj * f.view
        let vpJ = projJ * f.view
        let cut = f.cameraCut || !historyValid
        if cut {
            prevViewProj = vpJ
            prevViewProjNoJitter = vpNoJ
        }
        let planes = RenderMath.frustumPlanes(vpNoJ)
        let cascades = RenderMath.cascades(view: f.view, proj: f.proj, near: f.near, splits: Renderer.cascadeSplits,
                                           sunDir: f.env.sunDirection, shadowSize: shadowSize)
        let lightCount = min(f.lights.count, Renderer.maxLights)
        let doShadows = s.shadows && P.shadowStatic != nil
        let doSSAO = s.ssao && P.ssao != nil && P.ssaoBlur != nil
        let doSSR = s.ssr && P.ssr != nil && historyValid
        let doVolumetric = s.volumetrics && P.volumetric != nil

        var U = FrameUniformsGPU()
        U.view = f.view
        U.proj = projJ
        U.viewProj = vpJ
        U.invViewProj = vpJ.inverse
        U.prevViewProj = prevViewProj
        U.invProj = projJ.inverse
        U.viewProjNoJitter = vpNoJ
        U.prevViewProjNoJitter = prevViewProjNoJitter
        U.invView = f.view.inverse
        U.shadowViewProj = (cascades.viewProj[0], cascades.viewProj[1], cascades.viewProj[2])
        U.cameraPos = Vec4(f.cameraPosition, f.time)
        U.sunDir = Vec4(vnormalize(f.env.sunDirection), f.env.sunIntensity)
        U.sunColor = Vec4(f.env.sunColor, f.env.ambientIntensity)
        U.fogColor = Vec4(f.env.fogColor, f.env.fogDensity)
        U.fogParams = Vec4(f.env.fogHeight, f.env.fogScatter, f.env.wetness, f.env.lightning)
        U.rimColor = Vec4(f.env.rimColor, f.env.rimIntensity)
        U.setSH(f.env.sh)
        U.cascadeSplits = Vec4(Renderer.cascadeSplits[0], Renderer.cascadeSplits[1], Renderer.cascadeSplits[2], 0)
        U.screen = Vec4(Float(renderW), Float(renderH), 1 / Float(renderW), 1 / Float(renderH))
        U.jitter = Vec4(jitterPx.x, jitterPx.y, 0, 0)
        U.flags = Vec4(doSSAO ? 1 : 0, s.contactShadows ? 1 : 0, doShadows ? 1 : 0, Float(frameCounter % 1024))
        U.tileInfo = Vec4(Float(T.tilesX), Float(T.tilesY), Float(P.cullLights != nil ? lightCount : 0), f.near)
        U.floorColor2 = Vec4(f.env.floorMaterial.emissive, f.env.floorMaterial.runes)
        U.misc = Vec4(f.far, f.post.exposure, doSSR ? 1 : 0, doVolumetric ? 1 : 0)
        U.shadowInfo = Vec4(cascades.texelWorld[0], 0.0006, 3, 0)
        U.sky = f.env.sky
        let uni = ring.push(value: U)

        let lightsData: [PointLightGPU] = lightCount > 0 ? Array(f.lights.prefix(lightCount)) : [PointLightGPU(position: .zero, radius: 0, color: .zero, intensity: 0)]
        let lights = ring.push(lightsData)
        let draws = prepare(f, ring: ring, planes: planes)

        var stats = RenderStats()
        stats.renderSize = Vec2(Float(renderW), Float(renderH))

        // ---- Setup: sky cube + particles.
        if let cube = skyCube, let skyP = P.skyCube, f.skyVersion != skyBakedVersion || abs(f.time - skyBakedTime) > 2 {
            if let enc = setupCB.makeComputeCommandEncoder() {
                enc.setComputePipelineState(skyP)
                enc.setTexture(cube, index: 0)
                enc.setTexture(detailA, index: 1)
                enc.setBuffer(uni.0, offset: uni.1, index: 0)
                enc.dispatchThreads(MTLSize(width: cube.width, height: cube.height, depth: 6), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                enc.endEncoding()
            }
            if let blit = setupCB.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: cube)
                blit.endEncoding()
            }
            skyBakedVersion = f.skyVersion
            skyBakedTime = f.time
        }
        if let pool = particlePool, let spawnP = P.particleSpawn, let updateP = P.particleUpdate,
           let enc = setupCB.makeComputeCommandEncoder() {
            let spawns = f.particleSpawns.count > particleCapacity ? Array(f.particleSpawns.suffix(particleCapacity)) : f.particleSpawns
            if !spawns.isEmpty {
                let sb = ring.push(spawns)
                var params = SIMD4<UInt32>(UInt32(spawns.count), UInt32(particleHead), UInt32(particleCapacity), 0)
                enc.setComputePipelineState(spawnP)
                enc.setBuffer(pool, offset: 0, index: 0)
                enc.setBuffer(sb.0, offset: sb.1, index: 1)
                enc.setBytes(&params, length: MemoryLayout<SIMD4<UInt32>>.size, index: 2)
                enc.dispatchThreads(MTLSize(width: spawns.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                particleHead = (particleHead + spawns.count) % particleCapacity
            }
            var sim = Vec4(min(f.dt, 0.1), f.time, 0, Float(particleCapacity))
            enc.setComputePipelineState(updateP)
            enc.setBuffer(pool, offset: 0, index: 0)
            enc.setBytes(&sim, length: MemoryLayout<Vec4>.size, index: 1)
            enc.dispatchThreads(MTLSize(width: particleCapacity, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
            stats.particles = particleCapacity
        }
        setupCB.commit()

        // ---- Shadows.
        if doShadows, let sm = shadowMap, let cb = queue.makeCommandBuffer() {
            track(cb, "Shadows")
            for cascade in 0..<3 {
                let rpd = MTLRenderPassDescriptor()
                rpd.depthAttachment.texture = sm
                rpd.depthAttachment.slice = cascade
                rpd.depthAttachment.loadAction = .clear
                rpd.depthAttachment.clearDepth = 1
                rpd.depthAttachment.storeAction = .store
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
                enc.label = "Cascade\(cascade)"
                enc.setDepthStencilState(dsWrite)
                enc.setCullMode(.none)
                enc.setDepthBias(2, slopeScale: 2.5, clamp: 0.01)
                var c = UInt32(cascade)
                enc.setVertexBytes(&c, length: 4, index: 5)
                for d in draws where d.castShadow {
                    guard let pso = d.palette != nil ? P.shadowSkinned : P.shadowStatic else { continue }
                    enc.setRenderPipelineState(pso)
                    bindMesh(enc, d, uni)
                    drawMesh(enc, d)
                    stats.drawCalls += 1
                }
                enc.endEncoding()
            }
            cb.commit()
        }

        // ---- Prepass + light culling + SSAO.
        guard let prepCB = queue.makeCommandBuffer() else { inFlight.signal(); return }
        track(prepCB, "Prepass")
        do {
            let rpd = MTLRenderPassDescriptor()
            let clears: [(MTLTexture, MTLClearColor)] = [(T.normalRough, MTLClearColorMake(0, 0, 1, 1)), (T.velocity, MTLClearColorMake(0, 0, 0, 0)),
                                                         (T.linearDepth, MTLClearColorMake(1000, 0, 0, 0)), (T.objVelocity, MTLClearColorMake(0, 0, 0, 0))]
            for (i, c) in clears.enumerated() {
                rpd.colorAttachments[i].texture = c.0
                rpd.colorAttachments[i].loadAction = .clear
                rpd.colorAttachments[i].clearColor = c.1
                rpd.colorAttachments[i].storeAction = .store
            }
            rpd.depthAttachment.texture = T.depth
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1
            rpd.depthAttachment.storeAction = .store
            if let enc = prepCB.makeRenderCommandEncoder(descriptor: rpd) {
                enc.label = "Prepass"
                enc.setDepthStencilState(dsWrite)
                enc.setFrontFacing(.counterClockwise)
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                for d in draws where d.visible && !d.ghost {
                    guard let pso = d.palette != nil ? P.prepassSkinned : P.prepassStatic else { continue }
                    enc.setRenderPipelineState(pso)
                    enc.setCullMode(d.doubleSided ? .none : .back)
                    bindMesh(enc, d, uni)
                    enc.setFragmentBuffer(d.mats, offset: d.matsOffset, index: 1)
                    enc.setFragmentBuffer(d.inst, offset: d.instOffset, index: 2)
                    drawMesh(enc, d)
                    stats.drawCalls += 1
                    stats.triangles += d.indexCount / 3 * d.instanceCount
                }
                enc.endEncoding()
            }
        }
        if let cull = P.cullLights, let enc = prepCB.makeComputeCommandEncoder() {
            enc.setComputePipelineState(cull)
            enc.setBuffer(uni.0, offset: uni.1, index: 0)
            enc.setBuffer(lights.0, offset: lights.1, index: 1)
            enc.setBuffer(T.tiles, offset: 0, index: 2)
            enc.setTexture(T.linearDepth, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: T.tilesX, height: T.tilesY, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        } else if let blit = prepCB.makeBlitCommandEncoder() {
            blit.fill(buffer: T.tiles, range: 0..<T.tiles.length, value: 0)
            blit.endEncoding()
        }
        if doSSAO, let ssaoP = P.ssao, let blurP = P.ssaoBlur {
            fullscreen(prepCB, "SSAO", target: T.ao, pso: ssaoP) { enc in
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                enc.setFragmentTexture(T.normalRough, index: 0)
                enc.setFragmentTexture(T.linearDepth, index: 1)
            }
            let texel = Vec2(1 / Float(T.ao.width), 1 / Float(T.ao.height))
            for (src, dst, dir) in [(T.ao, T.aoTemp, Vec2(texel.x, 0)), (T.aoTemp, T.ao, Vec2(0, texel.y))] {
                fullscreen(prepCB, "SSAOBlur", target: dst, pso: blurP) { enc in
                    var p = Vec4(dir.x, dir.y, 12, 0)
                    enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                    enc.setFragmentBytes(&p, length: MemoryLayout<Vec4>.size, index: 1)
                    enc.setFragmentTexture(src, index: 0)
                    enc.setFragmentTexture(T.linearDepth, index: 1)
                }
            }
        }
        prepCB.commit()

        // ---- Opaque: forward+ shading, sky, decals.
        guard let opaqueCB = queue.makeCommandBuffer() else { inFlight.signal(); return }
        track(opaqueCB, "Opaque")
        do {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = T.hdr
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[1].texture = T.velocity
            rpd.colorAttachments[1].loadAction = .load
            rpd.colorAttachments[1].storeAction = .store
            rpd.depthAttachment.texture = T.depth
            rpd.depthAttachment.loadAction = .load
            rpd.depthAttachment.storeAction = .store
            if let enc = opaqueCB.makeRenderCommandEncoder(descriptor: rpd) {
                enc.label = "Forward+"
                enc.setDepthStencilState(dsTest)
                enc.setFrontFacing(.counterClockwise)
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                enc.setFragmentBuffer(lights.0, offset: lights.1, index: 2)
                enc.setFragmentBuffer(T.tiles, offset: 0, index: 3)
                enc.setFragmentTexture(detailA, index: 0)
                enc.setFragmentTexture(detailN, index: 1)
                enc.setFragmentTexture(shadowMap, index: 2)
                enc.setFragmentTexture(skyCube, index: 3)
                enc.setFragmentTexture(T.ao, index: 4)
                enc.setFragmentTexture(T.linearDepth, index: 5)
                for d in draws where d.visible && !d.ghost {
                    guard let pso = d.palette != nil ? P.mainSkinned : P.mainStatic else { continue }
                    enc.setRenderPipelineState(pso)
                    enc.setCullMode(d.doubleSided ? .none : .back)
                    bindMesh(enc, d, uni)
                    enc.setFragmentBuffer(d.mats, offset: d.matsOffset, index: 1)
                    enc.setFragmentBuffer(d.inst, offset: d.instOffset, index: 4)
                    drawMesh(enc, d)
                    stats.drawCalls += 1
                }
                if let skyP = P.sky {
                    enc.setRenderPipelineState(skyP)
                    enc.setCullMode(.none)
                    enc.setFragmentTexture(detailA, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    stats.drawCalls += 1
                }
                if !f.decals.isEmpty, let decalP = P.decal {
                    let db = ring.push(f.decals)
                    enc.setRenderPipelineState(decalP)
                    enc.setDepthStencilState(dsAlways)
                    enc.setCullMode(.front)
                    enc.setVertexBuffer(db.0, offset: db.1, index: 0)
                    enc.setVertexBuffer(uni.0, offset: uni.1, index: 1)
                    enc.setFragmentBuffer(db.0, offset: db.1, index: 1)
                    enc.setFragmentTexture(T.normalRough, index: 0)
                    enc.setFragmentTexture(T.linearDepth, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: f.decals.count)
                    stats.drawCalls += 1
                }
                enc.endEncoding()
            }
        }
        opaqueCB.commit()

        // ---- Effects: volumetric fog, SSR, fog composite.
        if let fxCB = queue.makeCommandBuffer() {
            track(fxCB, "Fog+SSR")
            if doVolumetric, let volP = P.volumetric {
                fullscreen(fxCB, "Volumetric", target: T.volumetric, pso: volP) { enc in
                    enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                    enc.setFragmentTexture(T.linearDepth, index: 0)
                    enc.setFragmentTexture(shadowMap, index: 1)
                }
            }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = T.hdr
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            if let enc = fxCB.makeRenderCommandEncoder(descriptor: rpd) {
                enc.label = "SSR+Fog"
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                if doSSR, let ssrP = P.ssr {
                    enc.setRenderPipelineState(ssrP)
                    enc.setFragmentTexture(T.normalRough, index: 0)
                    enc.setFragmentTexture(T.linearDepth, index: 1)
                    enc.setFragmentTexture(T.history[1 - historyIndex], index: 2)
                    enc.setFragmentTexture(T.velocity, index: 3)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                if let fogP = P.fogApply, f.env.fogDensity > 0 {
                    enc.setRenderPipelineState(fogP)
                    enc.setFragmentTexture(T.volumetric, index: 0)
                    enc.setFragmentTexture(T.linearDepth, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                enc.endEncoding()
            }
            fxCB.commit()
        }

        // ---- Transparent: afterimages, trails, particles.
        if let trCB = queue.makeCommandBuffer() {
            track(trCB, "Transparent")
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = T.hdr
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = T.depth
            rpd.depthAttachment.loadAction = .load
            rpd.depthAttachment.storeAction = .store
            if let enc = trCB.makeRenderCommandEncoder(descriptor: rpd) {
                enc.label = "Transparent"
                enc.setDepthStencilState(dsTest)
                enc.setFrontFacing(.counterClockwise)
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                for d in draws where d.visible && d.ghost {
                    guard let pso = d.palette != nil ? P.ghostSkinned : P.ghostStatic else { continue }
                    enc.setRenderPipelineState(pso)
                    enc.setCullMode(.back)
                    bindMesh(enc, d, uni)
                    enc.setFragmentBuffer(d.inst, offset: d.instOffset, index: 4)
                    drawMesh(enc, d)
                    stats.drawCalls += 1
                }
                if !f.trailIndices.isEmpty, !f.trailVertices.isEmpty, let trailP = P.trail {
                    let vb = ring.push(f.trailVertices)
                    let ib = ring.push(f.trailIndices)
                    enc.setRenderPipelineState(trailP)
                    enc.setCullMode(.none)
                    enc.setVertexBuffer(vb.0, offset: vb.1, index: 0)
                    enc.setVertexBuffer(uni.0, offset: uni.1, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: f.trailIndices.count, indexType: .uint32, indexBuffer: ib.0, indexBufferOffset: ib.1)
                    stats.drawCalls += 1
                }
                if let pool = particlePool, let partP = P.particle {
                    enc.setRenderPipelineState(partP)
                    enc.setCullMode(.none)
                    enc.setVertexBuffer(pool, offset: 0, index: 0)
                    enc.setVertexBuffer(uni.0, offset: uni.1, index: 1)
                    enc.setFragmentTexture(T.linearDepth, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: particleCapacity)
                    stats.drawCalls += 1
                }
                enc.endEncoding()
            }
            trCB.commit()
        }

        // ---- Resolve (TAA / MetalFX).
        guard let postCB = queue.makeCommandBuffer() else { inFlight.signal(); return }
        track(postCB, "Resolve+Post")
        let histOut = T.history[historyIndex]
        let histPrev = T.history[1 - historyIndex]
        if let mfx = scaler {
            mfx.colorTexture = T.hdr
            mfx.depthTexture = T.depth
            mfx.motionTexture = T.velocity
            mfx.outputTexture = histOut
            mfx.inputContentWidth = renderW
            mfx.inputContentHeight = renderH
            mfx.jitterOffsetX = jitterPx.x
            mfx.jitterOffsetY = jitterPx.y
            mfx.motionVectorScaleX = Float(renderW)
            mfx.motionVectorScaleY = Float(renderH)
            mfx.reset = cut
            mfx.isDepthReversed = false
            mfx.encode(commandBuffer: postCB)
        } else if temporal, let taaP = P.taa {
            fullscreen(postCB, "TAA", target: histOut, pso: taaP) { enc in
                var p = Vec4(cut ? 1 : 0, 0.1, 0.22, 0)
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                enc.setFragmentBytes(&p, length: MemoryLayout<Vec4>.size, index: 1)
                enc.setFragmentTexture(T.hdr, index: 0)
                enc.setFragmentTexture(histPrev, index: 1)
                enc.setFragmentTexture(T.velocity, index: 2)
                enc.setFragmentTexture(T.linearDepth, index: 3)
            }
        } else if let blit = postCB.makeBlitCommandEncoder() {
            blit.copy(from: T.hdr, to: histOut)
            blit.endEncoding()
        }
        var current = histOut

        // ---- Post: motion blur, DoF, bloom.
        if s.motionBlur, f.post.motionBlur > 0, let mbP = P.motionBlur {
            let dst = T.postA
            let src = current
            fullscreen(postCB, "MotionBlur", target: dst, pso: mbP) { enc in
                var p = Vec4(f.post.motionBlur, 0.2, 28 * Float(renderH) / 1080, 0)
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                enc.setFragmentBytes(&p, length: MemoryLayout<Vec4>.size, index: 1)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentTexture(T.velocity, index: 1)
                enc.setFragmentTexture(T.objVelocity, index: 2)
                enc.setFragmentTexture(T.linearDepth, index: 3)
            }
            current = dst
        }
        if s.dof, f.post.dofStrength > 0.01, let dofP = P.dof {
            let dst = current === T.postA ? T.postB : T.postA
            let src = current
            fullscreen(postCB, "DoF", target: dst, pso: dofP) { enc in
                var p = Vec4(f.post.dofFocus, f.post.dofRange, f.post.dofStrength, 10 * Float(T.resolveH) / 1080)
                enc.setFragmentBuffer(uni.0, offset: uni.1, index: 0)
                enc.setFragmentBytes(&p, length: MemoryLayout<Vec4>.size, index: 1)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentTexture(T.linearDepth, index: 1)
            }
            current = dst
        }
        let bloomOn = s.bloom && f.post.bloomStrength > 0 && !T.bloom.isEmpty && P.bloomPrefilter != nil && P.bloomDown != nil && P.bloomUp != nil
        if bloomOn, let pre = P.bloomPrefilter, let down = P.bloomDown, let up = P.bloomUp {
            let src0 = current
            fullscreen(postCB, "BloomPrefilter", target: T.bloom[0], pso: pre) { enc in
                var p = Vec4(f.post.bloomThreshold, 0.5, 1 / Float(src0.width), 1 / Float(src0.height))
                enc.setFragmentBytes(&p, length: MemoryLayout<Vec4>.size, index: 0)
                enc.setFragmentTexture(src0, index: 0)
            }
            for i in 1..<T.bloom.count {
                let src = T.bloom[i - 1]
                fullscreen(postCB, "BloomDown\(i)", target: T.bloom[i], pso: down) { enc in
                    var p = Vec4(0, 0, 1 / Float(src.width), 1 / Float(src.height))
                    enc.setFragmentBytes(&p, length: MemoryLayout<Vec4>.size, index: 0)
                    enc.setFragmentTexture(src, index: 0)
                }
            }
            for i in stride(from: T.bloom.count - 1, to: 0, by: -1) {
                let src = T.bloom[i]
                fullscreen(postCB, "BloomUp\(i)", target: T.bloom[i - 1], pso: up, load: true) { enc in
                    var p = Vec4(1, 1, 1 / Float(src.width), 1 / Float(src.height))
                    enc.setFragmentBytes(&p, length: MemoryLayout<Vec4>.size, index: 0)
                    enc.setFragmentTexture(src, index: 0)
                }
            }
        } else if let first = T.bloom.first {
            fullscreenClear(postCB, first)
        }

        // ---- Composite + debug lines + UI to the drawable.
        if let drawable = view.currentDrawable {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            if let enc = postCB.makeRenderCommandEncoder(descriptor: rpd) {
                enc.label = "Composite+UI"
                if let compP = P.composite {
                    var post = PostGPU(f.post, time: f.time, sharpen: scaler != nil ? 0.25 : (temporal ? 0.4 : 0.1),
                                       outputSize: Vec2(Float(outW), Float(outH)))
                    enc.setRenderPipelineState(compP)
                    enc.setFragmentBytes(&post, length: MemoryLayout<PostGPU>.size, index: 0)
                    enc.setFragmentTexture(current, index: 0)
                    enc.setFragmentTexture(T.bloom.first ?? current, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                if !f.debugLines.isEmpty, let lineP = P.line {
                    var verts: [Vec4] = []
                    verts.reserveCapacity(f.debugLines.count * 4)
                    for l in f.debugLines { verts += [Vec4(l.a, 1), l.color, Vec4(l.b, 1), l.color] }
                    let lb = ring.push(verts)
                    enc.setRenderPipelineState(lineP)
                    enc.setVertexBuffer(lb.0, offset: lb.1, index: 0)
                    enc.setVertexBuffer(uni.0, offset: uni.1, index: 1)
                    enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: f.debugLines.count * 2)
                }
                if let uiP = P.ui, let atlas = font.texture {
                    var quads: [UIQuadGPU] = []
                    quads.reserveCapacity(f.ui.items.count * 4)
                    for item in f.ui.items {
                        switch item {
                        case .quad(let q): quads.append(q)
                        case .text(let t): font.append(t, to: &quads)
                        }
                    }
                    if !quads.isEmpty {
                        let qb = ring.push(quads)
                        var vp = Vec4(Float(outW), Float(outH), 0, 0)
                        enc.setRenderPipelineState(uiP)
                        enc.setVertexBuffer(qb.0, offset: qb.1, index: 0)
                        enc.setVertexBytes(&vp, length: MemoryLayout<Vec4>.size, index: 1)
                        enc.setFragmentTexture(atlas, index: 0)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
                    }
                }
                enc.endEncoding()
            }
            if screenshotPending {
                screenshotPending = false
                encodeScreenshot(postCB, drawable.texture)
            }
            postCB.present(drawable)
        }
        postCB.addCompletedHandler { [weak self] _ in self?.inFlight.signal() }
        postCB.commit()

        // History bookkeeping for the next frame.
        historyIndex = 1 - historyIndex
        historyValid = true
        prevViewProj = vpJ
        prevViewProjNoJitter = vpNoJ

        statsLock.lock()
        stats.gpuPasses = gpuOrder.map { ($0, gpuTimes[$0] ?? 0) }
        statsLock.unlock()
        stats.gpuTotal = stats.gpuPasses.reduce(0) { $0 + $1.1 }
        self.stats = stats
    }

    // MARK: - Helpers

    private func fullscreen(_ cb: MTLCommandBuffer, _ label: String, target: MTLTexture, pso: MTLRenderPipelineState, load: Bool = false,
                            _ bind: (MTLRenderCommandEncoder) -> Void) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = load ? .load : .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.label = label
        enc.setRenderPipelineState(pso)
        bind(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func fullscreenClear(_ cb: MTLCommandBuffer, _ target: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rpd.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
    }

    private func encodeScreenshot(_ cb: MTLCommandBuffer, _ tex: MTLTexture) {
        let w = tex.width, h = tex.height
        let bpr = w * 4
        guard let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        let bgra = tex.pixelFormat == .bgra8Unorm || tex.pixelFormat == .bgra8Unorm_srgb
        let callback = onScreenshot
        cb.addCompletedHandler { _ in
            DispatchQueue.global(qos: .utility).async {
                var img = ImageRGBA8(width: w, height: h)
                let src = buf.contents().bindMemory(to: UInt8.self, capacity: bpr * h)
                for i in 0..<(w * h) {
                    let o = i * 4
                    img.pixels[o] = src[o + (bgra ? 2 : 0)]
                    img.pixels[o + 1] = src[o + 1]
                    img.pixels[o + 2] = src[o + (bgra ? 0 : 2)]
                    img.pixels[o + 3] = 255
                }
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyyMMdd-HHmmss"
                let url = Paths.desktop.appendingPathComponent("BladeRush-\(fmt.string(from: Date())).png")
                do {
                    try img.writePNG(to: url)
                    logInfo("Screenshot saved to \(url.path)", "render")
                    DispatchQueue.main.async { callback?(url) }
                } catch {
                    logError("Screenshot failed: \(error)", "render")
                    DispatchQueue.main.async { callback?(nil) }
                }
            }
        }
    }
}
