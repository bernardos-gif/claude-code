// Swift mirrors of the shader-side structs in Common.metal / Post.metal. Every field is a
// 16-byte aligned SIMD vector or matrix, so Swift's declaration-order layout matches MSL.
import Metal
import BladeCore

typealias Mat4x3 = (Mat4, Mat4, Mat4)
typealias Vec4x9 = (Vec4, Vec4, Vec4, Vec4, Vec4, Vec4, Vec4, Vec4, Vec4)

/// Mirrors `struct FrameUniforms` (1248 bytes).
struct FrameUniformsGPU {
    var view = Mat4.identity
    var proj = Mat4.identity
    var viewProj = Mat4.identity
    var invViewProj = Mat4.identity
    var prevViewProj = Mat4.identity
    var invProj = Mat4.identity
    var viewProjNoJitter = Mat4.identity
    var prevViewProjNoJitter = Mat4.identity
    var invView = Mat4.identity
    var shadowViewProj: Mat4x3 = (.identity, .identity, .identity)
    var cameraPos = Vec4.zero
    var sunDir = Vec4.zero
    var sunColor = Vec4.zero
    var fogColor = Vec4.zero
    var fogParams = Vec4.zero
    var rimColor = Vec4.zero
    var sh: Vec4x9 = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var cascadeSplits = Vec4.zero
    var screen = Vec4.zero
    var jitter = Vec4.zero
    var flags = Vec4.zero
    var tileInfo = Vec4.zero
    var floorColor2 = Vec4.zero
    var misc = Vec4.zero
    var shadowInfo = Vec4.zero
    var sky = SkyParams()

    static let expectedSize = 1248

    mutating func setSH(_ c: [Vec4]) {
        func at(_ i: Int) -> Vec4 { i < c.count ? c[i] : .zero }
        sh = (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7), at(8))
    }
}

/// Mirrors `struct PostGPU` in Post.metal (128 bytes).
struct PostGPU {
    var grade = Vec4.zero        // exposure, contrast, saturation, split strength
    var tint = Vec4.zero         // rgb, vignette
    var shadows = Vec4.zero      // rgb lift, grain
    var highlights = Vec4.zero   // rgb gain, chromatic aberration
    var radial = Vec4.zero       // center xy, radial blur, bloom strength
    var flash = Vec4.zero
    var effects = Vec4.zero      // desaturate, low health, slow motion, letterbox
    var misc = Vec4.zero         // time, sharpen, output width, output height

    init() {}

    init(_ p: PostParams, time: Float, sharpen: Float, outputSize: Vec2) {
        grade = Vec4(p.exposure, p.contrast, p.saturation, p.splitStrength)
        tint = Vec4(p.tint, p.vignette)
        shadows = Vec4(p.shadows, p.grain)
        highlights = Vec4(p.highlights, p.chromatic)
        radial = Vec4(p.radialCenter.x, p.radialCenter.y, p.radialBlur, p.bloomStrength)
        flash = p.flash
        effects = Vec4(p.desaturate, p.lowHealth, p.slowmo, p.letterbox)
        misc = Vec4(time, sharpen, outputSize.x, outputSize.y)
    }
}

/// Blend configurations used by the pipelines.
enum BlendMode {
    case opaque
    case premultiplied     // src one, dst 1 - src alpha (additive when alpha = 0)
    case additive          // one, one
    case fog               // dst = src + dst * src alpha (transmittance)
    case alpha             // straight alpha
}

extension MTLRenderPipelineColorAttachmentDescriptor {
    func apply(_ mode: BlendMode) {
        switch mode {
        case .opaque:
            isBlendingEnabled = false
        case .premultiplied:
            isBlendingEnabled = true
            rgbBlendOperation = .add; alphaBlendOperation = .add
            sourceRGBBlendFactor = .one; sourceAlphaBlendFactor = .one
            destinationRGBBlendFactor = .oneMinusSourceAlpha; destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            isBlendingEnabled = true
            rgbBlendOperation = .add; alphaBlendOperation = .add
            sourceRGBBlendFactor = .one; sourceAlphaBlendFactor = .one
            destinationRGBBlendFactor = .one; destinationAlphaBlendFactor = .one
        case .fog:
            isBlendingEnabled = true
            rgbBlendOperation = .add; alphaBlendOperation = .add
            sourceRGBBlendFactor = .one; sourceAlphaBlendFactor = .zero
            destinationRGBBlendFactor = .sourceAlpha; destinationAlphaBlendFactor = .one
        case .alpha:
            isBlendingEnabled = true
            rgbBlendOperation = .add; alphaBlendOperation = .add
            sourceRGBBlendFactor = .sourceAlpha; sourceAlphaBlendFactor = .one
            destinationRGBBlendFactor = .oneMinusSourceAlpha; destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
    }
}

enum TextureFactory {
    static func make(_ device: MTLDevice, _ label: String, _ format: MTLPixelFormat, _ w: Int, _ h: Int,
                     usage: MTLTextureUsage = [.renderTarget, .shaderRead], mips: Bool = false,
                     storage: MTLStorageMode = .private) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: mips)
        d.usage = usage
        d.storageMode = storage
        let t = device.makeTexture(descriptor: d)
        t?.label = label
        return t
    }

    /// RGBA8 texture filled from CPU pixels (with a full mip chain generated on the GPU).
    static func upload(_ device: MTLDevice, queue: MTLCommandQueue, _ label: String, width: Int, height: Int, rgba: [UInt8]) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = label
        rgba.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
            }
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return t
    }
}
