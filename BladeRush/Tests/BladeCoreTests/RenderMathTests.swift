import XCTest
@testable import BladeCore

final class RenderMathTests: XCTestCase {
    let view = Mat4.lookAt(eye: Vec3(0, 2.2, -6), target: Vec3(0, 1.2, 2), up: Vec3(0, 1, 0))
    let proj = Mat4.perspective(fovyRadians: 58 * kDeg2Rad, aspect: 16.0 / 9.0, near: 0.08, far: 600)

    func testJitterIsSubPixelAndVaried() {
        var seen = Set<Int>()
        for f in 0..<8 {
            let j = RenderMath.jitter(frame: f)
            XCTAssert(abs(j.x) <= 0.5 && abs(j.y) <= 0.5)
            seen.insert(Int((j.x + 0.5) * 100) * 1000 + Int((j.y + 0.5) * 100))
        }
        XCTAssertEqual(seen.count, 8)
    }

    func testJitterShiftsNDCByRequestedPixels() {
        let p = Vec3(0.7, 1.4, 5)
        let vp = proj * view
        let vpj = RenderMath.jittered(proj, pixels: Vec2(0.5, -0.25), width: 1920, height: 1080) * view
        let a = vp.transformPointProjective(p), b = vpj.transformPointProjective(p)
        let dx = (b.x / b.w - a.x / a.w) * 0.5 * 1920
        let dy = -(b.y / b.w - a.y / a.w) * 0.5 * 1080     // pixels, y down
        XCTAssertEqual(dx, 0.5, accuracy: 1e-3)
        XCTAssertEqual(dy, -0.25, accuracy: 1e-3)
    }

    /// Every point of each frustum slice must land inside its cascade's clip volume.
    func testCascadesContainTheirFrustumSlices() {
        let sun = vnormalize(Vec3(-0.4, 0.6, -0.5))
        let splits: [Float] = [7, 20, 55]
        let c = RenderMath.cascades(view: view, proj: proj, near: 0.08, splits: splits, sunDir: sun, shadowSize: 2048)
        XCTAssertEqual(c.viewProj.count, 3)
        let inv = view.inverse
        let tanX = 1 / proj.c0.x, tanY = 1 / proj.c1.y
        var n: Float = 0.08
        for (i, f) in splits.enumerated() {
            for d in [n, (n + f) / 2, f] {
                for sx: Float in [-1, 0, 1] {
                    for sy: Float in [-1, 0, 1] {
                        let pv = Vec3(sx * tanX * d, sy * tanY * d, -d)
                        let pw = inv.transformPoint(pv)
                        let q = c.viewProj[i].transformPointProjective(pw)
                        let ndc = Vec3(q.x, q.y, q.z) / q.w
                        XCTAssert(abs(ndc.x) <= 1.001 && abs(ndc.y) <= 1.001, "cascade \(i) misses \(pw): \(ndc)")
                        XCTAssert(ndc.z >= -0.001 && ndc.z <= 1.001, "cascade \(i) depth out of range: \(ndc.z)")
                    }
                }
            }
            n = f
        }
        // A caster 30 m toward the sun from the slice centre is still inside the depth range.
        let caster = inv.transformPoint(Vec3(0, 0, -4)) + sun * 30
        let q = c.viewProj[0].transformPointProjective(caster)
        XCTAssert(q.z / q.w >= 0 && q.z / q.w <= 1)
    }

    func testCascadeSnappingIsStableUnderSmallTranslation() {
        let sun = vnormalize(Vec3(-0.4, 0.6, -0.5))
        let a = RenderMath.cascades(view: view, proj: proj, near: 0.08, splits: [7, 20, 55], sunDir: sun, shadowSize: 2048)
        let moved = view * Mat4.translation(Vec3(0.0004, 0, 0))
        let b = RenderMath.cascades(view: moved, proj: proj, near: 0.08, splits: [7, 20, 55], sunDir: sun, shadowSize: 2048)
        // A tiny camera move either keeps the projection or shifts it by whole texels.
        let texel = a.texelWorld[2]
        let pa = a.viewProj[2].transformPoint(.zero), pb = b.viewProj[2].transformPoint(.zero)
        let shiftTexels = (pb.x - pa.x) * 0.5 * 2048
        XCTAssertEqual(shiftTexels, shiftTexels.rounded(), accuracy: 0.05, "texel \(texel)")
    }

    /// These sizes must match the structs in Shaders/Common.metal and UI.metal.
    func testGPUStructLayouts() {
        XCTAssertEqual(MemoryLayout<Vertex>.stride, 40)
        XCTAssertEqual(MemoryLayout<InstanceGPU>.stride, 176)
        XCTAssertEqual(MemoryLayout<ParticleGPU>.stride, 80)
        XCTAssertEqual(MemoryLayout<PointLightGPU>.stride, 32)
        XCTAssertEqual(MemoryLayout<TrailVertexGPU>.stride, 32)
        XCTAssertEqual(MemoryLayout<DecalGPU>.stride, 48)
        XCTAssertEqual(MemoryLayout<UIQuadGPU>.stride, 80)
        XCTAssertEqual(MemoryLayout<SkyParams>.stride, 112)
        XCTAssertEqual(MemoryLayout<Mat4>.stride, 64)
        XCTAssertEqual(MaterialDesc().packed.count * MemoryLayout<Vec4>.stride, 64)
    }

    func testFrustumCulling() {
        let planes = RenderMath.frustumPlanes(proj * view)
        XCTAssertTrue(RenderMath.sphereVisible(planes, center: Vec3(0, 1, 2), radius: 0.5))
        XCTAssertFalse(RenderMath.sphereVisible(planes, center: Vec3(0, 1, -20), radius: 1), "behind the camera")
        XCTAssertFalse(RenderMath.sphereVisible(planes, center: Vec3(60, 1, 2), radius: 1), "far to the side")
        XCTAssertTrue(RenderMath.sphereVisible(planes, center: Vec3(8, 1, 2), radius: 6), "straddling the edge")
    }
}
