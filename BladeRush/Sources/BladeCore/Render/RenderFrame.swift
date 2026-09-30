// Platform-independent description of one rendered frame. The game builds it, the
// Metal renderer consumes it. Struct layouts marked "GPU" are mirrored in Common.metal.
import Foundation

/// Per-instance data (GPU, 208 bytes): model matrices for motion vectors and shading params.
public struct InstanceGPU {
    public var model: Mat4
    public var prevModel: Mat4
    public var tint: Vec4        // rgb multiplier, a = opacity (ghosts / invisibility)
    public var params: Vec4      // x hit flash, y emissive boost, z telegraph glow, w dissolve
    public var flash: Vec4       // rgb hit flash color, a = telegraph kind (0 none 1 white 2 red 3 purple 4 gold)
    public init(model: Mat4, prevModel: Mat4, tint: Vec4 = Vec4(1, 1, 1, 1), params: Vec4 = .zero, flash: Vec4 = Vec4(1, 1, 1, 0)) {
        self.model = model; self.prevModel = prevModel; self.tint = tint; self.params = params; self.flash = flash
    }
}

public enum DrawLayer: Int { case opaque, ghost }

public struct DrawCall {
    public var mesh: MeshData
    public var materials: [MaterialDesc]
    public var instances: [InstanceGPU]
    /// Index into RenderFrame.skinPalettes (nil = static mesh).
    public var skin: Int?
    public var castShadow: Bool
    public var layer: DrawLayer
    /// Mesh changes every frame (cloth): uploaded to a transient buffer.
    public var dynamic: Bool
    public var doubleSided: Bool

    public init(mesh: MeshData, materials: [MaterialDesc], instances: [InstanceGPU], skin: Int? = nil, castShadow: Bool = true,
                layer: DrawLayer = .opaque, dynamic: Bool = false, doubleSided: Bool = false) {
        self.mesh = mesh; self.materials = materials; self.instances = instances; self.skin = skin
        self.castShadow = castShadow; self.layer = layer; self.dynamic = dynamic; self.doubleSided = doubleSided
    }
}

/// GPU point light (32 bytes).
public struct PointLightGPU {
    public var positionRadius: Vec4
    public var colorIntensity: Vec4
    public init(position: Vec3, radius: Float, color: Vec3, intensity: Float) {
        positionRadius = Vec4(position, radius)
        colorIntensity = Vec4(color, intensity)
    }
}

/// GPU particle (80 bytes). Spawned by the CPU, simulated by a compute shader.
public struct ParticleGPU {
    public var posLife: Vec4       // xyz position, w remaining life
    public var velSize: Vec4       // xyz velocity, w size
    public var color: Vec4         // HDR rgb, a alpha
    public var params: Vec4        // x max life, y drag, z gravity, w kind
    public var extra: Vec4         // x growth, y spin, z stretch, w seed

    public init(position: Vec3, velocity: Vec3, color: Vec4, size: Float, life: Float, drag: Float, gravity: Float,
                kind: ParticleKind, growth: Float = 0, stretch: Float = 1, seed: Float = 0) {
        posLife = Vec4(position, life)
        velSize = Vec4(velocity, size)
        self.color = color
        params = Vec4(life, drag, gravity, Float(kind.rawValue))
        extra = Vec4(growth, 0, stretch, seed)
    }
}

public enum ParticleKind: Int {
    case spark = 0      // velocity-stretched additive streak, bounces
    case glow = 1       // soft additive blob (flashes, embers, runes)
    case smoke = 2      // alpha-blended soft puff
    case snow = 3       // alpha flake
    case rain = 4       // stretched alpha streak
    case petal = 5      // tumbling alpha leaf
    case ember = 6      // small additive flickering point
    case blood = 7      // dark alpha droplets
    case shard = 8      // ice / debris chunk (alpha, lit)
}

/// Ribbon trail vertex (32 bytes): position + u coordinate + color (HDR).
public struct TrailVertexGPU {
    public var position: Vec4    // xyz, w = u (0 newest .. 1 oldest)
    public var color: Vec4
}

/// Ground decal (GPU, 48 bytes).
public struct DecalGPU {
    public var centerRadius: Vec4   // xyz center, w radius
    public var params: Vec4         // x rotation, y age01, z kind, w seed
    public var color: Vec4          // emissive rgb, a opacity
}

public enum DecalKind: Int { case crack = 0, scorch = 1, blood = 2, frost = 3, glyph = 4, slash = 5 }

/// Debug line (drawn on top of everything).
public struct DebugLine {
    public var a: Vec3
    public var b: Vec3
    public var color: Vec4
    public init(_ a: Vec3, _ b: Vec3, _ c: Vec4) { self.a = a; self.b = b; color = c }
}

/// Environment lighting for the frame (derived from the arena preset + phase shifts).
public struct EnvironmentParams {
    public var sky = SkyParams()
    public var sunDirection = vnormalize(Vec3(-0.4, 0.4, -0.6))   // toward the sun
    public var sunColor = Vec3(1, 0.8, 0.6)
    public var sunIntensity: Float = 3
    public var ambientIntensity: Float = 0.45
    public var sh: [Vec4] = [Vec4](repeating: .zero, count: 9)     // irradiance SH (rgb)
    public var fogColor = Vec3(0.5, 0.45, 0.45)
    public var fogDensity: Float = 0.02
    public var fogHeight: Float = 6
    public var fogScatter: Float = 0.6
    public var rimColor = Vec3(1, 0.8, 0.6)
    public var rimIntensity: Float = 0.6
    public var wetness: Float = 0
    public var lightning: Float = 0
    public var floorMaterial = MaterialDesc()
    public init() {}
}

/// Post-processing parameters for the frame.
public struct PostParams {
    public var exposure: Float = 1
    public var contrast: Float = 1.08
    public var saturation: Float = 1
    public var tint = Vec3(1, 1, 1)
    public var shadows = Vec3(0.1, 0.11, 0.16)
    public var highlights = Vec3(1, 0.95, 0.86)
    public var splitStrength: Float = 0.25
    public var vignette: Float = 0.35
    public var grain: Float = 0.04
    public var chromatic: Float = 0.0
    public var radialBlur: Float = 0
    public var radialCenter = Vec2(0.5, 0.5)
    public var bloomStrength: Float = 0.9
    public var bloomThreshold: Float = 1.0
    public var dofFocus: Float = 5
    public var dofRange: Float = 3
    public var dofStrength: Float = 0
    public var motionBlur: Float = 0.5
    public var flash = Vec4.zero               // rgb, a strength (screen flash)
    public var desaturate: Float = 0
    public var lowHealth: Float = 0
    public var slowmo: Float = 0
    public var letterbox: Float = 0
    public init() {}
}

/// Effect toggles and quality (from Settings).
public struct RenderSettings: Equatable {
    public var resolutionScale: Float = 1
    public var shadowSize = 2048
    public var shadows = true
    public var ssao = true
    public var ssr = true
    public var volumetrics = true
    public var bloom = true
    public var motionBlur = true
    public var dof = true
    public var chromaticAberration = true
    public var filmGrain = true
    public var vignette = true
    public var taa = true
    public var metalFX = false
    public var particleBudget = 65536
    public var contactShadows = true
    public var flashing = true
    public init() {}
}

public struct RenderFrame {
    public var view = Mat4.identity
    public var proj = Mat4.identity
    public var cameraPosition = Vec3.zero
    public var near: Float = 0.08
    public var far: Float = 600
    public var fovY: Float = 58
    public var env = EnvironmentParams()
    public var post = PostParams()
    public var settings = RenderSettings()
    public var draws: [DrawCall] = []
    public var skinPalettes: [[Mat4]] = []
    public var prevSkinPalettes: [[Mat4]] = []
    public var lights: [PointLightGPU] = []
    public var particleSpawns: [ParticleGPU] = []
    public var trailVertices: [TrailVertexGPU] = []
    public var trailIndices: [UInt32] = []
    public var decals: [DecalGPU] = []
    public var debugLines: [DebugLine] = []
    public var ui = UIDrawList()
    public var time: Float = 0
    public var dt: Float = 0
    public var skyVersion = 0              // bump when sky parameters change (renderer re-bakes the IBL cubemap)
    public var cameraCut = false           // reset temporal history
    public init() {}
}
