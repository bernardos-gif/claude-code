// 4x4 column-major matrix, memory compatible with Metal's float4x4.
import Foundation

public struct Mat4: Equatable {
    public var c0: Vec4
    public var c1: Vec4
    public var c2: Vec4
    public var c3: Vec4

    @inlinable public init(_ c0: Vec4, _ c1: Vec4, _ c2: Vec4, _ c3: Vec4) {
        self.c0 = c0; self.c1 = c1; self.c2 = c2; self.c3 = c3
    }

    public static let identity = Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1))

    @inlinable public static func * (a: Mat4, b: Mat4) -> Mat4 {
        Mat4(a * b.c0, a * b.c1, a * b.c2, a * b.c3)
    }

    @inlinable public static func * (m: Mat4, v: Vec4) -> Vec4 {
        m.c0 * v.x + m.c1 * v.y + m.c2 * v.z + m.c3 * v.w
    }

    @inlinable public func transformPoint(_ p: Vec3) -> Vec3 {
        let r = c0 * p.x + c1 * p.y + c2 * p.z + c3
        return Vec3(r.x, r.y, r.z)
    }

    @inlinable public func transformPointProjective(_ p: Vec3) -> Vec4 {
        c0 * p.x + c1 * p.y + c2 * p.z + c3
    }

    @inlinable public func transformDir(_ d: Vec3) -> Vec3 {
        let r = c0 * d.x + c1 * d.y + c2 * d.z
        return Vec3(r.x, r.y, r.z)
    }

    @inlinable public var translation: Vec3 {
        get { Vec3(c3.x, c3.y, c3.z) }
        set { c3 = Vec4(newValue.x, newValue.y, newValue.z, c3.w) }
    }

    @inlinable public var transposed: Mat4 {
        Mat4(Vec4(c0.x, c1.x, c2.x, c3.x),
             Vec4(c0.y, c1.y, c2.y, c3.y),
             Vec4(c0.z, c1.z, c2.z, c3.z),
             Vec4(c0.w, c1.w, c2.w, c3.w))
    }

    @inlinable public static func translation(_ t: Vec3) -> Mat4 {
        Mat4(Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(t.x, t.y, t.z, 1))
    }

    @inlinable public static func scale(_ s: Vec3) -> Mat4 {
        Mat4(Vec4(s.x, 0, 0, 0), Vec4(0, s.y, 0, 0), Vec4(0, 0, s.z, 0), Vec4(0, 0, 0, 1))
    }

    @inlinable public static func rotationY(_ a: Float) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(Vec4(c, 0, -s, 0), Vec4(0, 1, 0, 0), Vec4(s, 0, c, 0), Vec4(0, 0, 0, 1))
    }

    @inlinable public static func rotationX(_ a: Float) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(Vec4(1, 0, 0, 0), Vec4(0, c, s, 0), Vec4(0, -s, c, 0), Vec4(0, 0, 0, 1))
    }

    @inlinable public static func rotationZ(_ a: Float) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(Vec4(c, s, 0, 0), Vec4(-s, c, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1))
    }

    /// Translation * Rotation * Scale.
    @inlinable public static func trs(_ t: Vec3, _ r: Quat, _ s: Vec3 = Vec3(1, 1, 1)) -> Mat4 {
        var m = r.matrix
        m.c0 *= s.x; m.c1 *= s.y; m.c2 *= s.z
        m.c0.w = 0; m.c1.w = 0; m.c2.w = 0
        m.c3 = Vec4(t.x, t.y, t.z, 1)
        return m
    }

    /// Right-handed perspective projection mapping view-space depth to Metal's [0, 1] clip range.
    public static func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let ys = 1 / tan(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return Mat4(Vec4(xs, 0, 0, 0), Vec4(0, ys, 0, 0), Vec4(0, 0, zs, -1), Vec4(0, 0, zs * near, 0))
    }

    /// Right-handed orthographic projection with Metal's [0, 1] depth range.
    public static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> Mat4 {
        let rl = right - left, tb = top - bottom, fn = far - near
        return Mat4(Vec4(2 / rl, 0, 0, 0),
                    Vec4(0, 2 / tb, 0, 0),
                    Vec4(0, 0, -1 / fn, 0),
                    Vec4(-(right + left) / rl, -(top + bottom) / tb, -near / fn, 1))
    }

    /// Right-handed look-at view matrix (camera looks down -Z in view space).
    public static func lookAt(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
        let f = vnormalize(target - eye)
        var s = vcross(f, up)
        if vlengthSq(s) < 1e-8 { s = vcross(f, Vec3(0, 0, 1)) }
        s = vnormalize(s)
        let u = vcross(s, f)
        return Mat4(Vec4(s.x, u.x, -f.x, 0),
                    Vec4(s.y, u.y, -f.y, 0),
                    Vec4(s.z, u.z, -f.z, 0),
                    Vec4(-vdot(s, eye), -vdot(u, eye), vdot(f, eye), 1))
    }

    /// General 4x4 inverse (cofactor expansion). Returns identity for singular input.
    public var inverse: Mat4 {
        let m = [c0.x, c0.y, c0.z, c0.w, c1.x, c1.y, c1.z, c1.w, c2.x, c2.y, c2.z, c2.w, c3.x, c3.y, c3.z, c3.w]
        var inv = [Float](repeating: 0, count: 16)
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
        let det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
        if abs(det) < 1e-20 { return .identity }
        let d = 1 / det
        return Mat4(Vec4(inv[0], inv[1], inv[2], inv[3]) * d,
                    Vec4(inv[4], inv[5], inv[6], inv[7]) * d,
                    Vec4(inv[8], inv[9], inv[10], inv[11]) * d,
                    Vec4(inv[12], inv[13], inv[14], inv[15]) * d)
    }

    /// Fast inverse for rigid transforms (rotation + translation, uniform scale 1).
    @inlinable public var rigidInverse: Mat4 {
        let r0 = Vec3(c0.x, c1.x, c2.x), r1 = Vec3(c0.y, c1.y, c2.y), r2 = Vec3(c0.z, c1.z, c2.z)
        let t = translation
        return Mat4(Vec4(r0.x, r1.x, r2.x, 0), Vec4(r0.y, r1.y, r2.y, 0), Vec4(r0.z, r1.z, r2.z, 0),
                    Vec4(-vdot(r0, t), -vdot(r1, t), -vdot(r2, t), 1))
    }

    /// Upper-left 3x3 as columns.
    @inlinable public var axisX: Vec3 { Vec3(c0.x, c0.y, c0.z) }
    @inlinable public var axisY: Vec3 { Vec3(c1.x, c1.y, c1.z) }
    @inlinable public var axisZ: Vec3 { Vec3(c2.x, c2.y, c2.z) }
}
