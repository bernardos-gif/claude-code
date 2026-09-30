// Signed distance field modeling. Characters, statues and organic props are composed
// from smooth-blended primitives (Inigo Quilez formulas), then polygonized with
// Surface Nets (SurfaceNets.swift). Each primitive carries a bone assignment, material
// slot, tint and emissive flag so the extracted mesh is fully skinned and shaded.
import Foundation

public struct SDFPrim {
    public enum Kind { case sphere, ellipsoid, capsule, roundCone, box, torus, cylinder, cone, plane }
    public enum Op { case union, subtract, intersect }

    public var kind: Kind
    public var op: Op = .union
    public var a: Vec3 = .zero            // center, or segment start
    public var b: Vec3 = .zero            // segment end
    public var r1: Float = 0.1
    public var r2: Float = 0.1
    public var size: Vec3 = Vec3(0.1, 0.1, 0.1)   // box half extents / ellipsoid radii / torus (R, r, _) / cylinder (r, halfH, _)
    public var rot: Quat = .identity      // local orientation (box, ellipsoid, torus, cylinder, cone)
    public var rounding: Float = 0
    public var blend: Float = 0.02        // smooth blend radius with what came before
    public var shell: Float = 0           // > 0: hollow shell of this thickness
    public var noiseAmp: Float = 0
    public var noiseFreq: Float = 8
    public var material: Int = 0
    public var tint: Vec3 = Vec3(1, 1, 1)
    public var emissive: Float = 0
    public var bone: Int = 0
    public var bone2: Int = -1            // blend along a->b from `bone` to `bone2`
    public var skirt = false              // weight between pelvis and thighs by position
    /// Contributes to skin weights / material ownership (false for pure cut shapes).
    public var owns = true
    /// Clip planes applied to this primitive only: keeps points with dot(n, p) - d <= 0.
    public var clips: [Vec4] = []

    var invRot: Quat = .identity
    public var boundsMin: Vec3 = .zero
    public var boundsMax: Vec3 = .zero

    public init(kind: Kind) { self.kind = kind }

    // MARK: Factories

    public static func sphere(_ c: Vec3, _ r: Float) -> SDFPrim {
        var p = SDFPrim(kind: .sphere); p.a = c; p.r1 = r; return p
    }
    public static func ellipsoid(_ c: Vec3, _ radii: Vec3, rot: Quat = .identity) -> SDFPrim {
        var p = SDFPrim(kind: .ellipsoid); p.a = c; p.size = radii; p.rot = rot; return p
    }
    public static func capsule(_ a: Vec3, _ b: Vec3, _ r: Float) -> SDFPrim {
        var p = SDFPrim(kind: .capsule); p.a = a; p.b = b; p.r1 = r; return p
    }
    public static func roundCone(_ a: Vec3, _ b: Vec3, _ r1: Float, _ r2: Float) -> SDFPrim {
        var p = SDFPrim(kind: .roundCone); p.a = a; p.b = b; p.r1 = r1; p.r2 = r2; return p
    }
    public static func box(_ c: Vec3, _ half: Vec3, rot: Quat = .identity, rounding: Float = 0.01) -> SDFPrim {
        var p = SDFPrim(kind: .box); p.a = c; p.size = half; p.rot = rot; p.rounding = rounding; return p
    }
    /// Torus around the local Y axis: size.x = major radius, size.y = minor radius.
    public static func torus(_ c: Vec3, major: Float, minor: Float, rot: Quat = .identity) -> SDFPrim {
        var p = SDFPrim(kind: .torus); p.a = c; p.size = Vec3(major, minor, 0); p.rot = rot; return p
    }
    /// Capped cylinder along local Y: size.x = radius, size.y = half height.
    public static func cylinder(_ c: Vec3, radius: Float, halfHeight: Float, rot: Quat = .identity, rounding: Float = 0.005) -> SDFPrim {
        var p = SDFPrim(kind: .cylinder); p.a = c; p.size = Vec3(radius, halfHeight, 0); p.rot = rot; p.rounding = rounding; return p
    }
    /// Capped cone along local Y: radius r1 at y = -halfHeight, r2 at y = +halfHeight.
    public static func cone(_ c: Vec3, halfHeight: Float, r1: Float, r2: Float, rot: Quat = .identity) -> SDFPrim {
        var p = SDFPrim(kind: .cone); p.a = c; p.size = Vec3(0, halfHeight, 0); p.r1 = r1; p.r2 = r2; p.rot = rot; return p
    }
    /// Half-space below a plane through `point` with outward normal `n` (use with subtract/intersect).
    public static func plane(_ point: Vec3, normal n: Vec3) -> SDFPrim {
        var p = SDFPrim(kind: .plane); p.a = point; p.b = vnormalize(n); p.owns = false; return p
    }

    // MARK: Builders (chainable)

    public func mat(_ m: Int) -> SDFPrim { var p = self; p.material = m; return p }
    public func bone(_ b: Bone, _ b2: Bone? = nil) -> SDFPrim { var p = self; p.bone = b.rawValue; p.bone2 = b2?.rawValue ?? -1; return p }
    public func blend(_ k: Float) -> SDFPrim { var p = self; p.blend = k; return p }
    public func tint(_ c: Vec3) -> SDFPrim { var p = self; p.tint = c; return p }
    public func glow(_ e: Float = 1) -> SDFPrim { var p = self; p.emissive = e; return p }
    public func subtract(_ k: Float = 0.005) -> SDFPrim { var p = self; p.op = .subtract; p.blend = k; p.owns = false; return p }
    public func intersect(_ k: Float = 0.005) -> SDFPrim { var p = self; p.op = .intersect; p.blend = k; p.owns = false; return p }
    public func noise(_ amp: Float, _ freq: Float) -> SDFPrim { var p = self; p.noiseAmp = amp; p.noiseFreq = freq; return p }
    public func hollow(_ t: Float) -> SDFPrim { var p = self; p.shell = t; return p }
    public func asSkirt() -> SDFPrim { var p = self; p.skirt = true; return p }
    /// Keeps only the part of this primitive on the side opposite to `normal` from `point`.
    public func clip(_ point: Vec3, _ normal: Vec3) -> SDFPrim {
        var p = self
        let n = vnormalize(normal)
        p.clips.append(Vec4(n, vdot(n, point)))
        return p
    }

    // MARK: Distance

    mutating func prepare() {
        invRot = rot.conjugate
        var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
        func add(_ q: Vec3) { lo = vmin(lo, q); hi = vmax(hi, q) }
        switch kind {
        case .sphere:
            add(a - Vec3(repeating: r1)); add(a + Vec3(repeating: r1))
        case .capsule:
            add(vmin(a, b) - Vec3(repeating: r1)); add(vmax(a, b) + Vec3(repeating: r1))
        case .roundCone:
            let r = max(r1, r2)
            add(vmin(a, b) - Vec3(repeating: r)); add(vmax(a, b) + Vec3(repeating: r))
        case .ellipsoid, .box:
            let e = vmaxComp(size) + rounding
            add(a - Vec3(repeating: e * 1.01)); add(a + Vec3(repeating: e * 1.01))
        case .torus:
            let e = size.x + size.y
            add(a - Vec3(repeating: e)); add(a + Vec3(repeating: e))
        case .cylinder:
            let e = (size.x * size.x + size.y * size.y).squareRoot() + rounding
            add(a - Vec3(repeating: e)); add(a + Vec3(repeating: e))
        case .cone:
            let e = (max(r1, r2) * max(r1, r2) + size.y * size.y).squareRoot()
            add(a - Vec3(repeating: e)); add(a + Vec3(repeating: e))
        case .plane:
            add(Vec3(repeating: -1e6)); add(Vec3(repeating: 1e6))
        }
        let pad = blend + noiseAmp * 1.5 + shell
        boundsMin = lo - Vec3(repeating: pad)
        boundsMax = hi + Vec3(repeating: pad)
    }

    /// Lower bound of the distance from p to this primitive's bounds.
    @inlinable func boundsDistance(_ p: Vec3) -> Float {
        let d = vmax(boundsMin - p, p - boundsMax)
        return max(d.x, max(d.y, d.z))
    }

    func distance(_ p: Vec3) -> Float {
        var d: Float
        switch kind {
        case .sphere:
            d = vlength(p - a) - r1
        case .capsule:
            d = vlength(p - Geometry.closestPointOnSegment(p, a, b)) - r1
        case .roundCone:
            d = SDFPrim.roundCone(p, a, b, r1, r2)
        case .ellipsoid:
            let q = invRot.rotate(p - a)
            let k0 = vlength(q / size)
            let k1 = vlength(q / (size * size))
            d = k1 > 1e-8 ? k0 * (k0 - 1) / k1 : -vmaxComp(size)
        case .box:
            let q = vabs(invRot.rotate(p - a)) - size + Vec3(repeating: rounding)
            d = vlength(vmax(q, .zero)) + min(max(q.x, max(q.y, q.z)), 0) - rounding
        case .torus:
            let q = invRot.rotate(p - a)
            let t = Vec2(vlength2(Vec2(q.x, q.z)) - size.x, q.y)
            d = vlength2(t) - size.y
        case .cylinder:
            let q = invRot.rotate(p - a)
            let dd = Vec2(vlength2(Vec2(q.x, q.z)) - size.x + rounding, abs(q.y) - size.y + rounding)
            d = min(max(dd.x, dd.y), 0) + vlength2(vmax2(dd, .zero)) - rounding
        case .cone:
            let q = invRot.rotate(p - a)
            d = SDFPrim.cappedCone(q, size.y, r1, r2)
        case .plane:
            d = vdot(p - a, b)
        }
        if shell > 0 { d = abs(d) - shell }
        if noiseAmp > 0 { d += noiseAmp * Noise.perlin(p * noiseFreq, seed: 5) }
        for c in clips { d = max(d, vdot(c.xyz, p) - c.w) }
        return d
    }

    @inlinable func vmax2(_ a: Vec2, _ b: Vec2) -> Vec2 { pointwiseMax(a, b) }

    static func roundCone(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ r1: Float, _ r2: Float) -> Float {
        let ba = b - a
        let l2 = vdot(ba, ba)
        if l2 < 1e-10 { return vlength(p - a) - max(r1, r2) }
        let rr = r1 - r2
        let a2 = l2 - rr * rr
        let il2 = 1 / l2
        let pa = p - a
        let y = vdot(pa, ba)
        let z = y - l2
        let xv = pa * l2 - ba * y
        let x2 = vdot(xv, xv)
        let y2 = y * y * l2
        let z2 = z * z * l2
        let k = signf(rr) * rr * rr * x2
        if signf(z) * a2 * z2 > k { return (x2 + z2).squareRoot() * il2 - r2 }
        if signf(y) * a2 * y2 < k { return (x2 + y2).squareRoot() * il2 - r1 }
        return ((x2 * a2 * il2).squareRoot() + y * rr) * il2 - r1
    }

    static func cappedCone(_ p: Vec3, _ h: Float, _ r1: Float, _ r2: Float) -> Float {
        let q = Vec2(vlength2(Vec2(p.x, p.z)), p.y)
        let k1 = Vec2(r2, h)
        let k2 = Vec2(r2 - r1, 2 * h)
        let ca = Vec2(q.x - min(q.x, q.y < 0 ? r1 : r2), abs(q.y) - h)
        let t = saturatef(vdot2(k1 - q, k2) / vdot2(k2, k2))
        let cb = q - k1 + k2 * t
        let s: Float = (cb.x < 0 && ca.y < 0) ? -1 : 1
        return s * min(vdot2(ca, ca), vdot2(cb, cb)).squareRoot()
    }
}

@inlinable func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
    if k <= 0 { return min(a, b) }
    let h = max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
}

@inlinable func smax(_ a: Float, _ b: Float, _ k: Float) -> Float { -smin(-a, -b, k) }

/// A composed SDF model.
public final class SDFModel {
    public private(set) var prims: [SDFPrim] = []
    public private(set) var boundsMin = Vec3(repeating: .infinity)
    public private(set) var boundsMax = Vec3(repeating: -.infinity)
    /// Softness of skin-weight blending between primitives (meters).
    public var weightFalloff: Float = 0.025

    public init() {}

    public func add(_ p0: SDFPrim) {
        var p = p0
        p.prepare()
        prims.append(p)
        if p.op == .union && p.kind != .plane {
            boundsMin = vmin(boundsMin, p.boundsMin)
            boundsMax = vmax(boundsMax, p.boundsMax)
        }
    }

    public func add(_ ps: [SDFPrim]) { for p in ps { add(p) } }

    public var isEmpty: Bool { prims.isEmpty }

    /// Signed distance only.
    public func distance(_ p: Vec3) -> Float {
        var d: Float = 1e9
        for pr in prims {
            switch pr.op {
            case .union:
                if pr.boundsDistance(p) > d + pr.blend { continue }
                d = smin(d, pr.distance(p), pr.blend)
            case .subtract:
                if pr.boundsDistance(p) > pr.blend { continue }
                d = smax(d, -pr.distance(p), pr.blend)
            case .intersect:
                d = smax(d, pr.distance(p), pr.blend)
            }
        }
        return d
    }

    /// Signed distance plus the index of the primitive owning the surface at p.
    public func distanceOwner(_ p: Vec3) -> (Float, Int) {
        var d: Float = 1e9
        var owner = 0
        var ownerD: Float = 1e9
        for (i, pr) in prims.enumerated() {
            switch pr.op {
            case .union:
                if pr.boundsDistance(p) > d + pr.blend { continue }
                let di = pr.distance(p)
                // Later primitives win ties slightly (armor over skin).
                if di < ownerD + pr.blend * 0.15 { owner = i; ownerD = min(ownerD, di) }
                d = smin(d, di, pr.blend)
            case .subtract:
                if pr.boundsDistance(p) > pr.blend { continue }
                d = smax(d, -pr.distance(p), pr.blend)
            case .intersect:
                d = smax(d, pr.distance(p), pr.blend)
            }
        }
        return (d, owner)
    }

    /// Skin weights at a surface point: soft ownership of nearby primitives mapped to bones.
    public func skinWeights(_ p: Vec3) -> [(Int, Float)] {
        var acc = [Float](repeating: 0, count: Bone.count)
        var best: Float = 1e9
        var cand: [(Int, Float)] = []
        for (i, pr) in prims.enumerated() where pr.op == .union && pr.owns {
            if pr.boundsDistance(p) > best + weightFalloff * 5 { continue }
            let di = pr.distance(p)
            cand.append((i, di))
            best = min(best, di)
        }
        for (i, di) in cand {
            let rel = di - best
            if rel > weightFalloff * 5 { continue }
            let w = exp(-rel / weightFalloff)
            let pr = prims[i]
            if pr.skirt {
                // Robes / skirts: follow pelvis near the waist, legs further down.
                let side = saturatef(abs(p.x) / 0.14)
                let down = saturatef((pr.a.y - p.y) / max(0.3, pr.a.y - pr.b.y))
                let legW = side * down * 0.75
                let thigh = p.x >= 0 ? Bone.thighL.rawValue : Bone.thighR.rawValue
                acc[Bone.pelvis.rawValue] += w * (1 - legW)
                acc[thigh] += w * legW
            } else if pr.bone2 >= 0 {
                let ab = pr.b - pr.a
                let t = saturatef(vdot(p - pr.a, ab) / max(vdot(ab, ab), 1e-8))
                let tt = smoothstepf(0.25, 0.95, t)
                acc[pr.bone] += w * (1 - tt)
                acc[pr.bone2] += w * tt
            } else {
                acc[pr.bone] += w
            }
        }
        var list: [(Int, Float)] = []
        for (b, w) in acc.enumerated() where w > 1e-4 { list.append((b, w)) }
        list.sort { $0.1 > $1.1 }
        if list.count > 4 { list = Array(list.prefix(4)) }
        let total = list.reduce(0) { $0 + $1.1 }
        if total <= 0 { return [(0, 1)] }
        return list.map { ($0.0, $0.1 / total) }
    }

    public func gradient(_ p: Vec3, h: Float) -> Vec3 {
        let dx = distance(p + Vec3(h, 0, 0)) - distance(p - Vec3(h, 0, 0))
        let dy = distance(p + Vec3(0, h, 0)) - distance(p - Vec3(0, h, 0))
        let dz = distance(p + Vec3(0, 0, h)) - distance(p - Vec3(0, 0, h))
        return vnormalize(Vec3(dx, dy, dz), fallback: Vec3(0, 1, 0))
    }
}
