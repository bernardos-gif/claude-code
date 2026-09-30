// Unit quaternion rotations.
import Foundation

public struct Quat: Equatable, Codable {
    public var x: Float, y: Float, z: Float, w: Float

    @inlinable public init(x: Float, y: Float, z: Float, w: Float) { self.x = x; self.y = y; self.z = z; self.w = w }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    @inlinable public init(axis: Vec3, angle: Float) {
        let a = vnormalize(axis)
        let s = sin(angle * 0.5)
        self.init(x: a.x * s, y: a.y * s, z: a.z * s, w: cos(angle * 0.5))
    }

    /// Euler angles in radians, composed in the parent frame as: roll about Z first,
    /// then pitch about X, then yaw about Y (q = qY * qX * qZ). This is the convention
    /// used by all pose data in Data/poses.json (which is authored in degrees).
    @inlinable public static func euler(_ x: Float, _ y: Float, _ z: Float) -> Quat {
        Quat(axis: Vec3(0, 1, 0), angle: y) * Quat(axis: Vec3(1, 0, 0), angle: x) * Quat(axis: Vec3(0, 0, 1), angle: z)
    }

    @inlinable public static func eulerDeg(_ v: Vec3) -> Quat {
        euler(v.x * kDeg2Rad, v.y * kDeg2Rad, v.z * kDeg2Rad)
    }

    @inlinable public static func yaw(_ a: Float) -> Quat { Quat(axis: Vec3(0, 1, 0), angle: a) }

    @inlinable public static func * (a: Quat, b: Quat) -> Quat {
        Quat(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
             w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }

    @inlinable public var conjugate: Quat { Quat(x: -x, y: -y, z: -z, w: w) }

    @inlinable public var normalized: Quat {
        let l = (x * x + y * y + z * z + w * w).squareRoot()
        return l > 1e-12 ? Quat(x: x / l, y: y / l, z: z / l, w: w / l) : .identity
    }

    @inlinable public func rotate(_ v: Vec3) -> Vec3 {
        let u = Vec3(x, y, z)
        let t = 2 * vcross(u, v)
        return v + w * t + vcross(u, t)
    }

    @inlinable public static func dot(_ a: Quat, _ b: Quat) -> Float { a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w }

    /// Normalized linear interpolation along the shortest path. Great for pose blending.
    @inlinable public static func nlerp(_ a: Quat, _ b: Quat, _ t: Float) -> Quat {
        let s: Float = dot(a, b) < 0 ? -1 : 1
        return Quat(x: a.x + (b.x * s - a.x) * t, y: a.y + (b.y * s - a.y) * t,
                    z: a.z + (b.z * s - a.z) * t, w: a.w + (b.w * s - a.w) * t).normalized
    }

    /// Spherical interpolation along the shortest path.
    public static func slerp(_ a: Quat, _ b0: Quat, _ t: Float) -> Quat {
        var b = b0
        var cosT = dot(a, b)
        if cosT < 0 { b = Quat(x: -b.x, y: -b.y, z: -b.z, w: -b.w); cosT = -cosT }
        if cosT > 0.9995 { return nlerp(a, b, t) }
        let theta = acos(cosT)
        let s = sin(theta)
        let wa = sin((1 - t) * theta) / s, wb = sin(t * theta) / s
        return Quat(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb, z: a.z * wa + b.z * wb, w: a.w * wa + b.w * wb)
    }

    /// Shortest rotation taking unit vector `from` onto unit vector `to`.
    public static func fromTo(_ from: Vec3, _ to: Vec3) -> Quat {
        let f = vnormalize(from), t = vnormalize(to)
        let d = vdot(f, t)
        if d > 0.99999 { return .identity }
        if d < -0.99999 {
            var axis = vcross(Vec3(1, 0, 0), f)
            if vlengthSq(axis) < 1e-6 { axis = vcross(Vec3(0, 1, 0), f) }
            return Quat(axis: axis, angle: kPi)
        }
        let c = vcross(f, t)
        return Quat(x: c.x, y: c.y, z: c.z, w: 1 + d).normalized
    }

    /// Rotation whose +Z axis points along `forward` and +Y roughly along `up`.
    public static func lookRotation(forward: Vec3, up: Vec3 = Vec3(0, 1, 0)) -> Quat {
        let f = vnormalize(forward)
        var r = vcross(up, f)
        if vlengthSq(r) < 1e-8 { r = vcross(Vec3(1, 0, 0), f) }
        r = vnormalize(r)
        let u = vcross(f, r)
        return Quat.fromMatrixColumns(r, u, f)
    }

    /// Builds a quaternion from orthonormal basis columns.
    public static func fromMatrixColumns(_ cx: Vec3, _ cy: Vec3, _ cz: Vec3) -> Quat {
        let m00 = cx.x, m11 = cy.y, m22 = cz.z
        let trace = m00 + m11 + m22
        var q: Quat
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = Quat(x: (cy.z - cz.y) / s, y: (cz.x - cx.z) / s, z: (cx.y - cy.x) / s, w: 0.25 * s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            q = Quat(x: 0.25 * s, y: (cy.x + cx.y) / s, z: (cz.x + cx.z) / s, w: (cy.z - cz.y) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            q = Quat(x: (cy.x + cx.y) / s, y: 0.25 * s, z: (cz.y + cy.z) / s, w: (cz.x - cx.z) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            q = Quat(x: (cz.x + cx.z) / s, y: (cz.y + cy.z) / s, z: 0.25 * s, w: (cx.y - cy.x) / s)
        }
        return q.normalized
    }

    @inlinable public var matrix: Mat4 {
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        let wx = w * x, wy = w * y, wz = w * z
        return Mat4(Vec4(1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0),
                    Vec4(2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0),
                    Vec4(2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0),
                    Vec4(0, 0, 0, 1))
    }

    /// Scales the rotation angle (used for additive layers with weights).
    public func scaled(_ t: Float) -> Quat { Quat.nlerp(.identity, self, t) }
}

/// Position / rotation / scale transform.
public struct Transform: Equatable {
    public var position: Vec3
    public var rotation: Quat
    public var scale: Vec3

    public init(position: Vec3 = .zero, rotation: Quat = .identity, scale: Vec3 = Vec3(1, 1, 1)) {
        self.position = position; self.rotation = rotation; self.scale = scale
    }

    public static let identity = Transform()

    @inlinable public var matrix: Mat4 { Mat4.trs(position, rotation, scale) }
}
