// Collision geometry used by combat hit detection and the camera.
import Foundation

/// A capsule: the set of points within `radius` of segment [a, b].
public struct Capsule: Equatable {
    public var a: Vec3
    public var b: Vec3
    public var radius: Float
    public init(_ a: Vec3, _ b: Vec3, _ radius: Float) { self.a = a; self.b = b; self.radius = radius }
    public var center: Vec3 { (a + b) * 0.5 }
}

public struct Sphere: Equatable {
    public var center: Vec3
    public var radius: Float
    public init(_ c: Vec3, _ r: Float) { center = c; radius = r }
}

public enum Geometry {
    /// Closest point on segment [a, b] to point p.
    @inlinable public static func closestPointOnSegment(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> Vec3 {
        let ab = b - a
        let denom = vdot(ab, ab)
        if denom < 1e-12 { return a }
        let t = saturatef(vdot(p - a, ab) / denom)
        return a + ab * t
    }

    /// Closest points between segments [p1, q1] and [p2, q2] (Ericson, RTCD 5.1.9).
    /// Returns (pointOnFirst, pointOnSecond).
    public static func closestPointsSegments(_ p1: Vec3, _ q1: Vec3, _ p2: Vec3, _ q2: Vec3) -> (Vec3, Vec3) {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = vdot(d1, d1), e = vdot(d2, d2), f = vdot(d2, r)
        let eps: Float = 1e-10
        var s: Float = 0, t: Float = 0
        if a <= eps && e <= eps { return (p1, p2) }
        if a <= eps {
            s = 0; t = saturatef(f / e)
        } else {
            let c = vdot(d1, r)
            if e <= eps {
                t = 0; s = saturatef(-c / a)
            } else {
                let b = vdot(d1, d2)
                let denom = a * e - b * b
                s = denom != 0 ? saturatef((b * f - c * e) / denom) : 0
                t = (b * s + f) / e
                if t < 0 { t = 0; s = saturatef(-c / a) } else if t > 1 { t = 1; s = saturatef((b - c) / a) }
            }
        }
        return (p1 + d1 * s, p2 + d2 * t)
    }

    /// Capsule vs capsule overlap; returns contact point (midway between closest points) if overlapping.
    public static func capsuleOverlap(_ c1: Capsule, _ c2: Capsule) -> Vec3? {
        let (p, q) = closestPointsSegments(c1.a, c1.b, c2.a, c2.b)
        let r = c1.radius + c2.radius
        let d2 = vlengthSq(p - q)
        guard d2 <= r * r else { return nil }
        let d = d2.squareRoot()
        if d < 1e-6 { return p }
        // Point on surface of c1 toward c2, blended to the midpoint of the gap.
        let n = (q - p) / d
        return p + n * min(c1.radius, d * 0.5 + (c1.radius - c2.radius) * 0.5)
    }

    public static func sphereCapsuleOverlap(_ s: Sphere, _ c: Capsule) -> Vec3? {
        let p = closestPointOnSegment(s.center, c.a, c.b)
        let r = s.radius + c.radius
        guard vlengthSq(p - s.center) <= r * r else { return nil }
        return vlerp(p, s.center, 0.5)
    }

    /// Swept capsule test: the weapon capsule moves from `from` to `to` during one step.
    /// We sub-sample the motion so very fast swings never tunnel through thin targets.
    public static func sweptCapsuleOverlap(from: Capsule, to: Capsule, target: Capsule, substeps: Int) -> Vec3? {
        let n = max(1, substeps)
        for i in 0...n {
            let t = Float(i) / Float(n)
            let c = Capsule(vlerp(from.a, to.a, t), vlerp(from.b, to.b, t), from.radius)
            if let hit = capsuleOverlap(c, target) { return hit }
        }
        return nil
    }

    /// Number of substeps needed so no point on the capsule moves more than `maxStep`.
    public static func sweepSubsteps(from: Capsule, to: Capsule, maxStep: Float) -> Int {
        let m = max(vlength(to.a - from.a), vlength(to.b - from.b))
        return min(16, max(1, Int((m / max(maxStep, 1e-4)).rounded(.up))))
    }

    /// Ray vs sphere: distance along ray or nil.
    public static func raySphere(origin: Vec3, dir: Vec3, center: Vec3, radius: Float) -> Float? {
        let oc = origin - center
        let b = vdot(oc, dir)
        let c = vdot(oc, oc) - radius * radius
        let h = b * b - c
        if h < 0 { return nil }
        let t = -b - h.squareRoot()
        return t >= 0 ? t : nil
    }

    /// Ray vs vertical infinite cylinder (XZ circle) clipped to [y0, y1]. Returns entry distance.
    public static func rayVerticalCylinder(origin: Vec3, dir: Vec3, center: Vec2, radius: Float, y0: Float, y1: Float) -> Float? {
        let o = Vec2(origin.x - center.x, origin.z - center.y)
        let d = Vec2(dir.x, dir.z)
        let a = vdot2(d, d)
        if a < 1e-10 { return nil }
        let b = vdot2(o, d)
        let c = vdot2(o, o) - radius * radius
        let h = b * b - a * c
        if h < 0 { return nil }
        let t = (-b - h.squareRoot()) / a
        if t < 0 { return nil }
        let y = origin.y + dir.y * t
        return (y >= y0 && y <= y1) ? t : nil
    }

    /// Distance from point to the XZ circle boundary of an arena (positive inside).
    @inlinable public static func insideCircle(_ p: Vec3, radius: Float) -> Float {
        radius - vlength2(p.xz)
    }
}

/// Critically damped spring for smooth camera motion (frame-rate independent).
public struct SpringVec3 {
    public var value: Vec3
    public var velocity: Vec3 = .zero
    public init(_ v: Vec3) { value = v }

    /// `halfLife` is the time for the distance to target to halve.
    public mutating func update(target: Vec3, halfLife: Float, dt: Float) {
        let y = 4 * 0.693_147_2 / max(halfLife, 1e-5) / 2  // damping / 2
        let j0 = value - target
        let j1 = velocity + j0 * y
        let eydt = exp(-y * dt)
        value = eydt * (j0 + j1 * dt) + target
        velocity = eydt * (velocity - j1 * y * dt)
    }
}

public struct SpringFloat {
    public var value: Float
    public var velocity: Float = 0
    public init(_ v: Float) { value = v }
    public mutating func update(target: Float, halfLife: Float, dt: Float) {
        let y = 4 * 0.693_147_2 / max(halfLife, 1e-5) / 2
        let j0 = value - target
        let j1 = velocity + j0 * y
        let eydt = exp(-y * dt)
        value = eydt * (j0 + j1 * dt) + target
        velocity = eydt * (velocity - j1 * y * dt)
    }
}
