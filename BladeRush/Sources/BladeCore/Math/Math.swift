// Core scalar and vector math.
//
// We deliberately build on the Swift standard library SIMD types (SIMD2/3/4<Float>)
// instead of importing Apple's `simd` module. This keeps BladeCore portable (it also
// compiles on Linux for headless tests) and memory-layout compatible with Metal's
// float2/float3/float4. Free functions are prefixed with `v` / suffixed with `f` so
// they never collide with `simd` overloads in the macOS target.
import Foundation

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>
public typealias Vec4 = SIMD4<Float>

public let kPi: Float = Float.pi
public let kTwoPi: Float = Float.pi * 2
public let kDeg2Rad: Float = Float.pi / 180
public let kRad2Deg: Float = 180 / Float.pi

// MARK: - Scalar helpers

@inlinable public func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }
@inlinable public func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
@inlinable public func saturatef(_ x: Float) -> Float { min(max(x, 0), 1) }
@inlinable public func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inlinable public func invLerpf(_ a: Float, _ b: Float, _ x: Float) -> Float {
    abs(b - a) < 1e-12 ? 0 : (x - a) / (b - a)
}
@inlinable public func remapf(_ x: Float, _ a0: Float, _ a1: Float, _ b0: Float, _ b1: Float) -> Float {
    lerpf(b0, b1, saturatef(invLerpf(a0, a1, x)))
}
@inlinable public func smoothstepf(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = saturatef((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}
@inlinable public func signf(_ x: Float) -> Float { x > 0 ? 1 : (x < 0 ? -1 : 0) }
@inlinable public func fractf(_ x: Float) -> Float { x - x.rounded(.down) }

/// Frame-rate independent exponential smoothing toward `target`.
/// `sharpness` is roughly "1 / time constant" (higher = snappier).
@inlinable public func dampf(_ current: Float, _ target: Float, _ sharpness: Float, _ dt: Float) -> Float {
    lerpf(current, target, 1 - exp(-sharpness * dt))
}

/// Moves `current` toward `target` by at most `maxDelta`.
@inlinable public func approachf(_ current: Float, _ target: Float, _ maxDelta: Float) -> Float {
    if current < target { return min(current + maxDelta, target) }
    return max(current - maxDelta, target)
}

/// Wraps an angle (radians) into [-pi, pi].
@inlinable public func wrapAngle(_ a: Float) -> Float {
    var x = a.truncatingRemainder(dividingBy: kTwoPi)
    if x > kPi { x -= kTwoPi } else if x < -kPi { x += kTwoPi }
    return x
}

/// Shortest signed difference `to - from` for angles.
@inlinable public func angleDelta(_ from: Float, _ to: Float) -> Float { wrapAngle(to - from) }

/// Damps an angle along the shortest arc.
@inlinable public func dampAngle(_ current: Float, _ target: Float, _ sharpness: Float, _ dt: Float) -> Float {
    current + angleDelta(current, target) * (1 - exp(-sharpness * dt))
}

/// Rotates an angle toward target by at most maxDelta along the shortest arc.
@inlinable public func approachAngle(_ current: Float, _ target: Float, _ maxDelta: Float) -> Float {
    let d = angleDelta(current, target)
    if abs(d) <= maxDelta { return target }
    return wrapAngle(current + signf(d) * maxDelta)
}

// MARK: - Vector helpers

@inlinable public func vdot(_ a: Vec3, _ b: Vec3) -> Float { (a * b).sum() }
@inlinable public func vdot2(_ a: Vec2, _ b: Vec2) -> Float { (a * b).sum() }
@inlinable public func vdot4(_ a: Vec4, _ b: Vec4) -> Float { (a * b).sum() }
@inlinable public func vcross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inlinable public func vlength(_ a: Vec3) -> Float { (a * a).sum().squareRoot() }
@inlinable public func vlength2(_ a: Vec2) -> Float { (a * a).sum().squareRoot() }
@inlinable public func vlengthSq(_ a: Vec3) -> Float { (a * a).sum() }
@inlinable public func vdistance(_ a: Vec3, _ b: Vec3) -> Float { vlength(a - b) }
@inlinable public func vnormalize(_ a: Vec3, fallback: Vec3 = Vec3(0, 0, 1)) -> Vec3 {
    let l2 = (a * a).sum()
    return l2 > 1e-20 ? a / l2.squareRoot() : fallback
}
@inlinable public func vnormalize2(_ a: Vec2, fallback: Vec2 = Vec2(0, 1)) -> Vec2 {
    let l2 = (a * a).sum()
    return l2 > 1e-20 ? a / l2.squareRoot() : fallback
}
@inlinable public func vlerp(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 { a + (b - a) * t }
@inlinable public func vlerp4(_ a: Vec4, _ b: Vec4, _ t: Float) -> Vec4 { a + (b - a) * t }
@inlinable public func vdamp(_ a: Vec3, _ b: Vec3, _ sharpness: Float, _ dt: Float) -> Vec3 {
    vlerp(a, b, 1 - exp(-sharpness * dt))
}
@inlinable public func vclampLength(_ v: Vec3, _ maxLen: Float) -> Vec3 {
    let l = vlength(v)
    return l > maxLen && l > 0 ? v * (maxLen / l) : v
}
@inlinable public func vflat(_ v: Vec3) -> Vec3 { Vec3(v.x, 0, v.z) }
@inlinable public func vxz(_ v: Vec3) -> Vec2 { Vec2(v.x, v.z) }
@inlinable public func vmin(_ a: Vec3, _ b: Vec3) -> Vec3 { pointwiseMin(a, b) }
@inlinable public func vmax(_ a: Vec3, _ b: Vec3) -> Vec3 { pointwiseMax(a, b) }
@inlinable public func vabs(_ a: Vec3) -> Vec3 { Vec3(abs(a.x), abs(a.y), abs(a.z)) }
@inlinable public func vreflect(_ v: Vec3, _ n: Vec3) -> Vec3 { v - 2 * vdot(v, n) * n }
@inlinable public func vmaxComp(_ a: Vec3) -> Float { max(a.x, max(a.y, a.z)) }

/// Unit forward vector (XZ plane) for a yaw angle. Yaw 0 faces +Z.
@inlinable public func yawToDir(_ yaw: Float) -> Vec3 { Vec3(sin(yaw), 0, cos(yaw)) }
/// Yaw angle of a direction projected onto the XZ plane.
@inlinable public func dirToYaw(_ d: Vec3) -> Float { atan2(d.x, d.z) }

extension SIMD3 where Scalar == Float {
    @inlinable public var xz: Vec2 { Vec2(x, z) }
    @inlinable public func withY(_ y: Float) -> Vec3 { Vec3(self.x, y, self.z) }
}

extension SIMD4 where Scalar == Float {
    @inlinable public var xyz: Vec3 { Vec3(x, y, z) }
    @inlinable public init(_ v: Vec3, _ w: Float) { self.init(v.x, v.y, v.z, w) }
}

/// Converts an sRGB hex color like 0xRRGGBB to linear Vec3.
public func srgbHex(_ hex: UInt32) -> Vec3 {
    let r = Float((hex >> 16) & 0xFF) / 255, g = Float((hex >> 8) & 0xFF) / 255, b = Float(hex & 0xFF) / 255
    return Vec3(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
}

@inlinable public func srgbToLinear(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
@inlinable public func linearToSrgb(_ c: Float) -> Float {
    c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
}

/// Parses "#RRGGBB" / "RRGGBB" into linear RGB. Returns grey on failure.
public func parseColor(_ s: String) -> Vec3 {
    var str = s.trimmingCharacters(in: .whitespaces)
    if str.hasPrefix("#") { str.removeFirst() }
    guard str.count == 6, let v = UInt32(str, radix: 16) else { return Vec3(0.5, 0.5, 0.5) }
    return srgbHex(v)
}

// MARK: - Easing

public enum Ease: String, Codable, CaseIterable {
    case linear, inQuad, outQuad, inOutQuad, inCubic, outCubic, inOutCubic
    case inExpo, outExpo, outBack, inBack, outElastic, hold, snap

    public func apply(_ t0: Float) -> Float {
        let t = saturatef(t0)
        switch self {
        case .linear: return t
        case .inQuad: return t * t
        case .outQuad: return 1 - (1 - t) * (1 - t)
        case .inOutQuad: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .inCubic: return t * t * t
        case .outCubic: return 1 - pow(1 - t, 3)
        case .inOutCubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .inExpo: return t <= 0 ? 0 : pow(2, 10 * t - 10)
        case .outExpo: return t >= 1 ? 1 : 1 - pow(2, -10 * t)
        case .outBack:
            let c1: Float = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .inBack:
            let c1: Float = 1.70158, c3 = c1 + 1
            return c3 * t * t * t - c1 * t * t
        case .outElastic:
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * kPi / 3)) + 1
        case .hold: return t < 1 ? 0 : 1
        case .snap: return t < 0.15 ? t / 0.15 * 0.9 : 0.9 + (t - 0.15) / 0.85 * 0.1
        }
    }
}
