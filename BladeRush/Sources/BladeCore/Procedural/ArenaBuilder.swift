// Builds arenas from theme presets: floor, ring of architecture and props (instanced),
// distant backdrop silhouettes, colliders for camera/movement, static lights and emitters.
import Foundation

public struct PropInstanceSet {
    public var name: String
    public var mesh: MeshData
    public var materials: [MaterialDesc]
    public var transforms: [Mat4]
    public var castShadow: Bool
}

public struct CylinderCollider: Equatable {
    public var center: Vec2
    public var radius: Float
    public var height: Float
}

public struct StaticLight: Equatable {
    public var position: Vec3
    public var color: Vec3
    public var intensity: Float
    public var radius: Float
    public var flicker: Float
}

public struct EmitterDesc: Equatable {
    public var position: Vec3
    public var kind: String     // fire, embers, smoke, drip, sparks, mist, runes
    public var rate: Float
    public var scale: Float
}

public struct BuiltArena {
    public var def: ArenaDef
    public var sets: [PropInstanceSet]
    public var colliders: [CylinderCollider]
    public var lights: [StaticLight]
    public var emitters: [EmitterDesc]
}

public enum ArenaBuilder {
    public static func floorMaterial(_ d: ArenaDef) -> MaterialDesc {
        let kind: MaterialKind
        switch d.floor {
        case "flagstone", "rock": kind = .stone
        case "dirt": kind = .dirt
        case "planks", "tatami": kind = .planks
        case "snow": kind = .snow
        case "ice": kind = .ice
        case "marble": kind = .marble
        case "obsidian": kind = .obsidian
        case "sand": kind = .sand
        case "moss": kind = .moss
        case "grate": kind = .metal
        case "bone": kind = .bone
        case "water": kind = .water
        case "lava": kind = .lava
        default: kind = .stone
        }
        var m = MaterialDesc(kind: kind, color: parseColor(d.floorColor), metallic: kind == .metal ? 0.9 : 0, roughness: d.floorRoughness,
                             wear: 0.2, dirt: 0.4, scale: 1, sheen: d.wet)
        m.emissive = parseColor(d.floorColor2)          // floor uses emissive slot as its secondary color
        m.emissiveStrength = 0                            // (strength 0 => shader reads it as color2)
        m.runes = d.floor == "flagstone" ? 1 : (d.floor == "tatami" ? 2 : 0)
        if kind == .lava { m.emissiveStrength = 4 }
        return m
    }

    public static func build(_ d: ArenaDef, quality: Float = 1) -> BuiltArena {
        var sets: [PropInstanceSet] = []
        var colliders: [CylinderCollider] = []
        var lights: [StaticLight] = []
        var emitters: [EmitterDesc] = []

        // Floor.
        let floorMesh = buildFloor(d)
        var floorMats = [MaterialDesc](repeating: floorMaterial(d), count: 8)
        floorMats[1] = MaterialDesc(kind: .stone, color: parseColor(d.floorColor2), roughness: 0.9)
        sets.append(PropInstanceSet(name: "floor", mesh: floorMesh, materials: floorMats, transforms: [.identity], castShadow: false))

        // Backdrop.
        if let bd = buildBackdrop(d) { sets.append(bd) }

        // Props.
        var cache: [String: (MeshData, [MaterialDesc], Float, Float)] = [:]
        for (pi, pp) in d.props.enumerated() {
            var rng = Rng(seed: UInt64(pp.seed &* 7919 &+ pi &* 31 &+ 1))
            var transforms: [Mat4] = []
            var brokenTransforms: [Mat4] = []
            let arcR = pp.arc * kDeg2Rad
            for i in 0..<pp.count {
                let frac = pp.arc >= 359 ? Float(i) / Float(pp.count) : (pp.count > 1 ? Float(i) / Float(pp.count - 1) : 0.5)
                let a = pp.angleOffset * kDeg2Rad + frac * arcR + rng.range(-0.08, 0.08)
                var pos: Vec3
                if d.shape == "rect" {
                    let hx = d.size.x * 0.5 + pp.ring, hz = d.size.y * 0.5 + pp.ring
                    let dir = Vec2(sin(a), cos(a))
                    let k = min(hx / max(abs(dir.x), 1e-3), hz / max(abs(dir.y), 1e-3))
                    pos = Vec3(dir.x * k, 0, dir.y * k)
                } else {
                    pos = Vec3(sin(a) * pp.ring, 0, cos(a) * pp.ring)
                }
                pos += Vec3(rng.range(-pp.jitter, pp.jitter), 0, rng.range(-pp.jitter, pp.jitter)) * 0.5
                let sc = pp.scale * (1 + rng.range(-pp.scaleJitter, pp.scaleJitter))
                let yaw = faceCenter(pp.kind) ? atan2(-pos.x, -pos.z) : rng.range(0, kTwoPi)
                let m = Mat4.trs(pos, Quat.yaw(yaw), Vec3(repeating: sc))
                let broken = rng.chance(pp.broken)
                if broken { brokenTransforms.append(m) } else { transforms.append(m) }
                let key = pp.kind + (broken ? "_broken" : "")
                if cache[key] == nil { cache[key] = propMesh(pp.kind, broken: broken, d: d, pp: pp) }
                let colR = (cache[key]?.2 ?? 0) * sc
                let colH = (cache[key]?.3 ?? 0) * sc
                if colR > 0 { colliders.append(CylinderCollider(center: pos.xz, radius: colR, height: colH)) }
                if pp.light || lightProp(pp.kind) {
                    let lp = pos + Vec3(0, lightHeight(pp.kind) * sc, 0)
                    let col = pp.color.isEmpty ? srgbHex(0xFF8A3A) : parseColor(pp.color)
                    lights.append(StaticLight(position: lp, color: col, intensity: 14 * sc, radius: 9 * sc, flicker: 0.35))
                    emitters.append(EmitterDesc(position: lp, kind: pp.kind == "obelisk" || pp.kind == "crystal" ? "runes" : "fire", rate: 40, scale: sc))
                }
            }
            for (key, list) in [(pp.kind, transforms), (pp.kind + "_broken", brokenTransforms)] where !list.isEmpty {
                if let (mesh, mats, _, _) = cache[key] {
                    sets.append(PropInstanceSet(name: key, mesh: mesh, materials: mats, transforms: list, castShadow: true))
                }
            }
        }
        for l in d.lights {
            lights.append(StaticLight(position: l.position, color: parseColor(l.color), intensity: l.intensity, radius: l.radius, flicker: l.flicker))
        }
        return BuiltArena(def: d, sets: sets, colliders: colliders, lights: lights, emitters: emitters)
    }

    static func faceCenter(_ k: String) -> Bool { ["statue", "throne", "torii", "arch", "brokenWall", "wall", "gate", "banner", "bell"].contains(k) }
    static func lightProp(_ k: String) -> Bool { ["brazier", "lantern", "torch", "obelisk", "crystal", "forge"].contains(k) }
    static func lightHeight(_ k: String) -> Float {
        switch k {
        case "brazier": return 1.25
        case "lantern": return 1.1
        case "torch": return 2.2
        case "obelisk": return 3.5
        case "crystal": return 1.5
        case "forge": return 1.0
        default: return 1.5
        }
    }

    // MARK: Floor

    static func buildFloor(_ d: ArenaDef) -> MeshData {
        var verts: [Vertex] = []
        var idx: [UInt32] = []
        let attr = Vertex.packAttr(material: 0, edge: 0, emissive: 0)
        if d.shape == "rect" {
            let hx = d.size.x * 0.5 + 14, hz = d.size.y * 0.5 + 14
            let n = 48
            for j in 0...n {
                for i in 0...n {
                    let x = -hx + 2 * hx * Float(i) / Float(n), z = -hz + 2 * hz * Float(j) / Float(n)
                    let out = max(abs(x) - d.size.x * 0.5, abs(z) - d.size.y * 0.5)
                    let y = out > 1 ? smoothstepf(1, 12, out) * 1.5 : 0
                    verts.append(Vertex(p: Vec3(x, y, z), n: Vec3(0, 1, 0), color: Vertex.packColor(Vec3(1, 1, 1), ao: 1), attr: attr))
                }
            }
            for j in 0..<n {
                for i in 0..<n {
                    let a = UInt32(j * (n + 1) + i), b = a + 1, c = a + UInt32(n + 1), e = c + 1
                    idx += [a, c, b, b, c, e]
                }
            }
        } else {
            let rings = 36, segs = 96
            let outer = d.radius + 16
            verts.append(Vertex(p: .zero, n: Vec3(0, 1, 0), color: Vertex.packColor(Vec3(1, 1, 1), ao: 1), attr: attr))
            for r in 1...rings {
                let t = Float(r) / Float(rings)
                let rad = outer * pow(t, 1.25)
                let out = rad - d.radius
                let y = out > 1.5 ? smoothstepf(1.5, 16, out) * (d.backdrop == "void" ? -30 : 1.2) : 0
                for s in 0..<segs {
                    let a = Float(s) / Float(segs) * kTwoPi
                    verts.append(Vertex(p: Vec3(sin(a) * rad, y, cos(a) * rad), n: Vec3(0, 1, 0),
                                        color: Vertex.packColor(Vec3(1, 1, 1), ao: 1), attr: attr))
                }
            }
            for s in 0..<segs {
                let a = UInt32(1 + s), b = UInt32(1 + (s + 1) % segs)
                idx += [0, a, b]
            }
            for r in 1..<rings {
                let base = UInt32(1 + (r - 1) * segs), next = UInt32(1 + r * segs)
                for s in 0..<segs {
                    let s1 = UInt32((s + 1) % segs)
                    let a = base + UInt32(s), b = base + s1, c = next + UInt32(s), e = next + s1
                    idx += [a, c, b, b, c, e]
                }
            }
        }
        // Normals from geometry (the outer lip slopes).
        var normals = [Vec3](repeating: .zero, count: verts.count)
        var t = 0
        while t < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let n = vcross(verts[b].position - verts[a].position, verts[c].position - verts[a].position)
            normals[a] += n; normals[b] += n; normals[c] += n
            t += 3
        }
        for i in verts.indices {
            var n = vnormalize(normals[i], fallback: Vec3(0, 1, 0))
            if n.y < 0 { n = -n }
            verts[i].normal = n
        }
        // Ensure CCW winding seen from above (normal up).
        var i = 0
        while i < idx.count {
            let a = verts[Int(idx[i])].position, b = verts[Int(idx[i + 1])].position, c = verts[Int(idx[i + 2])].position
            if vcross(b - a, c - a).y < 0 { idx.swapAt(i + 1, i + 2) }
            i += 3
        }
        return MeshData(name: "floor", vertices: verts, indices: idx)
    }

    // MARK: Backdrop

    static func buildBackdrop(_ d: ArenaDef) -> PropInstanceSet? {
        let col = parseColor(d.backdropColor)
        var b = MeshBuilder()
        var rng = Rng(d.id + "backdrop")
        let r0 = d.boundingRadius + 28
        switch d.backdrop {
        case "void":
            return nil
        case "sea":
            b.material = 1
            b.lathe([(r0 + 200, -0.3), (0, -0.3)], segments: 48, rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2), capBottom: false, capTop: false)
            for k in 0..<14 {
                let a = rng.range(0, kTwoPi)
                let rr = r0 + rng.range(10, 60)
                b.material = 0
                b.sphere(center: Vec3(sin(a) * rr, rng.range(-2, 1), cos(a) * rr), radius: rng.range(3, 9), segments: 7,
                         scale: Vec3(1, rng.range(0.6, 1.6), 1))
            }
        case "cave", "forge":
            // Enclosing rock dome with stalactites.
            b.material = 0
            var prof: [(Float, Float)] = []
            for k in 0...10 {
                let t = Float(k) / 10
                prof.append((r0 * (1 - 0.3 * t * t), t * 26))
            }
            b.lathe(prof.reversed(), segments: 40, rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2), capBottom: true, capTop: false)
            for _ in 0..<40 {
                let a = rng.range(0, kTwoPi), rr = rng.range(r0 * 0.3, r0 * 0.85)
                let h = rng.range(3, 9)
                b.cylinder(from: Vec3(sin(a) * rr, 24 - rr * 0.2, cos(a) * rr), to: Vec3(sin(a) * rr, 24 - rr * 0.2 - h, cos(a) * rr),
                           r0: rng.range(0.8, 2), r1: 0.05, segments: 6)
            }
        default:
            // Rings of cliffs / mountains / walls / spires.
            let isWall = d.backdrop == "walls" || d.backdrop == "city"
            let count = isWall ? 28 : 36
            for k in 0..<count {
                let a = Float(k) / Float(count) * kTwoPi + rng.range(-0.05, 0.05)
                let rr = r0 + rng.range(0, d.backdrop == "mountains" ? 60 : 18)
                let h: Float
                switch d.backdrop {
                case "mountains": h = rng.range(25, 70)
                case "spires": h = rng.range(18, 45)
                case "forest": h = rng.range(10, 18)
                case "walls", "city": h = rng.range(9, 16)
                default: h = rng.range(8, 26)
                }
                let w = rng.range(6, 14)
                b.material = 0
                if isWall {
                    b.box(center: Vec3(sin(a) * rr, h * 0.5, cos(a) * rr), half: Vec3(w, h * 0.5, 2), rot: Quat.yaw(a), bevel: 0.2, segments: 1)
                    if d.backdrop == "city" && rng.chance(0.4) {
                        b.cylinder(from: Vec3(sin(a) * rr, h, cos(a) * rr), to: Vec3(sin(a) * rr, h + 8, cos(a) * rr), r0: 2.5, r1: 0.2, segments: 8)
                    }
                    for m in 0..<Int(w) {
                        let off = Float(m) * 2 - w + 1
                        let p = Vec3(sin(a) * rr + cos(a) * off, h + 0.6, cos(a) * rr - sin(a) * off)
                        b.box(center: p, half: Vec3(0.45, 0.6, 1.8), rot: Quat.yaw(a), bevel: 0.1, segments: 1)
                    }
                } else if d.backdrop == "forest" {
                    b.material = 1
                    b.cylinder(from: Vec3(sin(a) * rr, 0, cos(a) * rr), to: Vec3(sin(a) * rr, h, cos(a) * rr), r0: 0.8, r1: 0.25, segments: 6)
                    b.material = 0
                    b.cylinder(from: Vec3(sin(a) * rr, h * 0.35, cos(a) * rr), to: Vec3(sin(a) * rr, h * 1.3, cos(a) * rr), r0: w * 0.4, r1: 0.1, segments: 7)
                } else {
                    let tipR: Float = d.backdrop == "spires" ? 0.3 : w * 0.25
                    b.lathe([(w, -2), (w * 0.8, h * 0.4), (tipR, h)], segments: 7, center: Vec3(sin(a) * rr, 0, cos(a) * rr),
                            rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2) * Quat(axis: Vec3(0, 0, 1), angle: rng.range(0, 6)), capBottom: false, capTop: true)
                }
            }
        }
        let mesh = b.build(name: "backdrop_\(d.backdrop)", creaseDeg: 50)
        var mats = [MaterialDesc](repeating: MaterialDesc(kind: .stone, color: col, roughness: 0.95, wear: 0, dirt: 0.2), count: 8)
        mats[1] = d.backdrop == "sea" ? MaterialDesc(kind: .water, color: srgbHex(0x0B1A22), roughness: 0.08, sheen: 1)
                                      : MaterialDesc(kind: .wood, color: col * 0.7, roughness: 0.9)
        return PropInstanceSet(name: "backdrop", mesh: mesh, materials: mats, transforms: [.identity], castShadow: false)
    }

    // MARK: Props

    /// Returns (mesh, materials, collider radius, collider height).
    static func propMesh(_ kind: String, broken: Bool, d: ArenaDef, pp: PropPlacement) -> (MeshData, [MaterialDesc], Float, Float) {
        var b = MeshBuilder()
        var rng = Rng(kind + d.id + (broken ? "b" : ""))
        let stoneCol = pp.color.isEmpty ? srgbHex(0x6E6862) : parseColor(pp.color)
        var mats: [MaterialDesc] = [
            MaterialDesc(kind: pp.material.isEmpty ? .stone : MaterialKind.named(pp.material), color: stoneCol, roughness: 0.85, wear: 0.4, dirt: 0.6),
            MaterialDesc.wood(),
            MaterialDesc.gold(),
            MaterialDesc.emissive(srgbHex(0xFF7A2A), strength: 6),
            MaterialDesc.fabric(srgbHex(0x6A1414)),
            MaterialDesc.steel(srgbHex(0x3A3B40), rough: 0.45),
            MaterialDesc(kind: .moss, color: srgbHex(0x3E4A2A), roughness: 0.9),
            MaterialDesc(kind: .ice, color: srgbHex(0x9FD8F5), roughness: 0.06, emissive: srgbHex(0x3A9AE0), emissiveStrength: 0.6, frost: 0.5),
        ]
        var colR: Float = 0, colH: Float = 0
        switch kind {
        case "pillar":
            let h: Float = broken ? rng.range(1.5, 3.2) : 5.5
            b.material = 0
            b.box(center: Vec3(0, 0.2, 0), half: Vec3(0.75, 0.2, 0.75), bevel: 0.05)
            var prof: [(Float, Float)] = [(0.52, 0.4), (0.5, 0.6)]
            let n = 8
            for k in 1...n { prof.append((0.46 - 0.03 * Float(k) / Float(n), 0.6 + (h - 1.2) * Float(k) / Float(n))) }
            b.lathe(prof, segments: 14, rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2), capBottom: false, capTop: broken)
            if !broken {
                b.box(center: Vec3(0, h - 0.3, 0), half: Vec3(0.7, 0.3, 0.7), bevel: 0.06)
            } else {
                for _ in 0..<3 {
                    b.box(center: Vec3(rng.range(-1.5, 1.5), 0.2, rng.range(-1.5, 1.5)), half: Vec3(rng.range(0.2, 0.4), rng.range(0.15, 0.3), rng.range(0.2, 0.4)),
                          rot: Quat.euler(rng.range(-0.4, 0.4), rng.range(0, 3), rng.range(-0.4, 0.4)), bevel: 0.05)
                }
            }
            colR = 0.65; colH = h
        case "arch":
            b.material = 0
            for s: Float in [-1, 1] {
                b.box(center: Vec3(2.2 * s, 2.5, 0), half: Vec3(0.55, 2.5, 0.6), bevel: 0.06)
            }
            var rings: [[Vec3]] = []
            for k in 0...12 {
                let a = Float(k) / 12 * kPi
                let c = Vec3(cos(a) * 2.2, 5 + sin(a) * 1.8, 0)
                let o = Vec3(cos(a), sin(a), 0)
                rings.append([c - o * 0.5 + Vec3(0, 0, 0.6), c + o * 0.5 + Vec3(0, 0, 0.6), c + o * 0.5 - Vec3(0, 0, 0.6), c - o * 0.5 - Vec3(0, 0, 0.6)])
            }
            if !broken { b.loft(rings) } else { b.loft(Array(rings.prefix(6))) }
            colR = 0
        case "brokenWall", "wall":
            b.material = 0
            let segments = 6
            for k in 0..<segments {
                let h = broken ? rng.range(0.6, 2.5) : rng.range(2.5, 4.5)
                b.box(center: Vec3(Float(k) * 1.2 - 3, h * 0.5, rng.range(-0.1, 0.1)), half: Vec3(0.62, h * 0.5, 0.45),
                      rot: Quat(axis: Vec3(0, 0, 1), angle: rng.range(-0.05, 0.05)), bevel: 0.05)
            }
            colR = 0
        case "statue":
            let (m, sm) = statueMesh(d: d, seed: pp.seed, broken: broken)
            b.append(m)
            mats[0] = sm
            colR = 0.9; colH = 4
        case "brazier", "forge":
            b.material = 5
            b.lathe([(0.0, 0.9), (0.45, 0.95), (0.55, 1.25), (0.48, 1.3), (0.4, 1.0), (0.0, 1.0)], segments: 14,
                    rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2))
            for k in 0..<3 {
                let a = Float(k) / 3 * kTwoPi
                b.cylinder(from: Vec3(sin(a) * 0.45, 0, cos(a) * 0.45), to: Vec3(sin(a) * 0.15, 1.0, cos(a) * 0.15), r0: 0.04, r1: 0.035, segments: 6)
            }
            b.material = 3
            b.sphere(center: Vec3(0, 1.1, 0), radius: 0.36, segments: 10, scale: Vec3(1, 0.35, 1))
            colR = 0.5; colH = 1.3
        case "lantern":
            b.material = 0
            b.box(center: Vec3(0, 0.35, 0), half: Vec3(0.25, 0.35, 0.25), bevel: 0.04)
            b.box(center: Vec3(0, 0.95, 0), half: Vec3(0.3, 0.25, 0.3), bevel: 0.04)
            b.lathe([(0.55, 1.2), (0.0, 1.55)], segments: 4, rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2))
            b.material = 3
            b.box(center: Vec3(0, 0.95, 0), half: Vec3(0.31, 0.12, 0.12), bevel: 0.01)
            b.box(center: Vec3(0, 0.95, 0), half: Vec3(0.12, 0.12, 0.31), bevel: 0.01)
            colR = 0.4; colH = 1.5
        case "torch":
            b.material = 1
            b.cylinder(from: .zero, to: Vec3(0, 2.1, 0), r0: 0.06, r1: 0.05, segments: 6)
            b.material = 3; b.sphere(center: Vec3(0, 2.2, 0), radius: 0.12, segments: 8)
            colR = 0.1; colH = 2.2
        case "banner":
            b.material = 5
            b.cylinder(from: .zero, to: Vec3(0, 6, 0), r0: 0.07, r1: 0.06, segments: 8)
            b.cylinder(from: Vec3(-0.8, 5.6, 0), to: Vec3(0.8, 5.6, 0), r0: 0.04, r1: 0.04, segments: 6)
            b.material = 4
            var rings: [[Vec3]] = []
            for k in 0...10 {
                let t = Float(k) / 10
                let y = 5.55 - t * 3.2
                let wave = sin(t * 5) * 0.12 * t
                let w: Float = broken ? 0.8 * (1 - t * 0.6) : 0.8
                rings.append([Vec3(-w, y, wave + 0.02), Vec3(w, y, wave + 0.02), Vec3(w, y, wave - 0.02), Vec3(-w, y, wave - 0.02)])
            }
            b.loft(rings)
            mats[4] = MaterialDesc.fabric(pp.color.isEmpty ? srgbHex(0x6A1414) : parseColor(pp.color))
            mats[0] = MaterialDesc.steel(srgbHex(0x3A3B40), rough: 0.5)
            colR = 0.15; colH = 6
        case "crate", "barrel":
            b.material = 1
            if kind == "crate" {
                b.box(center: Vec3(0, 0.45, 0), half: Vec3(0.45, 0.45, 0.45), bevel: 0.03)
                b.material = 5
                b.box(center: Vec3(0, 0.45, 0.455), half: Vec3(0.46, 0.05, 0.01), bevel: 0.005)
                if rng.chance(0.6) {
                    b.material = 1
                    b.box(center: Vec3(0.1, 1.2, 0.05), half: Vec3(0.3, 0.3, 0.3), rot: Quat.yaw(0.5), bevel: 0.02)
                }
            } else {
                b.lathe([(0.0, 0.0), (0.36, 0.0), (0.42, 0.45), (0.36, 0.9), (0.0, 0.9)], segments: 14, rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2))
                b.material = 5
                b.torus(center: Vec3(0, 0.2, 0), majorR: 0.39, minorR: 0.02, rot: Quat(axis: Vec3(1, 0, 0), angle: kPi / 2), segments: 16, sides: 4)
                b.torus(center: Vec3(0, 0.7, 0), majorR: 0.39, minorR: 0.02, rot: Quat(axis: Vec3(1, 0, 0), angle: kPi / 2), segments: 16, sides: 4)
            }
            colR = 0.5; colH = 1
        case "mast":
            b.material = 1
            b.cylinder(from: .zero, to: Vec3(0, 12, 0), r0: 0.3, r1: 0.18, segments: 10)
            b.cylinder(from: Vec3(-3, 8, 0), to: Vec3(3, 8, 0), r0: 0.12, r1: 0.12, segments: 8)
            b.material = 4
            b.loft([[Vec3(-2.8, 7.9, 0.05), Vec3(2.8, 7.9, 0.05), Vec3(2.8, 7.9, -0.05), Vec3(-2.8, 7.9, -0.05)],
                    [Vec3(-2.6, 3.5, 0.6), Vec3(2.6, 3.5, 0.6), Vec3(2.6, 3.5, 0.5), Vec3(-2.6, 3.5, 0.5)]])
            mats[4] = MaterialDesc.fabric(srgbHex(0x7A7060))
            colR = 0.35; colH = 12
        case "anvil":
            b.material = 5
            b.box(center: Vec3(0, 0.3, 0), half: Vec3(0.3, 0.3, 0.3), bevel: 0.03)
            b.box(center: Vec3(0, 0.72, 0), half: Vec3(0.2, 0.12, 0.55), bevel: 0.03)
            b.cylinder(from: Vec3(0, 0.72, 0.55), to: Vec3(0, 0.74, 0.9), r0: 0.12, r1: 0.02, segments: 8)
            colR = 0.5; colH = 0.9
        case "crystal", "iceCrystal":
            b.material = 7
            for k in 0..<5 {
                let dir = vnormalize(Vec3(rng.range(-0.5, 0.5), 1, rng.range(-0.5, 0.5)))
                let len = rng.range(1.5, 4.5) * (k == 0 ? 1.4 : 1)
                let base = Vec3(rng.range(-0.5, 0.5), -0.2, rng.range(-0.5, 0.5))
                b.lathe([(0.0, 0), (rng.range(0.25, 0.55), len * 0.15), (rng.range(0.2, 0.4), len * 0.8), (0.0, len)], segments: 6,
                        center: base, rot: Quat.fromTo(Vec3(0, 0, 1), dir))
            }
            if kind == "crystal" {
                mats[7] = MaterialDesc(kind: .crystal, color: parseColor(pp.color.isEmpty ? "#8a4aff" : pp.color), roughness: 0.1,
                                       emissive: parseColor(pp.color.isEmpty ? "#8a4aff" : pp.color), emissiveStrength: 2)
            }
            colR = 0.9; colH = 4
        case "rock", "boulder":
            let m = rockMesh(seed: pp.seed + (broken ? 7 : 0), size: kind == "boulder" ? 2.2 : 1.2)
            b.append(m)
            colR = kind == "boulder" ? 1.8 : 0.9; colH = 2
        case "swordGrave":
            let types = ["longsword", "zweihander", "katana", "falchion", "spear", "halberd", "greatsword", "estoc"]
            for k in 0..<5 {
                var v = WeaponVisual(type: types[(k + pp.seed) % types.count])
                v.rust = 0.7
                let wm = WeaponCatalog.mesh(v)
                var wb = MeshBuilder()
                let tilt = Quat.euler(rng.range(-0.35, 0.35), rng.range(0, 6.28), rng.range(-0.35, 0.35))
                let pos = Vec3(rng.range(-1.2, 1.2), 0, rng.range(-1.2, 1.2))
                let length = WeaponCatalog.get(v.type).reach
                let m = Mat4.trs(pos + tilt.rotate(Vec3(0, length * 0.55, 0)), tilt * Quat(axis: Vec3(1, 0, 0), angle: kPi / 2))
                var tris = 0
                while tris + 2 < wm.indices.count {
                    let a = wm.vertices[Int(wm.indices[tris])], bb = wm.vertices[Int(wm.indices[tris + 1])], c = wm.vertices[Int(wm.indices[tris + 2])]
                    wb.material = 5
                    wb.triangle(m.transformPoint(a.position), m.transformPoint(bb.position), m.transformPoint(c.position),
                                na: m.transformDir(a.normal), nb: m.transformDir(bb.normal), nc: m.transformDir(c.normal))
                    tris += 3
                }
                b.append(wb)
            }
            mats[5] = MaterialDesc(kind: .rustIron, color: srgbHex(0x6A5A50), metallic: 0.8, roughness: 0.6, wear: 0.5, dirt: 0.6, rust: 0.8)
            colR = 0
        case "throne":
            b.material = 0
            b.box(center: Vec3(0, 0.4, 0), half: Vec3(2.5, 0.4, 2), bevel: 0.08)
            b.box(center: Vec3(0, 1.1, -0.3), half: Vec3(1.8, 0.3, 1.5), bevel: 0.06)
            b.box(center: Vec3(0, 1.9, -0.2), half: Vec3(0.9, 0.5, 0.8), bevel: 0.05)
            b.box(center: Vec3(0, 4.2, -0.9), half: Vec3(0.9, 2.3, 0.2), bevel: 0.05)
            b.material = 2
            for s: Float in [-1, 1] {
                b.box(center: Vec3(0.95 * s, 2.6, -0.2), half: Vec3(0.12, 0.3, 0.8), bevel: 0.03)
                for k in 0..<5 {
                    b.cylinder(from: Vec3((0.2 + Float(k) * 0.16) * s, 6.4, -0.9), to: Vec3((0.3 + Float(k) * 0.28) * s, 7.8 - Float(k) * 0.25, -0.9),
                               r0: 0.05, r1: 0.005, segments: 5)
                }
            }
            colR = 2.5; colH = 6
        case "torii":
            b.material = 0
            for s: Float in [-1, 1] { b.cylinder(from: Vec3(2.3 * s, 0, 0), to: Vec3(2.2 * s, 5.2, 0), r0: 0.28, r1: 0.24, segments: 12) }
            b.box(center: Vec3(0, 4.3, 0), half: Vec3(2.8, 0.18, 0.2), bevel: 0.04)
            b.box(center: Vec3(0, 5.35, 0), half: Vec3(3.4, 0.2, 0.3), bevel: 0.05)
            b.material = 5
            b.box(center: Vec3(0, 5.62, 0), half: Vec3(3.6, 0.08, 0.36), bevel: 0.03)
            mats[0] = MaterialDesc(kind: .plain, color: srgbHex(0x8E1A12), roughness: 0.5, wear: 0.5, dirt: 0.4)
            colR = 0
        case "obelisk":
            b.material = 0
            b.lathe([(0.9, 0), (0.7, 0.3), (0.55, 6.5), (0.0, 7.5)], segments: 4, rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2) * Quat(axis: Vec3(0, 0, 1), angle: kPi / 4))
            b.material = 3
            for k in 0..<5 {
                b.box(center: Vec3(0, 1.5 + Float(k) * 1.0, 0.56 - Float(k) * 0.025), half: Vec3(0.18, 0.06, 0.02), bevel: 0.005)
            }
            mats[3] = MaterialDesc.emissive(parseColor(pp.color.isEmpty ? "#7a4aff" : pp.color), strength: 6)
            mats[0] = MaterialDesc(kind: .obsidian, color: srgbHex(0x16141C), roughness: 0.15)
            colR = 0.8; colH = 7.5
        case "bones":
            b.material = 0
            for _ in 0..<9 {
                let a = Vec3(rng.range(-1.2, 1.2), 0.05, rng.range(-1.2, 1.2))
                let dir = vnormalize(Vec3(rng.range(-1, 1), rng.range(-0.1, 0.2), rng.range(-1, 1)))
                b.cylinder(from: a, to: a + dir * rng.range(0.3, 0.7), r0: 0.035, r1: 0.03, segments: 6)
                b.sphere(center: a, radius: 0.055, segments: 6)
            }
            b.sphere(center: Vec3(0.3, 0.12, 0.2), radius: 0.13, segments: 10, scale: Vec3(1, 0.9, 1.15))
            mats[0] = MaterialDesc(kind: .bone, color: srgbHex(0xCFC4A6), roughness: 0.6)
            colR = 0
        case "tree":
            let (m, tm) = treeMesh(seed: pp.seed)
            b.append(m)
            mats[0] = tm
            colR = 0.6; colH = 8
        case "bell":
            b.material = 1
            for s: Float in [-1, 1] { b.box(center: Vec3(1.4 * s, 2.5, 0), half: Vec3(0.18, 2.5, 0.18), bevel: 0.03) }
            b.box(center: Vec3(0, 5.1, 0), half: Vec3(1.9, 0.2, 0.25), bevel: 0.03)
            b.material = 2
            b.lathe([(0.0, 4.9), (0.2, 4.85), (0.5, 4.4), (0.62, 3.6), (0.75, 3.4), (0.0, 3.4)], segments: 16, rot: Quat(axis: Vec3(1, 0, 0), angle: -kPi / 2))
            mats[2] = MaterialDesc(kind: .gold, color: srgbHex(0x7A5A2A), metallic: 1, roughness: 0.4, wear: 0.4, dirt: 0.5)
            colR = 0
        case "chains":
            b.material = 5
            b.cylinder(from: .zero, to: Vec3(0, 4, 0), r0: 0.15, r1: 0.12, segments: 8)
            for k in 0..<12 {
                b.torus(center: Vec3(0.2, 3.9 - Float(k) * 0.07, 0), majorR: 0.05, minorR: 0.012,
                        rot: Quat(axis: Vec3(0, 1, 0), angle: Float(k % 2) * kPi / 2), segments: 8, sides: 4)
            }
            colR = 0.2; colH = 4
        case "gate":
            b.material = 0
            for s: Float in [-1, 1] { b.box(center: Vec3(2.6 * s, 3.5, 0), half: Vec3(0.8, 3.5, 0.8), bevel: 0.08) }
            b.box(center: Vec3(0, 6.6, 0), half: Vec3(3.4, 0.6, 0.8), bevel: 0.08)
            b.material = 5
            for k in 0..<7 {
                b.box(center: Vec3(-1.5 + Float(k) * 0.5, 3.2, 0), half: Vec3(0.04, 3.0, 0.04), bevel: 0.01)
            }
            for k in 0..<5 {
                b.box(center: Vec3(0, 0.8 + Float(k) * 1.3, 0), half: Vec3(1.8, 0.04, 0.04), bevel: 0.01)
            }
            colR = 0
        default:
            b.material = 0
            b.box(center: Vec3(0, 0.5, 0), half: Vec3(0.5, 0.5, 0.5), bevel: 0.05)
            colR = 0.6; colH = 1
        }
        return (b.build(name: "prop_\(kind)", creaseDeg: 40), mats, colR, colH)
    }

    static func rockMesh(seed: Int, size: Float) -> MeshBuilder {
        let model = SDFModel()
        var rng = Rng(seed: UInt64(seed) &+ 99)
        for _ in 0..<4 {
            model.add(SDFPrim.ellipsoid(Vec3(rng.range(-0.4, 0.4), rng.range(0.1, 0.4), rng.range(-0.4, 0.4)) * size,
                                        Vec3(rng.range(0.5, 0.9), rng.range(0.35, 0.7), rng.range(0.5, 0.9)) * size,
                                        rot: Quat.euler(rng.range(0, 1), rng.range(0, 6), rng.range(0, 1)))
                .blend(0.3 * size).noise(0.07 * size, 2.5 / size))
        }
        var o = SurfaceNetsOptions()
        o.voxelSize = 0.08 * size
        o.skinned = false
        o.featureScale = size * 2
        let m = SurfaceNets.polygonize(model, name: "rock", options: o)
        var b = MeshBuilder()
        b.material = 0
        var t = 0
        while t + 2 < m.indices.count {
            let a = m.vertices[Int(m.indices[t])], bb = m.vertices[Int(m.indices[t + 1])], c = m.vertices[Int(m.indices[t + 2])]
            b.triangle(a.position, bb.position, c.position, na: a.normal, nb: bb.normal, nc: c.normal)
            t += 3
        }
        return b
    }

    static func treeMesh(seed: Int) -> (MeshBuilder, MaterialDesc) {
        let model = SDFModel()
        var rng = Rng(seed: UInt64(seed) &+ 5)
        func branch(_ a: Vec3, _ dir: Vec3, _ len: Float, _ r: Float, _ depth: Int) {
            let b = a + dir * len
            model.add(SDFPrim.roundCone(a, b, r, r * 0.65).blend(0.15).noise(0.02, 6))
            if depth <= 0 { return }
            for _ in 0..<2 {
                let nd = vnormalize(dir + Vec3(rng.range(-0.8, 0.8), rng.range(0.1, 0.5), rng.range(-0.8, 0.8)))
                branch(b, nd, len * rng.range(0.55, 0.75), r * 0.65, depth - 1)
            }
        }
        branch(Vec3(0, -0.3, 0), Vec3(0, 1, 0), 3.2, 0.45, 3)
        var o = SurfaceNetsOptions()
        o.voxelSize = 0.07
        o.skinned = false
        o.featureScale = 2
        let m = SurfaceNets.polygonize(model, name: "tree", options: o)
        var b = MeshBuilder()
        var t = 0
        while t + 2 < m.indices.count {
            let a = m.vertices[Int(m.indices[t])], bb = m.vertices[Int(m.indices[t + 1])], c = m.vertices[Int(m.indices[t + 2])]
            b.triangle(a.position, bb.position, c.position, na: a.normal, nb: bb.normal, nc: c.normal)
            t += 3
        }
        return (b, MaterialDesc(kind: .wood, color: srgbHex(0x2A221C), roughness: 0.9, wear: 0.1, dirt: 0.5))
    }

    /// A stone warrior statue: reuses the character generator and bakes a pose.
    static func statueMesh(d: ArenaDef, seed: Int, broken: Bool) -> (MeshBuilder, MaterialDesc) {
        var v = CharacterVisual()
        var rng = Rng(seed: UInt64(seed) &+ 17)
        v.body.height = 3.4
        v.body.bulk = rng.range(1.0, 1.3)
        v.chest = ["plate", "none", "leather"][rng.int(3)]
        v.helmet = ["great", "hood", "kabuto", "crown", "none"][rng.int(5)]
        v.pauldrons = ["round", "large", "none"][rng.int(3)]
        v.skirt = ["robe", "tassets", "kilt"][rng.int(3)]
        v.arms = "bracers"
        let sk = Skeleton(v.body)
        let built = CharacterBuilder.build(v, skeleton: sk, quality: 0.35)
        let lib = AnimLibrary()
        var rp = RigPose()
        rp.hand = Vec3(-0.05, -0.3, 0.3); rp.blade = vnormalize(Vec3(0, -1, 0.05)); rp.left = .grip
        rp.crouch = 0.02
        rp.footL = Vec3(0.14, 0, 0.05); rp.footR = Vec3(-0.14, 0, -0.05)
        _ = lib
        let res = Rig.solve(rp, skeleton: sk, grip: .twoHand, twoHandOffset: -0.12)
        let pal = sk.skinMatrices(res.globals)
        var b = MeshBuilder()
        b.material = 0
        func skin(_ vx: Vertex) -> (Vec3, Vec3) {
            var p = Vec3.zero, n = Vec3.zero
            for k in 0..<4 {
                let bi = Int((vx.bones >> (8 * UInt32(k))) & 0xFF)
                let w = Float((vx.weights >> (8 * UInt32(k))) & 0xFF) / 255
                if w <= 0 { continue }
                p += pal[bi].transformPoint(vx.position) * w
                n += pal[bi].transformDir(vx.normal) * w
            }
            return (p + Vec3(0, 0.8, 0), vnormalize(n))
        }
        let cut: Float = broken ? rng.range(1.8, 3.0) : 99
        var t = 0
        let m = built.mesh
        while t + 2 < m.indices.count {
            let (pa, na) = skin(m.vertices[Int(m.indices[t])])
            let (pb, nb) = skin(m.vertices[Int(m.indices[t + 1])])
            let (pc, nc) = skin(m.vertices[Int(m.indices[t + 2])])
            t += 3
            if pa.y > cut && pb.y > cut && pc.y > cut { continue }
            b.triangle(pa, pb, pc, na: na, nb: nb, nc: nc)
        }
        // Greatsword held point-down in front, and the pedestal.
        var wv = WeaponVisual(type: "greatsword")
        wv.scale = 1.9
        let wm = WeaponCatalog.mesh(wv)
        let wx = Mat4.translation(Vec3(0, 0.8, 0)) * res.weaponR.matrix
        var i = 0
        while i + 2 < wm.indices.count {
            let a = wm.vertices[Int(wm.indices[i])], bb = wm.vertices[Int(wm.indices[i + 1])], c = wm.vertices[Int(wm.indices[i + 2])]
            b.triangle(wx.transformPoint(a.position), wx.transformPoint(bb.position), wx.transformPoint(c.position),
                       na: wx.transformDir(a.normal), nb: wx.transformDir(bb.normal), nc: wx.transformDir(c.normal))
            i += 3
        }
        b.box(center: Vec3(0, 0.4, 0), half: Vec3(1.0, 0.4, 1.0), bevel: 0.06)
        let col = srgbHex(0x7A756C)
        return (b, MaterialDesc(kind: .stone, color: col, roughness: 0.85, wear: 0.3, dirt: 0.7))
    }
}
