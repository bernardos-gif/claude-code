// Procedural sky presets. The same parameters drive the sky shader (clouds, stars,
// aurora, eclipse corona...) and a CPU evaluation of the base radiance that is projected
// onto 9-coefficient spherical harmonics for diffuse image-based lighting.
import Foundation

/// GPU sky parameters (7 x float4 = 112 bytes, mirrored in Common.metal).
public struct SkyParams: Equatable {
    public var zenith = Vec4(0.08, 0.1, 0.2, 0)        // rgb, w = preset id
    public var horizon = Vec4(0.6, 0.4, 0.3, 0)        // rgb, w = cloud cover
    public var ground = Vec4(0.08, 0.07, 0.06, 0)      // rgb, w = star intensity
    public var sunColor = Vec4(1, 0.7, 0.4, 0.9995)    // rgb, w = cos(sun disc radius)
    public var accent = Vec4(0, 0, 0, 0)               // rgb (aurora / eclipse / moon), w = accent strength
    public var params = Vec4(1, 0, 0, 0)               // x sun disc intensity, y horizon falloff, z time, w lightning
    public var moonDir = Vec4(0, 0.5, 0.86, 0)         // xyz direction of the moon / eclipse, w = size
    public init() {}
}

public enum SkyPreset: Int, CaseIterable {
    case dusk = 0, storm, eclipse, aurora, bloodmoon, underground, night, overcast, dawn, void

    public static func named(_ s: String) -> SkyPreset {
        switch s {
        case "storm": return .storm
        case "eclipse": return .eclipse
        case "aurora": return .aurora
        case "bloodmoon": return .bloodmoon
        case "underground": return .underground
        case "night": return .night
        case "overcast": return .overcast
        case "dawn": return .dawn
        case "void": return .void
        default: return .dusk
        }
    }

    public func params(sunDir: Vec3, sunColor: Vec3) -> SkyParams {
        var p = SkyParams()
        let id = Float(rawValue)
        func c(_ hex: UInt32) -> Vec3 { srgbHex(hex) }
        switch self {
        case .dusk:
            p.zenith = Vec4(c(0x2A3560), id); p.horizon = Vec4(c(0xF09050), 0.35); p.ground = Vec4(c(0x2A2024), 0.1)
            p.accent = Vec4(c(0xFF6A3A), 0.4)
        case .dawn:
            p.zenith = Vec4(c(0x4A6090), id); p.horizon = Vec4(c(0xFFC8A0), 0.3); p.ground = Vec4(c(0x302A2A), 0)
        case .storm:
            p.zenith = Vec4(c(0x1A2028), id); p.horizon = Vec4(c(0x4A5664), 0.95); p.ground = Vec4(c(0x14181C), 0)
            p.accent = Vec4(c(0xA0C0FF), 0.0)
        case .eclipse:
            p.zenith = Vec4(c(0x0A0814), id); p.horizon = Vec4(c(0x3A2050), 0.2); p.ground = Vec4(c(0x0A080E), 0.6)
            p.accent = Vec4(c(0xC8A0FF), 1.0)
        case .aurora:
            p.zenith = Vec4(c(0x061020), id); p.horizon = Vec4(c(0x28405A), 0.15); p.ground = Vec4(c(0x101820), 0.9)
            p.accent = Vec4(c(0x40FFB0), 1.0)
        case .bloodmoon:
            p.zenith = Vec4(c(0x14060A), id); p.horizon = Vec4(c(0x6A1A1A), 0.25); p.ground = Vec4(c(0x100808), 0.5)
            p.accent = Vec4(c(0xFF3A2A), 1.0)
        case .underground:
            p.zenith = Vec4(c(0x0A0606), id); p.horizon = Vec4(c(0x3A1A10), 0.0); p.ground = Vec4(c(0x1A0C08), 0)
            p.accent = Vec4(c(0xFF5A20), 0.6)
        case .night:
            p.zenith = Vec4(c(0x060A18), id); p.horizon = Vec4(c(0x1A2440), 0.2); p.ground = Vec4(c(0x0A0A10), 1.0)
            p.accent = Vec4(c(0xC8D8FF), 0.8)
        case .overcast:
            p.zenith = Vec4(c(0x5A6470), id); p.horizon = Vec4(c(0x9AA4AE), 0.85); p.ground = Vec4(c(0x3A3C40), 0)
        case .void:
            p.zenith = Vec4(c(0x04030A), id); p.horizon = Vec4(c(0x2A1A40), 0.1); p.ground = Vec4(c(0x050408), 1.0)
            p.accent = Vec4(c(0xFFD070), 1.0)
        }
        p.sunColor = Vec4(sunColor, cos(self == .eclipse || self == .bloodmoon || self == .night ? 0.035 : 0.022))
        p.params = Vec4(self == .storm || self == .underground || self == .overcast ? 0.0 : 1.0, 1.0, 0, 0)
        let moon = vnormalize(Vec3(-sunDir.x * 0.3 + 0.2, max(0.35, sunDir.y + 0.2), -sunDir.z * 0.3 + 0.85))
        p.moonDir = Vec4(self == .eclipse || self == .bloodmoon || self == .void ? vnormalize(sunDir + Vec3(0, 0.15, 0)) : moon, 0.06)
        return p
    }
}

public enum SkyMath {
    /// CPU approximation of the sky shader's base radiance (no clouds/stars detail).
    public static func radiance(_ d: Vec3, sky p: SkyParams, sunDir: Vec3, sunIntensity: Float) -> Vec3 {
        let y = d.y
        let zen = p.zenith.xyz, hor = p.horizon.xyz, gnd = p.ground.xyz
        var col: Vec3
        if y >= 0 {
            let t = pow(1 - y, 3)
            col = vlerp(zen, hor, t)
        } else {
            let t = min(1, -y * 4)
            col = vlerp(hor * 0.6, gnd, t)
        }
        // Clouds greying.
        col = vlerp(col, hor * 0.7 + zen * 0.3, p.horizon.w * 0.5 * saturatef(y * 3))
        // Sun scattering glow.
        let s = max(0, vdot(d, sunDir))
        col += p.sunColor.xyz * (pow(s, 8) * 0.35 + pow(s, 64) * 0.8) * sunIntensity * 0.25 * p.params.x
        // Accent glow (aurora band / eclipse corona / blood moon).
        if p.accent.w > 0 {
            let m = max(0, vdot(d, p.moonDir.xyz))
            col += p.accent.xyz * pow(m, 16) * p.accent.w * 0.5
            if p.zenith.w == Float(SkyPreset.aurora.rawValue) { col += p.accent.xyz * saturatef(y * 2) * 0.15 }
        }
        return col
    }

    /// Projects sky radiance onto irradiance SH9 (already convolved with the cosine lobe).
    public static func irradianceSH(sky p: SkyParams, sunDir: Vec3, sunIntensity: Float, ambientScale: Float, groundColor: Vec3) -> [Vec4] {
        var coeffs = [Vec3](repeating: .zero, count: 9)
        let n = 24
        var wsum: Float = 0
        for i in 0..<n {
            for j in 0..<(n * 2) {
                let theta = (Float(i) + 0.5) / Float(n) * kPi
                let phi = (Float(j) + 0.5) / Float(n * 2) * kTwoPi
                let d = Vec3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                var r = radiance(d, sky: p, sunDir: sunDir, sunIntensity: sunIntensity)
                if d.y < 0 { r = vlerp(r, groundColor * (0.2 + 0.25 * sunIntensity * max(sunDir.y, 0)), 0.6) }
                let w = sin(theta)
                let b = shBasis(d)
                for k in 0..<9 { coeffs[k] += r * b[k] * w }
                wsum += w
            }
        }
        let norm = 4 * kPi / wsum
        // Cosine lobe convolution (Ramamoorthi & Hanrahan).
        let a: [Float] = [kPi, 2 * kPi / 3, 2 * kPi / 3, 2 * kPi / 3, kPi / 4, kPi / 4, kPi / 4, kPi / 4, kPi / 4]
        return (0..<9).map { k in Vec4(coeffs[k] * norm * a[k] / kPi * ambientScale, 0) }
    }

    public static func shBasis(_ d: Vec3) -> [Float] {
        [0.282095,
         0.488603 * d.y, 0.488603 * d.z, 0.488603 * d.x,
         1.092548 * d.x * d.y, 1.092548 * d.y * d.z, 0.315392 * (3 * d.z * d.z - 1),
         1.092548 * d.x * d.z, 0.546274 * (d.x * d.x - d.y * d.y)]
    }

    public static func evalSH(_ sh: [Vec4], _ n: Vec3) -> Vec3 {
        let b = shBasis(n)
        var r = Vec3.zero
        for k in 0..<9 { r += sh[k].xyz * b[k] }
        return vmax(r, .zero)
    }
}
