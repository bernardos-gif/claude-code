// CPU-side mesh and material descriptions shared by the procedural generators and the
// Metal renderer. Layouts here are mirrored exactly in Shaders/Common.metal.
import Foundation

/// 40-byte vertex. Mirrors `struct Vertex` in Common.metal (packed_float3 x2 + uchar4 x4).
public struct Vertex: Equatable {
    public var px: Float, py: Float, pz: Float
    public var nx: Float, ny: Float, nz: Float
    /// RGB tint multiplier (sRGB-ish 0..255), A = baked cavity/AO (255 = open).
    public var color: UInt32
    /// Four bone indices (UInt8 each).
    public var bones: UInt32
    /// Four bone weights (UNorm8, sum 255).
    public var weights: UInt32
    /// x = material slot 0..7, y = edge wear 0..255, z = emissive mask, w = random/detail.
    public var attr: UInt32

    public init(p: Vec3, n: Vec3, color: UInt32 = 0xFFFF_FFFF, bones: UInt32 = 0, weights: UInt32 = 255, attr: UInt32 = 0) {
        px = p.x; py = p.y; pz = p.z
        nx = n.x; ny = n.y; nz = n.z
        self.color = color; self.bones = bones; self.weights = weights; self.attr = attr
    }

    @inlinable public var position: Vec3 {
        get { Vec3(px, py, pz) }
        set { px = newValue.x; py = newValue.y; pz = newValue.z }
    }
    @inlinable public var normal: Vec3 {
        get { Vec3(nx, ny, nz) }
        set { nx = newValue.x; ny = newValue.y; nz = newValue.z }
    }

    @inlinable public static func pack(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        UInt32(a) | (UInt32(b) << 8) | (UInt32(c) << 16) | (UInt32(d) << 24)
    }
    @inlinable public static func packColor(_ c: Vec3, ao: Float = 1) -> UInt32 {
        pack(UInt8(saturatef(c.x) * 255), UInt8(saturatef(c.y) * 255), UInt8(saturatef(c.z) * 255), UInt8(saturatef(ao) * 255))
    }
    @inlinable public static func packAttr(material: Int, edge: Float, emissive: Float, detail: Float = 0) -> UInt32 {
        pack(UInt8(clamping: material), UInt8(saturatef(edge) * 255), UInt8(saturatef(emissive) * 255), UInt8(saturatef(detail) * 255))
    }

    public var materialSlot: Int { Int(attr & 0xFF) }
}

/// Procedural material families. The fragment shader builds albedo/roughness/normal
/// detail for each family from tileable noise textures (triplanar).
public enum MaterialKind: Int, Codable, CaseIterable {
    case plain = 0, metal, stone, wood, leather, fabric, ice, obsidian, bone, moss
    case skin, gold, rustIron, dirt, lava, marble, snow, planks, sand, hair, water, crystal

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self), let k = MaterialKind(rawValue: i) { self = k; return }
        let s = try c.decode(String.self)
        self = MaterialKind.named(s)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }

    public var name: String { String(describing: self) }

    public static func named(_ s: String) -> MaterialKind {
        allCases.first { $0.name.lowercased() == s.lowercased() } ?? .plain
    }
}

/// One material slot. Mirrors `struct MaterialGPU` in Common.metal (4 x float4).
public struct MaterialDesc: Equatable {
    public var kind: MaterialKind = .plain
    public var color: Vec3 = Vec3(0.5, 0.5, 0.5)    // linear base color
    public var metallic: Float = 0
    public var roughness: Float = 0.6
    public var emissive: Vec3 = .zero                // linear, multiplied by strength
    public var emissiveStrength: Float = 0
    public var wear: Float = 0.3                     // edge scratches / exposed metal
    public var dirt: Float = 0.3                     // grime in crevices
    public var rust: Float = 0                       // rust / corrosion
    public var frost: Float = 0                      // frost on top faces and cavities
    public var scale: Float = 1                      // pattern scale
    public var runes: Float = 0                      // emissive engraving intensity
    public var sheen: Float = 0                      // fabric sheen / wetness

    public init(kind: MaterialKind = .plain, color: Vec3 = Vec3(0.5, 0.5, 0.5), metallic: Float = 0, roughness: Float = 0.6,
                emissive: Vec3 = .zero, emissiveStrength: Float = 0, wear: Float = 0.3, dirt: Float = 0.3,
                rust: Float = 0, frost: Float = 0, scale: Float = 1, runes: Float = 0, sheen: Float = 0) {
        self.kind = kind; self.color = color; self.metallic = metallic; self.roughness = roughness
        self.emissive = emissive; self.emissiveStrength = emissiveStrength; self.wear = wear; self.dirt = dirt
        self.rust = rust; self.frost = frost; self.scale = scale; self.runes = runes; self.sheen = sheen
    }

    /// GPU packing (4 x float4 = 64 bytes).
    public var packed: [Vec4] {
        [Vec4(color, metallic),
         Vec4(emissive * emissiveStrength, roughness),
         Vec4(Float(kind.rawValue), wear, dirt, rust),
         Vec4(frost, scale, runes, sheen)]
    }

    // Handy presets.
    public static func steel(_ c: Vec3 = Vec3(0.62, 0.63, 0.66), rough: Float = 0.32) -> MaterialDesc {
        MaterialDesc(kind: .metal, color: c, metallic: 1, roughness: rough, wear: 0.5, dirt: 0.25)
    }
    public static func gold(_ c: Vec3 = Vec3(1.0, 0.72, 0.32)) -> MaterialDesc {
        MaterialDesc(kind: .gold, color: c, metallic: 1, roughness: 0.28, wear: 0.4, dirt: 0.3)
    }
    public static func leather(_ c: Vec3 = Vec3(0.20, 0.11, 0.06)) -> MaterialDesc {
        MaterialDesc(kind: .leather, color: c, metallic: 0, roughness: 0.62, wear: 0.4, dirt: 0.35)
    }
    public static func fabric(_ c: Vec3) -> MaterialDesc {
        MaterialDesc(kind: .fabric, color: c, metallic: 0, roughness: 0.85, wear: 0.15, dirt: 0.35, sheen: 0.3)
    }
    public static func skin(_ c: Vec3) -> MaterialDesc {
        MaterialDesc(kind: .skin, color: c, metallic: 0, roughness: 0.55, wear: 0, dirt: 0.15)
    }
    public static func wood(_ c: Vec3 = Vec3(0.28, 0.16, 0.08)) -> MaterialDesc {
        MaterialDesc(kind: .wood, color: c, metallic: 0, roughness: 0.7, wear: 0.3, dirt: 0.3)
    }
    public static func emissive(_ c: Vec3, strength: Float) -> MaterialDesc {
        MaterialDesc(kind: .plain, color: c * 0.2, metallic: 0, roughness: 0.4, emissive: c, emissiveStrength: strength, wear: 0, dirt: 0)
    }
}

/// Unique id source for meshes (the renderer caches GPU buffers per id).
public enum MeshIDs {
    private static let lock = NSLock()
    private static var next = 1
    public static func make() -> Int {
        lock.lock(); defer { lock.unlock() }
        next += 1
        return next
    }
}

/// Triangle mesh. Immutable once registered with the renderer (dynamic meshes are
/// re-created or passed per frame).
public final class MeshData {
    public let id: Int
    public var name: String
    public var vertices: [Vertex]
    public var indices: [UInt32]
    public var boundsMin: Vec3 = .zero
    public var boundsMax: Vec3 = .zero
    public var skinned: Bool

    public init(name: String, vertices: [Vertex] = [], indices: [UInt32] = [], skinned: Bool = false) {
        id = MeshIDs.make()
        self.name = name
        self.vertices = vertices
        self.indices = indices
        self.skinned = skinned
        computeBounds()
    }

    public func computeBounds() {
        guard let f = vertices.first else { boundsMin = .zero; boundsMax = .zero; return }
        var lo = f.position, hi = f.position
        for v in vertices { lo = vmin(lo, v.position); hi = vmax(hi, v.position) }
        boundsMin = lo; boundsMax = hi
    }

    public var triangleCount: Int { indices.count / 3 }
    public var boundingRadius: Float { vlength(boundsMax - boundsMin) * 0.5 }
    public var center: Vec3 { (boundsMin + boundsMax) * 0.5 }
}
