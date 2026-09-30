// Tileable procedural textures generated at load time (and cached on disk).
// Materials sample them triplanarly in the shader and combine channels per material
// family (metal, stone, wood, leather, fabric, ice, obsidian, bone, moss...).
//
//   detailA (RGBA8): R = fBm Perlin (large blotches), G = Worley F2-F1 (cells / cracks),
//                    B = high-frequency fBm (grain), A = anisotropic scratches / fibers
//   detailN (RGBA8): RG = tangent normal from a medium bump height (hammered / stone),
//                    BA = tangent normal from a fine height (weave / pores)
import Foundation

public struct TextureData {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]   // RGBA8
}

public enum TextureGen {
    public static let size = 512
    static let cacheVersion = 3

    public static func detailTextures() -> (TextureData, TextureData) {
        let a = cached("detailA") { generateDetailA(size: size) }
        let n = cached("detailN") { generateDetailN(size: size) }
        return (a, n)
    }

    static func cached(_ name: String, _ make: () -> TextureData) -> TextureData {
        let url = Paths.cache.appendingPathComponent("\(name)_v\(cacheVersion)_\(size).rgba")
        if let d = try? Data(contentsOf: url), d.count == size * size * 4 {
            return TextureData(width: size, height: size, pixels: [UInt8](d))
        }
        let t = timed("generate texture \(name)", "load") { make() }
        Paths.ensureDirectories()
        try? Data(t.pixels).write(to: url)
        return t
    }

    /// Parallel per-row fill helper.
    static func fill(size: Int, _ f: @escaping (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: size) { y in
                for x in 0..<size {
                    let (r, g, b, a) = f(x, y)
                    let i = (y * size + x) * 4
                    buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = a
                }
            }
        }
        return px
    }

    static func u8(_ v: Float) -> UInt8 { UInt8(saturatef(v) * 255 + 0.5) }

    public static func generateDetailA(size: Int) -> TextureData {
        let s = Float(size)
        let px = fill(size: size) { x, y in
            let u = Float(x) / s, v = Float(y) / s
            let big = Noise.fbm(Vec3(u * 4, v * 4, 0.37), octaves: 5, period: 4, seed: 11) * 0.5 + 0.5
            let (f1, f2) = Noise.worley(Vec3(u * 8, v * 8, 0.5), period: 8, seed: 3)
            let cells = saturatef((f2 - f1) * 1.6)
            let grain = Noise.fbm(Vec3(u * 32, v * 32, 0.71), octaves: 3, period: 32, seed: 29) * 0.5 + 0.5
            // Scratches: stretched noise lines along x.
            let sc = Noise.perlin(Vec3(u * 3, v * 96, 0.2), period: 3, seed: 41)
            let sc2 = Noise.perlin(Vec3(u * 96, v * 5, 0.9), period: 96, seed: 43)
            let scratch = saturatef(pow(max(abs(sc), abs(sc2) * 0.7) * 1.8, 6))
            return (u8(big), u8(cells), u8(grain), u8(scratch))
        }
        return TextureData(width: size, height: size, pixels: px)
    }

    public static func generateDetailN(size: Int) -> TextureData {
        let s = Float(size)
        // Heights first, then normals by central differences (wrapping).
        var h1 = [Float](repeating: 0, count: size * size)
        var h2 = [Float](repeating: 0, count: size * size)
        h1.withUnsafeMutableBufferPointer { b1 in
            h2.withUnsafeMutableBufferPointer { b2 in
                DispatchQueue.concurrentPerform(iterations: size) { y in
                    for x in 0..<size {
                        let u = Float(x) / s, v = Float(y) / s
                        let (f1, f2) = Noise.worley(Vec3(u * 6, v * 6, 0.3), period: 6, seed: 5)
                        let hammered = f1 * 0.6 + Noise.fbm(Vec3(u * 8, v * 8, 0.1), octaves: 4, period: 8, seed: 17) * 0.3
                        b1[y * size + x] = hammered + saturatef((f2 - f1) * 4) * 0.25
                        let weaveU = sin(u * kTwoPi * 64) * 0.5 + 0.5, weaveV = sin(v * kTwoPi * 64) * 0.5 + 0.5
                        let checker = (Int(u * 64) + Int(v * 64)) % 2 == 0 ? weaveU : weaveV
                        let pores = Noise.fbm(Vec3(u * 48, v * 48, 0.6), octaves: 3, period: 48, seed: 23)
                        b2[y * size + x] = checker * 0.5 + pores * 0.5
                    }
                }
            }
        }
        func normal(_ h: [Float], _ x: Int, _ y: Int, _ strength: Float) -> (UInt8, UInt8) {
            let xl = h[y * size + (x + size - 1) % size], xr = h[y * size + (x + 1) % size]
            let yd = h[((y + size - 1) % size) * size + x], yu = h[((y + 1) % size) * size + x]
            let n = vnormalize(Vec3((xl - xr) * strength, (yd - yu) * strength, 1))
            return (u8(n.x * 0.5 + 0.5), u8(n.y * 0.5 + 0.5))
        }
        let px = fill(size: size) { x, y in
            let (a, b) = normal(h1, x, y, 18)
            let (c, d) = normal(h2, x, y, 10)
            return (a, b, c, d)
        }
        return TextureData(width: size, height: size, pixels: px)
    }
}
