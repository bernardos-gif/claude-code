// Position-based cloth (Verlet integration + distance constraints) for capes, scarves,
// robes tails and banners, and Verlet chains for flexible weapons and hair.
import Foundation

public final class ClothSim {
    public let cols: Int
    public let rows: Int
    public private(set) var pos: [Vec3]
    private var prev: [Vec3]
    private var invMass: [Float]
    private struct Link { var a: Int; var b: Int; var rest: Float; var stiffness: Float }
    private var links: [Link] = []
    public var colliders: [Capsule] = []
    public var damping: Float = 0.985
    public var gravity = Vec3(0, -9.8, 0)
    public var wind = Vec3.zero
    public var iterations = 6
    /// Column lengths (tattered capes have ragged bottoms).
    public private(set) var colLength: [Int]
    public var material: MaterialDesc
    public let spacing: Vec2
    private var initialized = false
    private var time: Float = 0

    public init(cols: Int, rows: Int, width: Float, length: Float, tattered: Bool, material: MaterialDesc, seed: UInt64 = 1) {
        self.cols = cols; self.rows = rows
        self.material = material
        spacing = Vec2(width / Float(max(cols - 1, 1)), length / Float(max(rows - 1, 1)))
        pos = [Vec3](repeating: .zero, count: cols * rows)
        prev = pos
        invMass = [Float](repeating: 1, count: cols * rows)
        var rng = Rng(seed: seed)
        colLength = (0..<cols).map { _ in tattered ? rows - rng.int(0, rows / 3) : rows }
        for r in 0..<rows {
            for c in 0..<cols {
                let i = r * cols + c
                if r == 0 { invMass[i] = 0 }
                if c + 1 < cols { links.append(Link(a: i, b: i + 1, rest: spacing.x, stiffness: 1)) }
                if r + 1 < rows { links.append(Link(a: i, b: i + cols, rest: spacing.y, stiffness: 1)) }
                if c + 1 < cols && r + 1 < rows {
                    let d = (spacing.x * spacing.x + spacing.y * spacing.y).squareRoot()
                    links.append(Link(a: i, b: i + cols + 1, rest: d, stiffness: 0.5))
                    links.append(Link(a: i + 1, b: i + cols, rest: d, stiffness: 0.5))
                }
                if r + 2 < rows { links.append(Link(a: i, b: i + 2 * cols, rest: spacing.y * 2, stiffness: 0.3)) }
            }
        }
    }

    /// Places the cloth hanging straight down from the pinned row.
    public func reset(pins: [Vec3], down: Vec3) {
        for r in 0..<rows {
            for c in 0..<cols {
                let p = pins[min(c, pins.count - 1)] + down * (Float(r) * spacing.y)
                pos[r * cols + c] = p
                prev[r * cols + c] = p
            }
        }
        initialized = true
    }

    /// Advances the simulation. `pins` are world positions for the top row (one per column).
    public func step(dt: Float, pins: [Vec3], down: Vec3, groundY: Float = 0) {
        if !initialized { reset(pins: pins, down: down) }
        let sub = 2
        let h = min(dt, 1.0 / 30.0) / Float(sub)
        time += dt
        for _ in 0..<sub {
            for c in 0..<cols { pos[c] = pins[min(c, pins.count - 1)]; prev[c] = pos[c] }
            let gust = wind * (0.6 + 0.4 * sin(time * 1.7)) + Vec3(sin(time * 3.1), 0, cos(time * 2.3)) * vlength(wind) * 0.15
            for i in 0..<pos.count where invMass[i] > 0 {
                let v = (pos[i] - prev[i]) * damping
                prev[i] = pos[i]
                pos[i] += v + (gravity + gust) * h * h
            }
            for _ in 0..<iterations {
                for l in links {
                    let d = pos[l.b] - pos[l.a]
                    let len = vlength(d)
                    if len < 1e-6 { continue }
                    let wa = invMass[l.a], wb = invMass[l.b]
                    let w = wa + wb
                    if w <= 0 { continue }
                    let corr = d * ((len - l.rest) / (len * w)) * l.stiffness
                    pos[l.a] += corr * wa
                    pos[l.b] -= corr * wb
                }
                // Body collisions (capsules) and ground.
                for i in 0..<pos.count where invMass[i] > 0 {
                    for cap in colliders {
                        let q = Geometry.closestPointOnSegment(pos[i], cap.a, cap.b)
                        let dv = pos[i] - q
                        let dl = vlength(dv)
                        let r = cap.radius + 0.02
                        if dl < r && dl > 1e-6 { pos[i] = q + dv * (r / dl) }
                    }
                    if pos[i].y < groundY + 0.02 { pos[i].y = groundY + 0.02 }
                }
            }
        }
    }

    /// Two-sided mesh of the current state (world space).
    public func mesh(name: String = "cloth") -> MeshData {
        var verts: [Vertex] = []
        var idx: [UInt32] = []
        verts.reserveCapacity(cols * rows * 2)
        var normals = [Vec3](repeating: .zero, count: pos.count)
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let i = r * cols + c
                let n = vcross(pos[i + cols] - pos[i], pos[i + 1] - pos[i])
                normals[i] += n; normals[i + 1] += n; normals[i + cols] += n; normals[i + cols + 1] += n
            }
        }
        let attr = Vertex.packAttr(material: 0, edge: 0, emissive: 0)
        for side in 0..<2 {
            let s: Float = side == 0 ? 1 : -1
            for (i, p) in pos.enumerated() {
                let r = i / cols
                let ao: Float = 0.75 + 0.25 * Float(r) / Float(rows)
                verts.append(Vertex(p: p, n: vnormalize(normals[i], fallback: Vec3(0, 0, 1)) * s,
                                    color: Vertex.packColor(Vec3(1, 1, 1), ao: ao), attr: attr))
            }
        }
        let off = UInt32(pos.count)
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) where r + 1 < colLength[c] && r + 1 < colLength[c + 1] {
                let a = UInt32(r * cols + c), b = a + 1, cc = a + UInt32(cols), d = cc + 1
                idx += [a, cc, b, b, cc, d]
                idx += [off + a, off + b, off + cc, off + b, off + d, off + cc]
            }
        }
        return MeshData(name: name, vertices: verts, indices: idx)
    }
}

/// Verlet chain (flexible weapons, ponytails, hanging chains).
public final class VerletChain {
    public private(set) var points: [Vec3]
    private var prev: [Vec3]
    public var segment: Float
    public var damping: Float = 0.98
    public var gravity = Vec3(0, -12, 0)
    public var iterations = 8

    public init(count: Int, segment: Float, start: Vec3) {
        points = (0..<count).map { start - Vec3(0, Float($0) * segment, 0) }
        prev = points
        self.segment = segment
    }

    public var head: Vec3 { points[points.count - 1] }

    /// Pins the root to `root`; if `tip` is given, the end is driven toward it (with `tipStrength`).
    public func step(dt: Float, root: Vec3, tip: Vec3?, tipStrength: Float = 1, groundY: Float = 0, segmentLength: Float? = nil) {
        if let s = segmentLength { segment = s }
        let h = min(dt, 1.0 / 30.0)
        let n = points.count
        points[0] = root; prev[0] = root
        for i in 1..<n {
            let v = (points[i] - prev[i]) * damping
            prev[i] = points[i]
            points[i] += v + gravity * h * h
        }
        for _ in 0..<iterations {
            if let t = tip {
                points[n - 1] = vlerp(points[n - 1], t, tipStrength)
            }
            points[0] = root
            for i in 0..<(n - 1) {
                let d = points[i + 1] - points[i]
                let len = vlength(d)
                if len < 1e-6 { continue }
                let diff = (len - segment) / len
                if i == 0 {
                    points[i + 1] -= d * diff
                } else {
                    points[i] += d * diff * 0.5
                    points[i + 1] -= d * diff * 0.5
                }
            }
            for i in 1..<n where points[i].y < groundY + 0.03 { points[i].y = groundY + 0.03 }
        }
    }

    public func teleport(to p: Vec3) {
        for i in points.indices { points[i] = p - Vec3(0, Float(i) * segment, 0); prev[i] = points[i] }
    }
}
