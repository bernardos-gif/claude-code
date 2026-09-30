// Deterministic PCG32 random number generator. Everything procedural is seeded so a
// given boss / arena / texture always generates identically.
import Foundation

public struct Rng {
    public var state: UInt64
    public var inc: UInt64

    public init(seed: UInt64, stream: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        state = 0
        inc = (stream << 1) | 1
        _ = nextU32()
        state &+= seed
        _ = nextU32()
    }

    public init(_ string: String) {
        self.init(seed: Rng.hash(string))
    }

    /// FNV-1a 64-bit hash of a string (stable across runs, unlike Hasher).
    public static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01B3 }
        return h
    }

    @inlinable public mutating func nextU32() -> UInt32 {
        let old = state
        state = old &* 6_364_136_223_846_793_005 &+ inc
        let xorshifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
        let rot = UInt32(truncatingIfNeeded: old >> 59)
        return (xorshifted >> rot) | (xorshifted << ((~rot &+ 1) & 31))
    }

    /// Uniform float in [0, 1).
    @inlinable public mutating func float() -> Float { Float(nextU32() >> 8) * (1.0 / 16_777_216.0) }
    @inlinable public mutating func double() -> Double { Double(nextU32()) / 4_294_967_296.0 }
    @inlinable public mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * float() }
    @inlinable public mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(nextU32() % UInt32(n)) }
    @inlinable public mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + int(hi - lo + 1) }
    @inlinable public mutating func chance(_ p: Float) -> Bool { float() < p }
    @inlinable public mutating func sign() -> Float { float() < 0.5 ? -1 : 1 }

    public mutating func unitVector() -> Vec3 {
        let z = range(-1, 1)
        let a = range(0, kTwoPi)
        let r = (1 - z * z).squareRoot()
        return Vec3(r * cos(a), z, r * sin(a))
    }

    public mutating func inCone(_ dir: Vec3, spread: Float) -> Vec3 {
        let v = unitVector()
        return vnormalize(dir + v * spread)
    }

    public mutating func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[int(a.count)] }

    /// Weighted random index. Returns nil if all weights are <= 0.
    public mutating func weightedIndex(_ weights: [Float]) -> Int? {
        let total = weights.reduce(0) { $0 + max($1, 0) }
        guard total > 0 else { return nil }
        var r = float() * total
        for (i, w) in weights.enumerated() where w > 0 {
            if r < w { return i }
            r -= w
        }
        return weights.lastIndex(where: { $0 > 0 })
    }

    public mutating func shuffle<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            a.swapAt(i, int(i + 1))
        }
    }
}

/// Stateless integer hash helpers used by noise and GPU-mirrored code.
@inlinable public func hash32(_ x0: UInt32) -> UInt32 {
    var x = x0
    x ^= x >> 16; x = x &* 0x7FEB_352D
    x ^= x >> 15; x = x &* 0x846C_A68B
    x ^= x >> 16
    return x
}

@inlinable public func hash3i(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> UInt32 {
    hash32(UInt32(bitPattern: x) &* 0x8DA6_B343 ^ UInt32(bitPattern: y) &* 0xD816_3841 ^ UInt32(bitPattern: z) &* 0xCB1A_B31F ^ seed &* 0x1656_67B1)
}

@inlinable public func hashFloat(_ h: UInt32) -> Float { Float(h >> 8) * (1.0 / 16_777_216.0) }
