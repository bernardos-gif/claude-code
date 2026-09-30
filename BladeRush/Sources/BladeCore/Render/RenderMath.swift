// Platform-independent renderer math: TAA jitter, cascaded shadow map fitting and frustum
// culling. Lives in BladeCore so it is unit-tested without a GPU.
import Foundation

public enum RenderMath {
    /// Radical inverse in the given base (Halton sequence).
    public static func halton(_ index: Int, _ base: Int) -> Float {
        var f: Float = 1, r: Float = 0, i = index
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }

    /// Sub-pixel jitter in pixels (x right, y down), in [-0.5, 0.5), 8-sample Halton(2, 3).
    public static func jitter(frame: Int) -> Vec2 {
        let i = (frame % 8) + 1
        return Vec2(halton(i, 2) - 0.5, halton(i, 3) - 0.5)
    }

    /// Applies a pixel jitter to a perspective projection (render target size in pixels).
    public static func jittered(_ proj: Mat4, pixels j: Vec2, width: Float, height: Float) -> Mat4 {
        var p = proj
        let nx = j.x * 2 / max(width, 1)
        let ny = -j.y * 2 / max(height, 1)
        // clip.w = -z for a right-handed perspective, so subtracting from column 2 shifts NDC by +n.
        p.c2.x -= nx
        p.c2.y -= ny
        return p
    }

    public struct Cascades {
        public var viewProj: [Mat4]
        public var splits: [Float]
        public var texelWorld: [Float]
    }

    /// Fits one orthographic light projection per view-frustum slice using a bounding sphere
    /// (rotation-stable) snapped to the shadow-map texel grid (translation-stable).
    public static func cascades(view: Mat4, proj: Mat4, near: Float, splits: [Float], sunDir: Vec3, shadowSize: Int,
                                casterDistance: Float = 80) -> Cascades {
        let invView = view.inverse
        let tanX = 1 / proj.c0.x
        let tanY = 1 / proj.c1.y
        let k2 = tanX * tanX + tanY * tanY
        let toSun = vnormalize(sunDir)
        let up = abs(toSun.y) > 0.99 ? Vec3(0, 0, 1) : Vec3(0, 1, 0)
        let lightRot = Mat4.lookAt(eye: .zero, target: -toSun, up: up)
        var out = Cascades(viewProj: [], splits: splits, texelWorld: [])
        var n = near
        for f in splits {
            var zc = 0.5 * (n + f) * (1 + k2)
            var r: Float
            if zc > f {
                zc = f
                r = sqrt((zc - n) * (zc - n) + n * n * k2)
                r = max(r, sqrt(f * f * k2))
            } else {
                r = max(sqrt((zc - n) * (zc - n) + n * n * k2), sqrt((f - zc) * (f - zc) + f * f * k2))
            }
            r = (r * 4).rounded(.up) / 4 + 0.25
            let centerWorld = invView.transformPoint(Vec3(0, 0, -zc))
            let lc = lightRot.transformPoint(centerWorld)
            let texel = 2 * r / Float(max(shadowSize, 1))
            let cx = (lc.x / texel).rounded(.down) * texel
            let cy = (lc.y / texel).rounded(.down) * texel
            let ortho = Mat4.orthographic(left: cx - r, right: cx + r, bottom: cy - r, top: cy + r,
                                          near: -lc.z - r - casterDistance, far: -lc.z + r)
            out.viewProj.append(ortho * lightRot)
            out.texelWorld.append(texel)
            n = f
        }
        return out
    }

    /// Frustum planes (xyz normal pointing inside, w distance) for a Metal-style [0, 1] depth projection.
    public static func frustumPlanes(_ m: Mat4) -> [Vec4] {
        let r0 = Vec4(m.c0.x, m.c1.x, m.c2.x, m.c3.x)
        let r1 = Vec4(m.c0.y, m.c1.y, m.c2.y, m.c3.y)
        let r2 = Vec4(m.c0.z, m.c1.z, m.c2.z, m.c3.z)
        let r3 = Vec4(m.c0.w, m.c1.w, m.c2.w, m.c3.w)
        let planes = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
        return planes.map { p in
            let l = vlength(Vec3(p.x, p.y, p.z))
            return l > 1e-8 ? p / l : p
        }
    }

    public static func sphereVisible(_ planes: [Vec4], center c: Vec3, radius: Float) -> Bool {
        for p in planes where p.x * c.x + p.y * c.y + p.z * c.z + p.w < -radius { return false }
        return true
    }

    /// World-space bounding sphere of a mesh under a model matrix (uses the largest axis scale).
    public static func boundingSphere(center: Vec3, radius: Float, model: Mat4) -> (Vec3, Float) {
        let s = max(vlength(model.axisX), max(vlength(model.axisY), vlength(model.axisZ)))
        return (model.transformPoint(center), radius * s)
    }
}
