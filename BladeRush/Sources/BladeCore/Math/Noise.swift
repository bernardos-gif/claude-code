// Procedural noise: gradient (Perlin-style) noise with optional periodic tiling,
// simplex-like value noise, Worley (cellular) noise, fBm and domain warping.
// All functions are deterministic and seedable, used for textures, terrain,
// camera shake and audio.
import Foundation

public enum Noise {
    // MARK: Gradient noise (3D, periodic)

    @inlinable static func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }

    @inlinable static func grad(_ h: UInt32, _ x: Float, _ y: Float, _ z: Float) -> Float {
        // 12 edge directions of a cube (classic improved Perlin gradients).
        switch h % 12 {
        case 0: return x + y
        case 1: return -x + y
        case 2: return x - y
        case 3: return -x - y
        case 4: return x + z
        case 5: return -x + z
        case 6: return x - z
        case 7: return -x - z
        case 8: return y + z
        case 9: return -y + z
        case 10: return y - z
        default: return -y - z
        }
    }

    @inlinable static func wrap(_ i: Int32, _ period: Int32) -> Int32 {
        guard period > 0 else { return i }
        let m = i % period
        return m < 0 ? m + period : m
    }

    /// Gradient noise in roughly [-1, 1]. If `period` > 0 the noise tiles every `period` units.
    public static func perlin(_ p: Vec3, period: Int32 = 0, seed: UInt32 = 0) -> Float {
        let fx = p.x.rounded(.down), fy = p.y.rounded(.down), fz = p.z.rounded(.down)
        let xi = Int32(fx), yi = Int32(fy), zi = Int32(fz)
        let x = p.x - fx, y = p.y - fy, z = p.z - fz
        let u = fade(x), v = fade(y), w = fade(z)
        let x0 = wrap(xi, period), x1 = wrap(xi + 1, period)
        let y0 = wrap(yi, period), y1 = wrap(yi + 1, period)
        let z0 = wrap(zi, period), z1 = wrap(zi + 1, period)
        let n000 = grad(hash3i(x0, y0, z0, seed), x, y, z)
        let n100 = grad(hash3i(x1, y0, z0, seed), x - 1, y, z)
        let n010 = grad(hash3i(x0, y1, z0, seed), x, y - 1, z)
        let n110 = grad(hash3i(x1, y1, z0, seed), x - 1, y - 1, z)
        let n001 = grad(hash3i(x0, y0, z1, seed), x, y, z - 1)
        let n101 = grad(hash3i(x1, y0, z1, seed), x - 1, y, z - 1)
        let n011 = grad(hash3i(x0, y1, z1, seed), x, y - 1, z - 1)
        let n111 = grad(hash3i(x1, y1, z1, seed), x - 1, y - 1, z - 1)
        let nx00 = lerpf(n000, n100, u), nx10 = lerpf(n010, n110, u)
        let nx01 = lerpf(n001, n101, u), nx11 = lerpf(n011, n111, u)
        let nxy0 = lerpf(nx00, nx10, v), nxy1 = lerpf(nx01, nx11, v)
        return lerpf(nxy0, nxy1, w) * 0.95
    }

    @inlinable public static func perlin2(_ x: Float, _ y: Float, period: Int32 = 0, seed: UInt32 = 0) -> Float {
        perlin(Vec3(x, y, 0.5), period: period, seed: seed)
    }

    // MARK: Simplex (2D, non-periodic, used for animation / shake / audio)

    public static func simplex2(_ xin: Float, _ yin: Float, seed: UInt32 = 0) -> Float {
        let F2: Float = 0.366_025_4, G2: Float = 0.211_324_87
        let s = (xin + yin) * F2
        let i = (xin + s).rounded(.down), j = (yin + s).rounded(.down)
        let t = (i + j) * G2
        let x0 = xin - (i - t), y0 = yin - (j - t)
        let i1: Float = x0 > y0 ? 1 : 0, j1: Float = x0 > y0 ? 0 : 1
        let x1 = x0 - i1 + G2, y1 = y0 - j1 + G2
        let x2 = x0 - 1 + 2 * G2, y2 = y0 - 1 + 2 * G2
        let ii = Int32(i), jj = Int32(j)
        func g(_ h: UInt32, _ x: Float, _ y: Float) -> Float {
            let a = Float(h & 255) / 256 * kTwoPi
            return cos(a) * x + sin(a) * y
        }
        var n: Float = 0
        var t0 = 0.5 - x0 * x0 - y0 * y0
        if t0 > 0 { t0 *= t0; n += t0 * t0 * g(hash3i(ii, jj, 0, seed), x0, y0) }
        var t1 = 0.5 - x1 * x1 - y1 * y1
        if t1 > 0 { t1 *= t1; n += t1 * t1 * g(hash3i(ii + Int32(i1), jj + Int32(j1), 0, seed), x1, y1) }
        var t2 = 0.5 - x2 * x2 - y2 * y2
        if t2 > 0 { t2 *= t2; n += t2 * t2 * g(hash3i(ii + 1, jj + 1, 0, seed), x2, y2) }
        return 70 * n
    }

    // MARK: Worley / cellular

    /// Returns (F1, F2) distances to the nearest feature points (3D, optional period).
    public static func worley(_ p: Vec3, period: Int32 = 0, seed: UInt32 = 0) -> (Float, Float) {
        let fx = p.x.rounded(.down), fy = p.y.rounded(.down), fz = p.z.rounded(.down)
        let xi = Int32(fx), yi = Int32(fy), zi = Int32(fz)
        var f1: Float = 9, f2: Float = 9
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let cx = xi + Int32(dx), cy = yi + Int32(dy), cz = zi + Int32(dz)
                    let h = hash3i(wrap(cx, period), wrap(cy, period), wrap(cz, period), seed &+ 77)
                    let ox = hashFloat(h), oy = hashFloat(hash32(h ^ 0x68E3_1DA4)), oz = hashFloat(hash32(h ^ 0xB529_7A4D))
                    let d = Vec3(Float(cx) + ox, Float(cy) + oy, Float(cz) + oz) - p
                    let dist = vdot(d, d)
                    if dist < f1 { f2 = f1; f1 = dist } else if dist < f2 { f2 = dist }
                }
            }
        }
        return (f1.squareRoot(), f2.squareRoot())
    }

    // MARK: Fractal sums

    /// Fractal Brownian motion of gradient noise. Periodic if `period` > 0 (period doubles per octave).
    public static func fbm(_ p: Vec3, octaves: Int = 5, lacunarity: Float = 2, gain: Float = 0.5,
                           period: Int32 = 0, seed: UInt32 = 0) -> Float {
        var sum: Float = 0, amp: Float = 0.5, freq: Float = 1, norm: Float = 0
        var per = period
        for o in 0..<octaves {
            sum += amp * perlin(p * freq, period: per, seed: seed &+ UInt32(o) &* 1013)
            norm += amp
            amp *= gain
            freq *= lacunarity
            if per > 0 { per = Int32(Float(per) * lacunarity) }
        }
        return sum / norm
    }

    /// Ridged multifractal: sharp crests, good for cracks, veins, lightning-like patterns.
    public static func ridged(_ p: Vec3, octaves: Int = 5, period: Int32 = 0, seed: UInt32 = 0) -> Float {
        var sum: Float = 0, amp: Float = 0.5, freq: Float = 1, norm: Float = 0
        var per = period
        for o in 0..<octaves {
            let n = 1 - abs(perlin(p * freq, period: per, seed: seed &+ UInt32(o) &* 7919))
            sum += amp * n * n
            norm += amp
            amp *= 0.5
            freq *= 2
            if per > 0 { per *= 2 }
        }
        return sum / norm
    }

    /// Domain-warped fBm (Inigo Quilez style) for organic marbling and smoke.
    public static func warped(_ p: Vec3, strength: Float = 1.5, period: Int32 = 0, seed: UInt32 = 0) -> Float {
        let q = Vec3(fbm(p, octaves: 4, period: period, seed: seed),
                     fbm(p + Vec3(5.2, 1.3, 2.8), octaves: 4, period: period, seed: seed &+ 11),
                     fbm(p + Vec3(1.7, 9.2, 4.1), octaves: 4, period: period, seed: seed &+ 23))
        return fbm(p + q * strength, octaves: 5, period: period, seed: seed &+ 37)
    }
}
