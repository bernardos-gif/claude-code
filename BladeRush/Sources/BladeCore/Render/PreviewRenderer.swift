// Tiny CPU rasterizer used by BladeSim to render preview images of generated characters,
// weapons, poses and arenas without a GPU (useful for bug reports and for verifying
// procedural content on any machine).
import Foundation

public struct PreviewItem {
    public var mesh: MeshData
    public var model: Mat4
    public var palette: [Mat4]?
    public var colors: [Vec3]
    public var emissive: [Float]
    public init(mesh: MeshData, model: Mat4, palette: [Mat4]? = nil, colors: [Vec3], emissive: [Float] = []) {
        self.mesh = mesh; self.model = model; self.palette = palette; self.colors = colors; self.emissive = emissive
    }
}

public struct PreviewLine {
    public var a: Vec3
    public var b: Vec3
    public var color: Vec3
    public init(_ a: Vec3, _ b: Vec3, _ c: Vec3) { self.a = a; self.b = b; self.color = c }
}

public final class PreviewRenderer {
    public let width: Int
    public let height: Int
    public var image: ImageRGBA8
    var depth: [Float]
    public var background = Vec3(0.13, 0.13, 0.16)
    public var lightDir = vnormalize(Vec3(-0.5, 0.8, 0.6))

    public init(width: Int, height: Int) {
        self.width = width; self.height = height
        image = ImageRGBA8(width: width, height: height)
        depth = [Float](repeating: .infinity, count: width * height)
        clear()
    }

    public func clear() {
        for y in 0..<height {
            let t = Float(y) / Float(height)
            let c = vlerp(background * 1.3, background * 0.6, t)
            for x in 0..<width { image.set(x, y, Vec4(c, 1)) }
        }
        depth = [Float](repeating: .infinity, count: width * height)
    }

    /// Renders items into a viewport sub-rectangle (for grids of previews).
    public func render(_ items: [PreviewItem], lines: [PreviewLine] = [], eye: Vec3, target: Vec3, fov: Float = 35,
                       viewport: (Int, Int, Int, Int)? = nil) {
        let (vx, vy, vw, vh) = viewport ?? (0, 0, width, height)
        let view = Mat4.lookAt(eye: eye, target: target, up: Vec3(0, 1, 0))
        let proj = Mat4.perspective(fovyRadians: fov * kDeg2Rad, aspect: Float(vw) / Float(vh), near: 0.05, far: 100)
        let vp = proj * view
        for item in items {
            let m = item.mesh
            var sp = [Vec3](repeating: .zero, count: m.vertices.count)
            var wn = [Vec3](repeating: .zero, count: m.vertices.count)
            var ok = [Bool](repeating: true, count: m.vertices.count)
            for (i, v) in m.vertices.enumerated() {
                var p = v.position, n = v.normal
                if let pal = item.palette, m.skinned {
                    var pp = Vec3.zero, nn = Vec3.zero
                    for k in 0..<4 {
                        let b = Int((v.bones >> (8 * UInt32(k))) & 0xFF)
                        let w = Float((v.weights >> (8 * UInt32(k))) & 0xFF) / 255
                        if w <= 0 || b >= pal.count { continue }
                        pp += pal[b].transformPoint(p) * w
                        nn += pal[b].transformDir(n) * w
                    }
                    p = pp; n = nn
                }
                let wp = item.model.transformPoint(p)
                wn[i] = vnormalize(item.model.transformDir(n))
                let c = vp.transformPointProjective(wp)
                if c.w < 0.05 { ok[i] = false; continue }
                let ndc = c.xyz / c.w
                sp[i] = Vec3(Float(vx) + (ndc.x * 0.5 + 0.5) * Float(vw), Float(vy) + (1 - (ndc.y * 0.5 + 0.5)) * Float(vh), c.w)
            }
            let idx = m.indices
            var t = 0
            while t + 2 < idx.count {
                let i0 = Int(idx[t]), i1 = Int(idx[t + 1]), i2 = Int(idx[t + 2])
                t += 3
                guard ok[i0], ok[i1], ok[i2] else { continue }
                let a = sp[i0], b = sp[i1], c = sp[i2]
                let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                if area >= 0 { continue } // back-face (screen y is flipped)
                let va = m.vertices[i0], vb = m.vertices[i1], vc = m.vertices[i2]
                func shade(_ v: Vertex, _ n: Vec3) -> Vec3 {
                    let slot = min(v.materialSlot, item.colors.count - 1)
                    var base = slot >= 0 ? item.colors[slot] : Vec3(0.7, 0.7, 0.7)
                    let tint = Vec3(Float(v.color & 0xFF), Float((v.color >> 8) & 0xFF), Float((v.color >> 16) & 0xFF)) / 255
                    let ao = Float((v.color >> 24) & 0xFF) / 255
                    base *= tint
                    let ndl = max(0, vdot(n, lightDir))
                    let rim = pow(1 - max(0, vdot(n, vnormalize(eye - target))), 3) * 0.35
                    let em = slot < item.emissive.count ? item.emissive[slot] : 0
                    let edge = Float((v.attr >> 8) & 0xFF) / 255
                    var col = base * (0.25 + 0.85 * ndl) * (0.4 + 0.6 * ao) + Vec3(repeating: rim) + Vec3(repeating: edge * 0.08)
                    let emMask = Float((v.attr >> 16) & 0xFF) / 255
                    col += base * em * max(emMask, em > 0 ? 1 : 0)
                    return col
                }
                let ca = shade(va, wn[i0]), cb = shade(vb, wn[i1]), cc = shade(vc, wn[i2])
                let minX = max(vx, Int(min(a.x, min(b.x, c.x)))), maxX = min(vx + vw - 1, Int(max(a.x, max(b.x, c.x))) + 1)
                let minY = max(vy, Int(min(a.y, min(b.y, c.y)))), maxY = min(vy + vh - 1, Int(max(a.y, max(b.y, c.y))) + 1)
                if minX > maxX || minY > maxY { continue }
                let inv = 1 / area
                for y in minY...maxY {
                    for x in minX...maxX {
                        let px = Float(x) + 0.5, py = Float(y) + 0.5
                        let w0 = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) * inv
                        let w1 = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) * inv
                        let w2 = 1 - w0 - w1
                        if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                        let z = a.z * w0 + b.z * w1 + c.z * w2
                        let di = y * width + x
                        if z >= depth[di] { continue }
                        depth[di] = z
                        let col = ca * w0 + cb * w1 + cc * w2
                        let mapped = Vec3(1 - exp(-col.x * 1.4), 1 - exp(-col.y * 1.4), 1 - exp(-col.z * 1.4))
                        image.set(x, y, Vec4(linearToSrgb(mapped.x), linearToSrgb(mapped.y), linearToSrgb(mapped.z), 1))
                    }
                }
            }
        }
        for l in lines {
            let ca = vp.transformPointProjective(l.a), cb = vp.transformPointProjective(l.b)
            guard ca.w > 0.05, cb.w > 0.05 else { continue }
            let a = Vec2(Float(vx) + (ca.x / ca.w * 0.5 + 0.5) * Float(vw), Float(vy) + (1 - (ca.y / ca.w * 0.5 + 0.5)) * Float(vh))
            let b = Vec2(Float(vx) + (cb.x / cb.w * 0.5 + 0.5) * Float(vw), Float(vy) + (1 - (cb.y / cb.w * 0.5 + 0.5)) * Float(vh))
            let steps = Int(max(abs(b.x - a.x), abs(b.y - a.y))) + 1
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let p = a + (b - a) * t
                image.set(Int(p.x), Int(p.y), Vec4(l.color, 1))
            }
        }
    }
}
