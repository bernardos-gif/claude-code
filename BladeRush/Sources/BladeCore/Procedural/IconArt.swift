// The application icon, drawn in code with signed distance functions (no image assets):
// a katana crossing a blood moon inside a gold ring on a crimson-to-black squircle.
// Used by the app at runtime (dock icon) and by BladeSim to produce the .icns iconset.
import Foundation

public enum IconArt {
    private static func sdRoundBox(_ p: Vec2, _ half: Float, _ r: Float) -> Float {
        let q = Vec2(abs(p.x) - half + r, abs(p.y) - half + r)
        let outside = vlength2(Vec2(max(q.x, 0), max(q.y, 0)))
        return outside + min(max(q.x, q.y), 0) - r
    }

    /// Distance to segment ab and the parameter t of the closest point.
    private static func segment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> (Float, Float) {
        let pa = p - a, ba = b - a
        let t = saturatef(vdot2(pa, ba) / max(vdot2(ba, ba), 1e-8))
        return (vlength2(pa - ba * t), t)
    }

    private static func over(_ dst: inout Vec4, _ c: Vec3, _ a: Float) {
        let a = saturatef(a)
        let outA = a + dst.w * (1 - a)
        if outA <= 1e-6 { return }
        let rgb = (c * a + Vec3(dst.x, dst.y, dst.z) * dst.w * (1 - a)) / outA
        dst = Vec4(rgb, outA)
    }

    public static func render(size: Int) -> ImageRGBA8 {
        var img = ImageRGBA8(width: size, height: size, fill: (0, 0, 0, 0))
        let s = Float(size)
        let px = 1.5 / s
        func cov(_ d: Float) -> Float { saturatef(0.5 - d / px) }
        // Blade geometry (y down, unit square).
        let hiltA = Vec2(0.20, 0.84), hiltB = Vec2(0.31, 0.72)
        let tip = Vec2(0.83, 0.20)
        let bend = Vec2(0.035, 0.03)            // gentle katana curvature
        for y in 0..<size {
            for x in 0..<size {
                let p = Vec2((Float(x) + 0.5) / s, (Float(y) + 0.5) / s)
                let c = p - Vec2(0.5, 0.5)
                var col = Vec4(0, 0, 0, 0)
                // Squircle background.
                let dBox = sdRoundBox(c, 0.41, 0.095)
                let inBox = cov(dBox)
                if inBox <= 0 { continue }
                let g = saturatef(vdot2(c, Vec2(0.62, 0.78)) + 0.5)
                var bg = vlerp(Vec3(0.50, 0.05, 0.05), Vec3(0.035, 0.02, 0.03), smoothstepf(0.1, 0.95, g))
                bg += Vec3(0.25, 0.05, 0.02) * max(0, 0.35 - vlength2(c - Vec2(-0.1, -0.12))) * 1.2
                over(&col, bg, inBox)
                // Blood moon.
                let moonC = Vec2(0.60, 0.40)
                let dm = vlength2(p - moonC) - 0.19
                var moon = vlerp(Vec3(1.0, 0.55, 0.32), Vec3(0.85, 0.16, 0.08), saturatef(vlength2(p - moonC - Vec2(-0.06, -0.06)) / 0.25))
                // Soft darker maria.
                for (mc, mr) in [(Vec2(0.55, 0.36), Float(0.06)), (Vec2(0.66, 0.45), Float(0.05)), (Vec2(0.62, 0.30), Float(0.035))] {
                    moon *= 1 - 0.18 * saturatef(1 - vlength2(p - mc) / mr)
                }
                over(&col, moon, cov(dm) * inBox)
                over(&col, Vec3(1.0, 0.35, 0.15), max(0, 1 - max(dm, 0) / 0.06) * 0.35 * inBox)
                // Gold ring.
                let dr = abs(vlength2(c) - 0.33) - 0.011
                over(&col, Vec3(1.0, 0.78, 0.36), cov(dr) * inBox)
                // Blade: two curved segments with a tapering width.
                // Quadratic Bezier sampled as short segments (smooth curvature).
                let ctrl = (hiltB + tip) * 0.5 + bend
                var bestD: Float = 1e9, along: Float = 0
                let segs = 10
                var prev = hiltB
                for k in 1...segs {
                    let t = Float(k) / Float(segs)
                    let q = hiltB * ((1 - t) * (1 - t)) + ctrl * (2 * (1 - t) * t) + tip * (t * t)
                    let (d, st) = segment(p, prev, q)
                    if d < bestD { bestD = d; along = (Float(k - 1) + st) / Float(segs) }
                    prev = q
                }
                let width = 0.021 * (1 - along * 0.55) + 0.004
                let dBlade = bestD - width
                let steel = vlerp(Vec3(0.72, 0.75, 0.82), Vec3(0.97, 0.98, 1.0), saturatef(0.5 + (p.x - p.y) * 1.5))
                over(&col, steel, cov(dBlade) * inBox)
                // Hamon edge highlight.
                over(&col, Vec3(1, 1, 1), cov(abs(bestD - width * 0.45) - 0.0025) * 0.8 * cov(dBlade) * inBox)
                // Tsuba (guard).
                let dg = vlength2(p - hiltB) - 0.042
                over(&col, Vec3(0.55, 0.40, 0.14), cov(dg) * inBox)
                over(&col, Vec3(0.12, 0.08, 0.05), cov(vlength2(p - hiltB) - 0.02) * inBox)
                // Handle with a diamond wrap.
                let (dh, th) = segment(p, hiltA, hiltB)
                let dHandle = dh - 0.026
                let wrap = abs(sin(th * 26)) > 0.55 ? Vec3(0.08, 0.05, 0.05) : Vec3(0.75, 0.55, 0.2)
                over(&col, wrap, cov(dHandle) * inBox)
                // Slash streak.
                let arcD = abs(vlength2(p - Vec2(0.3, 0.95)) - 0.62) - 0.004 * (1 - saturatef((p.x - 0.35) * 2))
                let arcMask = saturatef((p.x - 0.18) * 4) * saturatef((0.86 - p.x) * 6) * saturatef((0.62 - p.y) * 6)
                over(&col, Vec3(1.0, 0.9, 0.85), cov(arcD) * arcMask * 0.9 * inBox)
                img.set(x, y, col)
            }
        }
        return img
    }
}
