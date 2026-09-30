// Surface Nets polygonization of an SDF model (a dual method: one vertex per surface
// cell, quads across sign-changing edges). Compared to marching cubes it yields evenly
// spaced vertices and smoother, more organic results with far less code, which suits
// sculpted characters. A coarse narrow-band pass skips empty space so a 1-2 million cell
// grid polygonizes in well under a second on Apple Silicon.
import Foundation

public struct SurfaceNetsOptions {
    public var voxelSize: Float = 0.012
    public var skinned: Bool = true
    public var computeAO: Bool = true
    /// Scale for AO / curvature sampling distances (character scale).
    public var featureScale: Float = 1
    public var aoStrength: Float = 1
    public init() {}
}

public enum SurfaceNets {
    public static func polygonize(_ model: SDFModel, name: String, options o: SurfaceNetsOptions,
                                  materialFor: ((Int) -> Int)? = nil) -> MeshData {
        guard !model.isEmpty, model.boundsMin.x.isFinite else { return MeshData(name: name) }
        let h = o.voxelSize
        let lo = model.boundsMin - Vec3(repeating: h * 2)
        let hi = model.boundsMax + Vec3(repeating: h * 2)
        let dims = SIMD3<Int>(Int(((hi.x - lo.x) / h).rounded(.up)) + 1,
                              Int(((hi.y - lo.y) / h).rounded(.up)) + 1,
                              Int(((hi.z - lo.z) / h).rounded(.up)) + 1)
        let nx = dims.x, ny = dims.y, nz = dims.z
        let total = nx * ny * nz
        if total > 12_000_000 {
            logWarn("SurfaceNets grid too large for \(name): \(nx)x\(ny)x\(nz); coarsening", "mesh")
            var o2 = o
            o2.voxelSize = h * 1.4
            return polygonize(model, name: name, options: o2, materialFor: materialFor)
        }
        @inline(__always) func pos(_ i: Int, _ j: Int, _ k: Int) -> Vec3 {
            lo + Vec3(Float(i), Float(j), Float(k)) * h
        }
        @inline(__always) func idx(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }

        // 1. Narrow band: classify 4x4x4 blocks by the distance at their center.
        let B = 4
        let bx = (nx + B - 1) / B, by = (ny + B - 1) / B, bz = (nz + B - 1) / B
        var near = [Bool](repeating: false, count: bx * by * bz)
        var blockSign = [Float](repeating: 1, count: bx * by * bz)
        let halfDiag = Float(B) * h * 0.5 * 1.7321 + h
        near.withUnsafeMutableBufferPointer { nearBuf in
            blockSign.withUnsafeMutableBufferPointer { signBuf in
                DispatchQueue.concurrentPerform(iterations: bz) { kb in
                    for jb in 0..<by {
                        for ib in 0..<bx {
                            let c = lo + Vec3(Float(ib * B) + Float(B) * 0.5, Float(jb * B) + Float(B) * 0.5, Float(kb * B) + Float(B) * 0.5) * h
                            let d = model.distance(c)
                            let bi = (kb * by + jb) * bx + ib
                            nearBuf[bi] = abs(d) <= halfDiag * 1.25
                            signBuf[bi] = d < 0 ? -1 : 1
                        }
                    }
                }
            }
        }

        // 2. Sample the field at grid points touching near blocks.
        var field = [Float](repeating: 1, count: total)
        field.withUnsafeMutableBufferPointer { fb in
            DispatchQueue.concurrentPerform(iterations: nz) { k in
                for j in 0..<ny {
                    for i in 0..<nx {
                        // Blocks containing this point (point may sit on block borders).
                        var isNear = false
                        var sgn: Float = 1
                        let i0 = max(0, (i - 1) / B), i1 = min(bx - 1, i / B)
                        let j0 = max(0, (j - 1) / B), j1 = min(by - 1, j / B)
                        let k0 = max(0, (k - 1) / B), k1 = min(bz - 1, k / B)
                        outer: for kb in k0...k1 {
                            for jb in j0...j1 {
                                for ib in i0...i1 {
                                    let bi = (kb * by + jb) * bx + ib
                                    sgn = blockSign[bi]
                                    if near[bi] { isNear = true; break outer }
                                }
                            }
                        }
                        fb[(k * ny + j) * nx + i] = isNear ? model.distance(pos(i, j, k)) : sgn * 1e3
                    }
                }
            }
        }

        // 3. One vertex per cell with a sign change.
        var cellVertex = [Int32](repeating: -1, count: total)
        var verts: [Vec3] = []
        verts.reserveCapacity(40000)
        let cornerOffsets: [SIMD3<Int>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
                                           SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 1, 1)]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        for k in 0..<(nz - 1) {
            for j in 0..<(ny - 1) {
                for i in 0..<(nx - 1) {
                    var mask = 0
                    var vals = [Float](repeating: 0, count: 8)
                    for c in 0..<8 {
                        let o = cornerOffsets[c]
                        let v = field[idx(i + o.x, j + o.y, k + o.z)]
                        vals[c] = v
                        if v < 0 { mask |= 1 << c }
                    }
                    if mask == 0 || mask == 255 { continue }
                    var sum = Vec3.zero
                    var cnt: Float = 0
                    for (e0, e1) in edges {
                        let v0 = vals[e0], v1 = vals[e1]
                        if (v0 < 0) == (v1 < 0) { continue }
                        let t = v0 / (v0 - v1)
                        let p0 = Vec3(Float(cornerOffsets[e0].x), Float(cornerOffsets[e0].y), Float(cornerOffsets[e0].z))
                        let p1 = Vec3(Float(cornerOffsets[e1].x), Float(cornerOffsets[e1].y), Float(cornerOffsets[e1].z))
                        sum += p0 + (p1 - p0) * t
                        cnt += 1
                    }
                    let local = sum / max(cnt, 1)
                    cellVertex[idx(i, j, k)] = Int32(verts.count)
                    verts.append(pos(i, j, k) + local * h)
                }
            }
        }

        // 4. Quads across sign-changing grid edges.
        var indices: [UInt32] = []
        indices.reserveCapacity(verts.count * 6)
        func emit(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, _ flip: Bool) {
            guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
            let q = flip ? [a, d, c, b] : [a, b, c, d]
            // Split along the shorter diagonal.
            let d02 = vlengthSq(verts[Int(q[0])] - verts[Int(q[2])])
            let d13 = vlengthSq(verts[Int(q[1])] - verts[Int(q[3])])
            if d02 <= d13 {
                indices += [UInt32(q[0]), UInt32(q[1]), UInt32(q[2]), UInt32(q[0]), UInt32(q[2]), UInt32(q[3])]
            } else {
                indices += [UInt32(q[0]), UInt32(q[1]), UInt32(q[3]), UInt32(q[1]), UInt32(q[2]), UInt32(q[3])]
            }
        }
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let v0 = field[idx(i, j, k)]
                    let inside0 = v0 < 0
                    // Edge along +x
                    if i + 1 < nx && j > 0 && k > 0 && j < ny - 1 && k < nz - 1 {
                        let v1 = field[idx(i + 1, j, k)]
                        if inside0 != (v1 < 0) {
                            emit(cellVertex[idx(i, j - 1, k - 1)], cellVertex[idx(i, j, k - 1)],
                                 cellVertex[idx(i, j, k)], cellVertex[idx(i, j - 1, k)], !inside0)
                        }
                    }
                    // Edge along +y
                    if j + 1 < ny && i > 0 && k > 0 && i < nx - 1 && k < nz - 1 {
                        let v1 = field[idx(i, j + 1, k)]
                        if inside0 != (v1 < 0) {
                            emit(cellVertex[idx(i - 1, j, k - 1)], cellVertex[idx(i - 1, j, k)],
                                 cellVertex[idx(i, j, k)], cellVertex[idx(i, j, k - 1)], !inside0)
                        }
                    }
                    // Edge along +z
                    if k + 1 < nz && i > 0 && j > 0 && i < nx - 1 && j < ny - 1 {
                        let v1 = field[idx(i, j, k + 1)]
                        if inside0 != (v1 < 0) {
                            emit(cellVertex[idx(i - 1, j - 1, k)], cellVertex[idx(i, j - 1, k)],
                                 cellVertex[idx(i, j, k)], cellVertex[idx(i - 1, j, k)], !inside0)
                        }
                    }
                }
            }
        }

        // 5. Per-vertex refinement and attributes (parallel).
        let count = verts.count
        var out = [Vertex](repeating: Vertex(p: .zero, n: Vec3(0, 1, 0)), count: count)
        let gh = h * 0.5
        let fs = o.featureScale
        verts.withUnsafeBufferPointer { vb in
            out.withUnsafeMutableBufferPointer { ob in
                DispatchQueue.concurrentPerform(iterations: max(1, (count + 255) / 256)) { chunk in
                    let start = chunk * 256
                    let end = min(count, start + 256)
                    if start >= end { return }
                    for vi in start..<end {
                        var p = vb[vi]
                        // Project onto the surface (bounded to the cell).
                        for _ in 0..<2 {
                            let d = model.distance(p)
                            let g = model.gradient(p, h: gh)
                            p -= g * clampf(d, -h * 0.7, h * 0.7)
                        }
                        let n = model.gradient(p, h: gh)
                        let (_, ownerIdx) = model.distanceOwner(p)
                        let owner = model.prims[ownerIdx]
                        // Cavity / ambient occlusion from the field itself.
                        var ao: Float = 1
                        if o.computeAO {
                            var occ: Float = 0
                            var sca: Float = 1
                            for s in 1...5 {
                                let hr = (0.012 + 0.022 * Float(s)) * fs
                                let dd = model.distance(p + n * hr)
                                occ += max(0, hr - dd) * sca
                                sca *= 0.72
                            }
                            ao = saturatef(1 - occ * 7.5 / fs * o.aoStrength)
                        }
                        // Convexity (mean curvature via Laplacian) -> edge wear mask.
                        let e = 0.012 * fs
                        let d0 = model.distance(p)
                        var lap: Float = -6 * d0
                        lap += model.distance(p + Vec3(e, 0, 0)) + model.distance(p - Vec3(e, 0, 0))
                        lap += model.distance(p + Vec3(0, e, 0)) + model.distance(p - Vec3(0, e, 0))
                        lap += model.distance(p + Vec3(0, 0, e)) + model.distance(p - Vec3(0, 0, e))
                        let curvature = lap / (e * e) * 0.5 * fs
                        let edge = smoothstepf(9, 45, curvature)
                        var bones: UInt32 = UInt32(owner.bone)
                        var weights: UInt32 = 255
                        if o.skinned {
                            let sw = model.skinWeights(p)
                            var bi = [UInt8](repeating: 0, count: 4)
                            var wi = [UInt8](repeating: 0, count: 4)
                            var acc = 0
                            for (n2, (b, w)) in sw.enumerated() {
                                bi[n2] = UInt8(b)
                                let q = n2 == sw.count - 1 ? 255 - acc : Int((w * 255).rounded())
                                wi[n2] = UInt8(clamping: max(0, q))
                                acc += Int(wi[n2])
                            }
                            bones = Vertex.pack(bi[0], bi[1], bi[2], bi[3])
                            weights = Vertex.pack(wi[0], wi[1], wi[2], wi[3])
                        }
                        let slot = materialFor?(owner.material) ?? owner.material
                        let detail = hashFloat(hash32(UInt32(truncatingIfNeeded: ownerIdx &* 7919)))
                        ob[vi] = Vertex(p: p, n: n, color: Vertex.packColor(owner.tint, ao: ao),
                                        bones: bones, weights: weights,
                                        attr: Vertex.packAttr(material: slot, edge: edge, emissive: owner.emissive, detail: detail))
                    }
                }
            }
        }
        return MeshData(name: name, vertices: out, indices: indices, skinned: o.skinned)
    }
}
