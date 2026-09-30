// Size-dependent GPU resources and the set of pipeline states.
import Foundation
import Metal
import BladeCore

enum Formats {
    static let hdr: MTLPixelFormat = .rgba16Float
    static let normal: MTLPixelFormat = .rgba16Float
    static let velocity: MTLPixelFormat = .rg16Float
    static let linearDepth: MTLPixelFormat = .r32Float
    static let depth: MTLPixelFormat = .depth32Float
    static let ao: MTLPixelFormat = .r8Unorm
    static let bloom: MTLPixelFormat = .rg11b10Float
    static let output: MTLPixelFormat = .bgra8Unorm_srgb
}

/// Render-resolution G-buffer-ish targets plus resolve/post targets.
final class RenderTargets {
    let renderW: Int, renderH: Int
    let outW: Int, outH: Int
    let resolveW: Int, resolveH: Int
    let metalFX: Bool
    let depth: MTLTexture
    let hdr: MTLTexture
    let normalRough: MTLTexture
    let velocity: MTLTexture
    let linearDepth: MTLTexture
    let objVelocity: MTLTexture
    let ao: MTLTexture
    let aoTemp: MTLTexture
    let volumetric: MTLTexture
    let history: [MTLTexture]
    let postA: MTLTexture
    let postB: MTLTexture
    let bloom: [MTLTexture]
    let tiles: MTLBuffer
    let tilesX: Int, tilesY: Int

    init?(device: MTLDevice, renderW: Int, renderH: Int, outW: Int, outH: Int, metalFX: Bool) {
        self.renderW = renderW; self.renderH = renderH
        self.outW = outW; self.outH = outH
        self.metalFX = metalFX
        resolveW = metalFX ? outW : renderW
        resolveH = metalFX ? outH : renderH
        let rt: MTLTextureUsage = [.renderTarget, .shaderRead]
        let hw = max(1, renderW / 2), hh = max(1, renderH / 2)
        guard let depth = TextureFactory.make(device, "Depth", Formats.depth, renderW, renderH, usage: rt),
              let hdr = TextureFactory.make(device, "HDR", Formats.hdr, renderW, renderH, usage: rt),
              let normalRough = TextureFactory.make(device, "NormalRough", Formats.normal, renderW, renderH, usage: rt),
              let velocity = TextureFactory.make(device, "Velocity", Formats.velocity, renderW, renderH, usage: rt),
              let linearDepth = TextureFactory.make(device, "LinearDepth", Formats.linearDepth, renderW, renderH, usage: rt),
              let objVelocity = TextureFactory.make(device, "ObjVelocity", Formats.velocity, renderW, renderH, usage: rt),
              let ao = TextureFactory.make(device, "SSAO", Formats.ao, hw, hh, usage: rt),
              let aoTemp = TextureFactory.make(device, "SSAOTemp", Formats.ao, hw, hh, usage: rt),
              let volumetric = TextureFactory.make(device, "Volumetric", Formats.hdr, hw, hh, usage: rt),
              let h0 = TextureFactory.make(device, "History0", Formats.hdr, resolveW, resolveH, usage: [.renderTarget, .shaderRead, .shaderWrite]),
              let h1 = TextureFactory.make(device, "History1", Formats.hdr, resolveW, resolveH, usage: [.renderTarget, .shaderRead, .shaderWrite]),
              let postA = TextureFactory.make(device, "PostA", Formats.hdr, resolveW, resolveH, usage: rt),
              let postB = TextureFactory.make(device, "PostB", Formats.hdr, resolveW, resolveH, usage: rt)
        else { return nil }
        self.depth = depth; self.hdr = hdr; self.normalRough = normalRough; self.velocity = velocity
        self.linearDepth = linearDepth; self.objVelocity = objVelocity; self.ao = ao; self.aoTemp = aoTemp
        self.volumetric = volumetric; history = [h0, h1]; self.postA = postA; self.postB = postB
        var levels: [MTLTexture] = []
        var bw = max(1, resolveW / 2), bh = max(1, resolveH / 2)
        for i in 0..<6 where bw >= 8 && bh >= 8 {
            guard let t = TextureFactory.make(device, "Bloom\(i)", Formats.bloom, bw, bh, usage: rt) else { break }
            levels.append(t)
            bw /= 2; bh /= 2
        }
        bloom = levels
        tilesX = (renderW + 15) / 16
        tilesY = (renderH + 15) / 16
        guard let tiles = device.makeBuffer(length: tilesX * tilesY * 64 * 4, options: .storageModePrivate) else { return nil }
        tiles.label = "LightTiles"
        self.tiles = tiles
    }

    var memoryMB: Double {
        let px = Double(renderW * renderH)
        return (px * (4 + 8 + 8 + 4 + 4 + 4) + Double(resolveW * resolveH) * 8 * 4) / (1024 * 1024)
    }
}

struct PipelineSet {
    var shadowStatic: MTLRenderPipelineState?
    var shadowSkinned: MTLRenderPipelineState?
    var prepassStatic: MTLRenderPipelineState?
    var prepassSkinned: MTLRenderPipelineState?
    var mainStatic: MTLRenderPipelineState?
    var mainSkinned: MTLRenderPipelineState?
    var ghostStatic: MTLRenderPipelineState?
    var ghostSkinned: MTLRenderPipelineState?
    var sky: MTLRenderPipelineState?
    var decal: MTLRenderPipelineState?
    var ssao: MTLRenderPipelineState?
    var ssaoBlur: MTLRenderPipelineState?
    var volumetric: MTLRenderPipelineState?
    var ssr: MTLRenderPipelineState?
    var fogApply: MTLRenderPipelineState?
    var trail: MTLRenderPipelineState?
    var particle: MTLRenderPipelineState?
    var taa: MTLRenderPipelineState?
    var dof: MTLRenderPipelineState?
    var motionBlur: MTLRenderPipelineState?
    var bloomPrefilter: MTLRenderPipelineState?
    var bloomDown: MTLRenderPipelineState?
    var bloomUp: MTLRenderPipelineState?
    var composite: MTLRenderPipelineState?
    var ui: MTLRenderPipelineState?
    var line: MTLRenderPipelineState?
    var cullLights: MTLComputePipelineState?
    var skyCube: MTLComputePipelineState?
    var particleSpawn: MTLComputePipelineState?
    var particleUpdate: MTLComputePipelineState?

    struct Color {
        var format: MTLPixelFormat
        var blend: BlendMode = .opaque
        var write = true
    }

    static func build(device: MTLDevice, shaders: ShaderLibrary, output: MTLPixelFormat) -> PipelineSet {
        func render(_ label: String, _ file: String, vs: String, fs: String?, colors: [Color], depth: MTLPixelFormat = .invalid) -> MTLRenderPipelineState? {
            guard let v = shaders.function(vs, in: file) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = v
            if let fs = fs {
                guard let f = shaders.function(fs, in: file) else { return nil }
                d.fragmentFunction = f
            }
            for (i, c) in colors.enumerated() {
                d.colorAttachments[i].pixelFormat = c.format
                d.colorAttachments[i].apply(c.blend)
                if !c.write { d.colorAttachments[i].writeMask = [] }
            }
            d.depthAttachmentPixelFormat = depth
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                logError("Pipeline \(label) failed: \(error)", "render")
                return nil
            }
        }
        func compute(_ name: String, _ file: String) -> MTLComputePipelineState? {
            guard let f = shaders.function(name, in: file) else { return nil }
            do { return try device.makeComputePipelineState(function: f) } catch {
                logError("Compute pipeline \(name) failed: \(error)", "render")
                return nil
            }
        }
        let hdr = Color(format: Formats.hdr)
        let velNoWrite = Color(format: Formats.velocity, write: false)
        let prepassColors = [Color(format: Formats.normal), Color(format: Formats.velocity), Color(format: Formats.linearDepth), Color(format: Formats.velocity)]
        var p = PipelineSet()
        p.shadowStatic = render("ShadowStatic", "Mesh", vs: "vs_shadow_static", fs: nil, colors: [], depth: Formats.depth)
        p.shadowSkinned = render("ShadowSkinned", "Mesh", vs: "vs_shadow_skinned", fs: nil, colors: [], depth: Formats.depth)
        p.prepassStatic = render("PrepassStatic", "Mesh", vs: "vs_static", fs: "fs_prepass", colors: prepassColors, depth: Formats.depth)
        p.prepassSkinned = render("PrepassSkinned", "Mesh", vs: "vs_skinned", fs: "fs_prepass", colors: prepassColors, depth: Formats.depth)
        p.mainStatic = render("MainStatic", "Mesh", vs: "vs_static", fs: "fs_main", colors: [hdr, velNoWrite], depth: Formats.depth)
        p.mainSkinned = render("MainSkinned", "Mesh", vs: "vs_skinned", fs: "fs_main", colors: [hdr, velNoWrite], depth: Formats.depth)
        p.ghostStatic = render("GhostStatic", "Mesh", vs: "vs_static", fs: "fs_ghost", colors: [Color(format: Formats.hdr, blend: .additive)], depth: Formats.depth)
        p.ghostSkinned = render("GhostSkinned", "Mesh", vs: "vs_skinned", fs: "fs_ghost", colors: [Color(format: Formats.hdr, blend: .additive)], depth: Formats.depth)
        p.sky = render("Sky", "Sky", vs: "vs_sky", fs: "fs_sky", colors: [hdr, Color(format: Formats.velocity)], depth: Formats.depth)
        p.decal = render("Decal", "Decals", vs: "vs_decal", fs: "fs_decal", colors: [Color(format: Formats.hdr, blend: .premultiplied), velNoWrite], depth: Formats.depth)
        p.ssao = render("SSAO", "SSAO", vs: "vs_fullscreen", fs: "fs_ssao", colors: [Color(format: Formats.ao)])
        p.ssaoBlur = render("SSAOBlur", "SSAO", vs: "vs_fullscreen", fs: "fs_ssao_blur", colors: [Color(format: Formats.ao)])
        p.volumetric = render("Volumetric", "Fog", vs: "vs_fullscreen", fs: "fs_volumetric", colors: [hdr])
        p.fogApply = render("FogApply", "Fog", vs: "vs_fullscreen", fs: "fs_fog_apply", colors: [Color(format: Formats.hdr, blend: .fog)])
        p.ssr = render("SSR", "SSR", vs: "vs_fullscreen", fs: "fs_ssr", colors: [Color(format: Formats.hdr, blend: .additive)])
        p.trail = render("Trail", "Trails", vs: "vs_trail", fs: "fs_trail", colors: [Color(format: Formats.hdr, blend: .premultiplied)], depth: Formats.depth)
        p.particle = render("Particle", "Particles", vs: "vs_particle", fs: "fs_particle", colors: [Color(format: Formats.hdr, blend: .premultiplied)], depth: Formats.depth)
        p.taa = render("TAA", "TAA", vs: "vs_fullscreen", fs: "fs_taa", colors: [hdr])
        p.dof = render("DoF", "Post", vs: "vs_fullscreen", fs: "fs_dof", colors: [hdr])
        p.motionBlur = render("MotionBlur", "Post", vs: "vs_fullscreen", fs: "fs_motion_blur", colors: [hdr])
        p.bloomPrefilter = render("BloomPrefilter", "Post", vs: "vs_fullscreen", fs: "fs_bloom_prefilter", colors: [Color(format: Formats.bloom)])
        p.bloomDown = render("BloomDown", "Post", vs: "vs_fullscreen", fs: "fs_bloom_down", colors: [Color(format: Formats.bloom)])
        p.bloomUp = render("BloomUp", "Post", vs: "vs_fullscreen", fs: "fs_bloom_up", colors: [Color(format: Formats.bloom, blend: .additive)])
        p.composite = render("Composite", "Post", vs: "vs_fullscreen", fs: "fs_composite", colors: [Color(format: output)])
        p.ui = render("UI", "UI", vs: "vs_ui", fs: "fs_ui", colors: [Color(format: output, blend: .premultiplied)])
        p.line = render("DebugLines", "UI", vs: "vs_line", fs: "fs_line", colors: [Color(format: output, blend: .premultiplied)])
        p.cullLights = compute("cull_lights", "Lighting")
        p.skyCube = compute("sky_cube", "Sky")
        p.particleSpawn = compute("particle_spawn", "Particles")
        p.particleUpdate = compute("particle_update", "Particles")
        return p
    }

    /// Names of pipelines that failed (shown in the debug overlay / log).
    var missing: [String] {
        let m = Mirror(reflecting: self)
        return m.children.compactMap { c in
            let isNil: Bool
            if let o = c.value as? MTLRenderPipelineState? { isNil = o == nil }
            else if let o = c.value as? MTLComputePipelineState? { isNil = o == nil }
            else { isNil = false }
            return isNil ? c.label : nil
        }
    }
}
