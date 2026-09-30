// Hard-surface mesh construction: beveled boxes, lathes, lofts, extrusions, spheres,
// tori, cylinders. Geometry is emitted flat, then welded and smoothed by crease angle,
// which also marks sharp edges for the edge-wear shader mask.
import Foundation

public struct MeshBuilder {
    public var positions: [Vec3] = []
    public var faceNormals: [Vec3] = []   // one per triangle
    public var triMaterial: [UInt8] = []
    public var triColor: [Vec3] = []
    public var triEmissive: [Float] = []
    public var triEdge: [Float] = []      // extra wear (bevels)
    public var triBone: [UInt8] = []
    /// Per-corner explicit normals (nil = use face normal before smoothing).
    public var cornerNormals: [Vec3?] = []

    public var material: Int = 0
    public var color = Vec3(1, 1, 1)
    public var emissive: Float = 0
    public var edgeBoost: Float = 0
    public var bone: Int = 0
    public var transform: Mat4 = .identity

    public init() {}

    // MARK: - Primitives

    public mutating func triangle(_ a: Vec3, _ b: Vec3, _ c: Vec3, na: Vec3? = nil, nb: Vec3? = nil, nc: Vec3? = nil) {
        let pa = transform.transformPoint(a), pb = transform.transformPoint(b), pc = transform.transformPoint(c)
        let n = vcross(pb - pa, pc - pa)
        if vlengthSq(n) < 1e-16 { return }
        positions += [pa, pb, pc]
        faceNormals.append(vnormalize(n))
        triMaterial.append(UInt8(material))
        triColor.append(color)
        triEmissive.append(emissive)
        triEdge.append(edgeBoost)
        triBone.append(UInt8(bone))
        let t = transform
        func tn(_ v: Vec3?) -> Vec3? { v.map { vnormalize(t.transformDir($0)) } }
        cornerNormals += [tn(na), tn(nb), tn(nc)]
    }

    public mutating func quad(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) {
        triangle(a, b, c)
        triangle(a, c, d)
    }

    /// Rounded (beveled) box built from a subdivided cube projected onto a rounded box.
    public mutating func box(center: Vec3, half h: Vec3, rot: Quat = .identity, bevel: Float = 0.01, segments: Int = 3) {
        let b = min(bevel, min(h.x, min(h.y, h.z)) * 0.95)
        let inner = h - Vec3(repeating: b)
        let n = max(1, segments)
        // Grid per face includes extra rows near the edges for the bevel.
        func coords(_ half: Float, _ inner: Float) -> [Float] {
            var c: [Float] = [-half]
            for i in 1...n { c.append(-inner - b + b * Float(i) / Float(n)) }
            if inner > 1e-5 { c.append(inner) }
            for i in 1...n { c.append(inner + b * Float(i) / Float(n)) }
            // Deduplicate / sort.
            return Array(Set(c.map { ($0 * 1e5).rounded() / 1e5 })).sorted()
        }
        let cx = coords(h.x, inner.x), cy = coords(h.y, inner.y), cz = coords(h.z, inner.z)
        func project(_ p: Vec3) -> (Vec3, Vec3, Float) {
            let cl = Vec3(clampf(p.x, -inner.x, inner.x), clampf(p.y, -inner.y, inner.y), clampf(p.z, -inner.z, inner.z))
            let d = p - cl
            let l = vlength(d)
            if l < 1e-6 { return (p, .zero, 0) }
            let nn = d / l
            return (cl + nn * b, nn, 1)
        }
        let saveT = transform
        transform = transform * Mat4.trs(center, rot)
        let saveEdge = edgeBoost
        // Six faces: (axis, sign).
        let faces: [(Int, Float)] = [(0, 1), (0, -1), (1, 1), (1, -1), (2, 1), (2, -1)]
        for (axis, sgn) in faces {
            let (ua, va): (Int, Int) = axis == 0 ? (1, 2) : (axis == 1 ? (2, 0) : (0, 1))
            let us = [cx, cy, cz][ua], vs = [cx, cy, cz][va]
            let fixed = [h.x, h.y, h.z][axis] * sgn
            for i in 0..<(us.count - 1) {
                for j in 0..<(vs.count - 1) {
                    func P(_ u: Float, _ v: Float) -> Vec3 {
                        var p = Vec3.zero
                        p[axis] = fixed; p[ua] = u; p[va] = v
                        return p
                    }
                    let raw = [P(us[i], vs[j]), P(us[i + 1], vs[j]), P(us[i + 1], vs[j + 1]), P(us[i], vs[j + 1])]
                    let pr = raw.map(project)
                    let wear = pr.map { $0.2 }.reduce(0, +) / 4
                    edgeBoost = saveEdge + wear * 0.8
                    var fn = Vec3.zero; fn[axis] = sgn
                    let ns = pr.map { vlengthSq($0.1) > 0 ? $0.1 : fn }
                    if sgn > 0 {
                        triangle(pr[0].0, pr[1].0, pr[2].0, na: ns[0], nb: ns[1], nc: ns[2])
                        triangle(pr[0].0, pr[2].0, pr[3].0, na: ns[0], nb: ns[2], nc: ns[3])
                    } else {
                        triangle(pr[0].0, pr[2].0, pr[1].0, na: ns[0], nb: ns[2], nc: ns[1])
                        triangle(pr[0].0, pr[3].0, pr[2].0, na: ns[0], nb: ns[3], nc: ns[2])
                    }
                }
            }
        }
        edgeBoost = saveEdge
        transform = saveT
    }

    /// Surface of revolution around the local +Z axis. Profile: (radius, z) from bottom to top.
    public mutating func lathe(_ profile: [(Float, Float)], segments: Int = 16, center: Vec3 = .zero, rot: Quat = .identity,
                               capBottom: Bool = true, capTop: Bool = true, radiusScale: Vec2 = Vec2(1, 1)) {
        guard profile.count >= 2 else { return }
        let saveT = transform
        transform = transform * Mat4.trs(center, rot)
        func P(_ i: Int, _ s: Int) -> Vec3 {
            let a = Float(s) / Float(segments) * kTwoPi
            let (r, z) = profile[i]
            return Vec3(cos(a) * r * radiusScale.x, sin(a) * r * radiusScale.y, z)
        }
        for i in 0..<(profile.count - 1) {
            for s in 0..<segments {
                let a = P(i, s), b = P(i, s + 1), c = P(i + 1, s + 1), d = P(i + 1, s)
                quad(a, b, c, d)
            }
        }
        if capBottom, profile[0].0 > 1e-4 {
            let cz = Vec3(0, 0, profile[0].1)
            for s in 0..<segments { triangle(cz, P(0, s + 1), P(0, s)) }
        }
        let last = profile.count - 1
        if capTop, profile[last].0 > 1e-4 {
            let cz = Vec3(0, 0, profile[last].1)
            for s in 0..<segments { triangle(cz, P(last, s), P(last, s + 1)) }
        }
        transform = saveT
    }

    /// Cylinder / cone between two points.
    public mutating func cylinder(from a: Vec3, to b: Vec3, r0: Float, r1: Float, segments: Int = 12, caps: Bool = true) {
        let d = b - a
        let len = vlength(d)
        guard len > 1e-6 else { return }
        let rot = Quat.fromTo(Vec3(0, 0, 1), d / len)
        lathe([(r0, 0), (r1, len)], segments: segments, center: a, rot: rot, capBottom: caps, capTop: caps)
    }

    public mutating func sphere(center: Vec3, radius: Float, segments: Int = 12, scale: Vec3 = Vec3(1, 1, 1), rot: Quat = .identity) {
        var prof: [(Float, Float)] = []
        let rings = max(4, segments / 2 + 1)
        for i in 0...rings {
            let t = Float(i) / Float(rings) * kPi
            prof.append((sin(t) * radius, -cos(t) * radius))
        }
        let saveT = transform
        transform = transform * Mat4.trs(center, rot) * Mat4.scale(scale)
        lathe(prof, segments: segments, capBottom: false, capTop: false)
        transform = saveT
    }

    public mutating func torus(center: Vec3, majorR: Float, minorR: Float, rot: Quat = .identity, segments: Int = 20, sides: Int = 8, arc: Float = kTwoPi) {
        let saveT = transform
        transform = transform * Mat4.trs(center, rot)
        func P(_ i: Int, _ j: Int) -> Vec3 {
            let u = Float(i) / Float(segments) * arc
            let v = Float(j) / Float(sides) * kTwoPi
            let r = majorR + minorR * cos(v)
            return Vec3(cos(u) * r, sin(u) * r, minorR * sin(v))
        }
        for i in 0..<segments {
            for j in 0..<sides {
                quad(P(i, j), P(i + 1, j), P(i + 1, j + 1), P(i, j + 1))
            }
        }
        transform = saveT
    }

    /// Connects closed rings of points (each ring same count). Rings run along the shape.
    public mutating func loft(_ rings: [[Vec3]], capStart: Bool = true, capEnd: Bool = true) {
        guard rings.count >= 2, let n = rings.first?.count, n >= 3 else { return }
        for r in 0..<(rings.count - 1) {
            let A = rings[r], B = rings[r + 1]
            for j in 0..<n {
                let j1 = (j + 1) % n
                quad(A[j], A[j1], B[j1], B[j])
            }
        }
        if capStart { fan(rings[0].reversed()) }
        if capEnd { fan(rings[rings.count - 1]) }
    }

    /// Triangle fan around the centroid (convex-ish polygons).
    public mutating func fan(_ pts: [Vec3]) {
        guard pts.count >= 3 else { return }
        let c = pts.reduce(Vec3.zero, +) / Float(pts.count)
        for i in 0..<pts.count { triangle(c, pts[i], pts[(i + 1) % pts.count]) }
    }

    /// Extrudes a 2D polygon (in local YZ plane, counter-clockwise seen from +X) along X,
    /// with per-point half thickness (lets axe heads taper to a sharp edge).
    public mutating func extrude(_ poly0: [Vec2], thickness thickness0: [Float], center: Vec3 = .zero, rot: Quat = .identity) {
        let n = poly0.count
        guard n >= 3, thickness0.count == n else { return }
        var area: Float = 0
        for i in 0..<n { let a = poly0[i], b = poly0[(i + 1) % n]; area += a.x * b.y - b.x * a.y }
        let poly = area >= 0 ? poly0 : Array(poly0.reversed())
        let thickness = area >= 0 ? thickness0 : Array(thickness0.reversed())
        let saveT = transform
        transform = transform * Mat4.trs(center, rot)
        let top = (0..<n).map { Vec3(thickness[$0], poly[$0].x, poly[$0].y) }
        let bot = (0..<n).map { Vec3(-thickness[$0], poly[$0].x, poly[$0].y) }
        let tris = MeshBuilder.triangulate(poly)
        for t in tris {
            triangle(top[t.0], top[t.1], top[t.2])
            triangle(bot[t.0], bot[t.2], bot[t.1])
        }
        for i in 0..<n {
            let j = (i + 1) % n
            quad(bot[i], bot[j], top[j], top[i])
        }
        transform = saveT
    }

    /// Ear-clipping triangulation of a simple polygon (CCW or CW).
    public static func triangulate(_ poly: [Vec2]) -> [(Int, Int, Int)] {
        var idx = Array(0..<poly.count)
        var area: Float = 0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            area += a.x * b.y - b.x * a.y
        }
        let ccw = area > 0
        var result: [(Int, Int, Int)] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < 10000 {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = poly[i0], b = poly[i1], c = poly[i2]
                let cr = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                if (cr > 0) != ccw || abs(cr) < 1e-12 { continue }
                var inside = false
                for m in idx where m != i0 && m != i1 && m != i2 {
                    if MeshBuilder.pointInTri(poly[m], a, b, c) { inside = true; break }
                }
                if inside { continue }
                result.append(ccw ? (i0, i1, i2) : (i0, i2, i1))
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { result.append(ccw ? (idx[0], idx[1], idx[2]) : (idx[0], idx[2], idx[1])) }
        return result
    }

    static func pointInTri(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        func s(_ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> Float { (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y) }
        let d1 = s(p, a, b), d2 = s(p, b, c), d3 = s(p, c, a)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }

    /// Appends another builder's geometry.
    public mutating func append(_ o: MeshBuilder) {
        positions += o.positions; faceNormals += o.faceNormals; triMaterial += o.triMaterial
        triColor += o.triColor; triEmissive += o.triEmissive; triEdge += o.triEdge; triBone += o.triBone
        cornerNormals += o.cornerNormals
    }

    // MARK: - Finalize

    /// Welds vertices and smooths normals across edges sharper than `creaseDeg` are kept hard.
    public func build(name: String, creaseDeg: Float = 40, skinned: Bool = false) -> MeshData {
        let triCount = faceNormals.count
        let cosCrease = cos(creaseDeg * kDeg2Rad)
        // Group corners by quantized position.
        var groups: [SIMD3<Int32>: [Int]] = [:]
        groups.reserveCapacity(positions.count)
        let q: Float = 1e4
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int32>(Int32((p.x * q).rounded()), Int32((p.y * q).rounded()), Int32((p.z * q).rounded()))
            groups[key, default: []].append(i)
        }
        var normals = [Vec3](repeating: .zero, count: positions.count)
        var sharp = [Float](repeating: 0, count: positions.count)
        for (_, corners) in groups {
            for c in corners {
                let fn = faceNormals[c / 3]
                if let explicit = cornerNormals[c] { normals[c] = explicit; continue }
                var acc = Vec3.zero
                var hasSharp = false
                for o in corners {
                    let on = faceNormals[o / 3]
                    let d = vdot(fn, on)
                    if d >= cosCrease { acc += on } else if d < 0.95 { hasSharp = true }
                }
                normals[c] = vnormalize(acc, fallback: fn)
                if hasSharp { sharp[c] = 1 }
            }
        }
        // Deduplicate identical corners.
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(positions.count / 2)
        indices.reserveCapacity(positions.count)
        struct Key: Hashable { var p: SIMD3<Int32>; var n: SIMD3<Int32>; var a: UInt32; var c: UInt32 }
        var map: [Key: UInt32] = [:]
        for t in 0..<triCount {
            for k in 0..<3 {
                let c = t * 3 + k
                let p = positions[c], n = normals[c]
                let edge = saturatef(sharp[c] + triEdge[t])
                let attr = Vertex.packAttr(material: Int(triMaterial[t]), edge: edge, emissive: triEmissive[t])
                let col = Vertex.packColor(triColor[t], ao: 1)
                let key = Key(p: SIMD3<Int32>(Int32((p.x * q).rounded()), Int32((p.y * q).rounded()), Int32((p.z * q).rounded())),
                              n: SIMD3<Int32>(Int32(n.x * 1000), Int32(n.y * 1000), Int32(n.z * 1000)), a: attr, c: col)
                if let e = map[key] { indices.append(e); continue }
                let v = Vertex(p: p, n: n, color: col, bones: UInt32(triBone[t]), weights: 255, attr: attr)
                let id = UInt32(vertices.count)
                vertices.append(v)
                map[key] = id
                indices.append(id)
            }
        }
        return MeshData(name: name, vertices: vertices, indices: indices, skinned: skinned)
    }
}

extension MeshData {
    /// Merges meshes into one (indices re-based).
    public static func merge(_ meshes: [MeshData], name: String) -> MeshData {
        var v: [Vertex] = []
        var i: [UInt32] = []
        for m in meshes {
            let base = UInt32(v.count)
            v += m.vertices
            i += m.indices.map { $0 + base }
        }
        return MeshData(name: name, vertices: v, indices: i, skinned: meshes.contains { $0.skinned })
    }

    /// Returns a transformed copy.
    public func transformed(_ m: Mat4, name: String? = nil) -> MeshData {
        let v = vertices.map { vx -> Vertex in
            var o = vx
            o.position = m.transformPoint(vx.position)
            o.normal = vnormalize(m.transformDir(vx.normal))
            return o
        }
        return MeshData(name: name ?? self.name, vertices: v, indices: indices, skinned: skinned)
    }
}
