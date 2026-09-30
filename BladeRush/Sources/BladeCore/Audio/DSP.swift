// Small DSP toolkit for procedural sound: oscillators, noise, biquad filters, envelopes,
// modal (resonant) synthesis, Karplus-Strong plucks and a Freeverb-style reverb.
import Foundation

public let kSampleRate: Float = 48000

public struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    public init() {}

    public enum Kind { case lowpass, highpass, bandpass, peak }

    public mutating func set(_ kind: Kind, freq: Float, q: Float, gainDB: Float = 0) {
        let f = clampf(freq, 10, kSampleRate * 0.45)
        let w = 2 * kPi * f / kSampleRate
        let cw = cos(w), sw = sin(w)
        let alpha = sw / (2 * max(q, 0.05))
        var nb0: Float, nb1: Float, nb2: Float, na0: Float, na1: Float, na2: Float
        switch kind {
        case .lowpass:
            nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = (1 - cw) / 2; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .highpass:
            nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = (1 + cw) / 2; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .bandpass:
            nb0 = alpha; nb1 = 0; nb2 = -alpha; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .peak:
            let a = pow(10, gainDB / 40)
            nb0 = 1 + alpha * a; nb1 = -2 * cw; nb2 = 1 - alpha * a; na0 = 1 + alpha / a; na1 = -2 * cw; na2 = 1 - alpha / a
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0; a1 = na1 / na0; a2 = na2 / na0
    }

    @inline(__always) public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Fast deterministic white noise.
public struct NoiseGen {
    var state: UInt32
    public init(seed: UInt32 = 22222) { state = seed | 1 }
    @inline(__always) public mutating func next() -> Float {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Float(Int32(bitPattern: state)) / 2_147_483_648
    }
}

/// Pink-ish noise (Paul Kellet's economy filter).
public struct PinkNoise {
    var w = NoiseGen(seed: 777)
    var b0: Float = 0, b1: Float = 0, b2: Float = 0
    public init(seed: UInt32 = 777) { w = NoiseGen(seed: seed) }
    @inline(__always) public mutating func next() -> Float {
        let white = w.next()
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        return (b0 + b1 + b2 + white * 0.1848) * 0.2
    }
}

/// PolyBLEP band-limited sawtooth.
public struct SawOsc {
    public var phase: Float = 0
    public init(phase: Float = 0) { self.phase = phase }
    @inline(__always) public mutating func next(_ freq: Float) -> Float {
        let dt = freq / kSampleRate
        phase += dt
        if phase >= 1 { phase -= 1 }
        var v = 2 * phase - 1
        if phase < dt { let t = phase / dt; v -= t + t - t * t - 1 }
        else if phase > 1 - dt { let t = (phase - 1) / dt; v -= t * t + t + t + 1 }
        return v
    }
}

public enum DSP {
    @inline(__always) public static func sine(_ phase: Float) -> Float { sin(phase * kTwoPi) }
    @inline(__always) public static func softClip(_ x: Float) -> Float { tanh(x) }
    public static func midiToFreq(_ n: Float) -> Float { 440 * pow(2, (n - 69) / 12) }
    public static func dbToGain(_ db: Float) -> Float { pow(10, db / 20) }

    /// Renders `seconds` of audio by calling `f(t, i)` per sample.
    public static func render(_ seconds: Float, _ f: (Float, Int) -> Float) -> [Float] {
        let n = Int(seconds * kSampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = f(Float(i) / kSampleRate, i) }
        return out
    }

    /// Normalizes a buffer to the given peak and applies short fades to avoid clicks.
    public static func finalize(_ b: inout [Float], peak: Float = 0.9, fadeIn: Float = 0.001, fadeOut: Float = 0.01) {
        var m: Float = 1e-9
        for v in b { m = max(m, abs(v)) }
        let g = peak / m
        let fi = Int(fadeIn * kSampleRate), fo = Int(fadeOut * kSampleRate)
        for i in 0..<b.count {
            var k = g
            if i < fi { k *= Float(i) / Float(max(fi, 1)) }
            if i > b.count - fo { k *= Float(b.count - i) / Float(max(fo, 1)) }
            b[i] *= k
        }
    }

    public static func mix(_ a: [Float], _ b: [Float], _ gb: Float = 1, offset: Int = 0) -> [Float] {
        var out = a
        if out.count < b.count + offset { out += [Float](repeating: 0, count: b.count + offset - out.count) }
        for i in 0..<b.count { out[i + offset] += b[i] * gb }
        return out
    }

    /// Modal synthesis: a set of exponentially decaying partials (metal, bells, gongs).
    public static func modal(_ seconds: Float, base: Float, ratios: [Float], decays: [Float], amps: [Float], seed: UInt32 = 1,
                             detune: Float = 0.003, strike: Float = 0.004) -> [Float] {
        var rng = NoiseGen(seed: seed)
        let partials = ratios.indices.map { i -> (Float, Float, Float, Float) in
            (base * ratios[i] * (1 + rng.next() * detune), decays[min(i, decays.count - 1)], amps[min(i, amps.count - 1)], abs(rng.next()))
        }
        var n = NoiseGen(seed: seed &+ 3)
        return render(seconds) { t, _ in
            var s: Float = 0
            for (f, d, a, ph) in partials { s += sin((t * f + ph) * kTwoPi) * exp(-t / d) * a }
            // Strike transient.
            if t < strike { s += n.next() * (1 - t / strike) * 0.8 }
            return s
        }
    }

    /// Band-passed noise sweep (whooshes, wind gusts).
    public static func whoosh(_ seconds: Float, from f0: Float, to f1: Float, q: Float, seed: UInt32, shape: Float = 2) -> [Float] {
        var bq = Biquad()
        var n = NoiseGen(seed: seed)
        let total = seconds
        return render(seconds) { t, i in
            let u = t / total
            if i % 32 == 0 { bq.set(.bandpass, freq: f0 * pow(f1 / f0, u), q: q) }
            let env = pow(sin(kPi * min(1, u)), shape)
            return bq.process(n.next()) * env
        }
    }

    /// Karplus-Strong plucked string.
    public static func pluck(_ seconds: Float, freq: Float, damping: Float = 0.996, seed: UInt32 = 5, brightness: Float = 0.5) -> [Float] {
        let len = max(2, Int(kSampleRate / freq))
        var line = [Float](repeating: 0, count: len)
        var n = NoiseGen(seed: seed)
        for i in 0..<len { line[i] = n.next() }
        var idx = 0
        var prev: Float = 0
        return render(seconds) { _, _ in
            let cur = line[idx]
            let next = line[(idx + 1) % len]
            let avg = (cur * (0.5 + brightness * 0.5) + next * (0.5 - brightness * 0.5))
            line[idx] = avg * damping
            idx = (idx + 1) % len
            prev = cur
            return prev
        }
    }
}

/// Freeverb-style stereo reverb (4 combs + 2 allpasses per channel, lightweight).
public final class Reverb {
    private final class Comb {
        var buf: [Float]; var idx = 0; var store: Float = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
        @inline(__always) func process(_ x: Float, feedback: Float, damp: Float) -> Float {
            let out = buf[idx]
            store = out * (1 - damp) + store * damp
            buf[idx] = x + store * feedback
            idx += 1; if idx >= buf.count { idx = 0 }
            return out
        }
    }
    private final class Allpass {
        var buf: [Float]; var idx = 0
        init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
        @inline(__always) func process(_ x: Float) -> Float {
            let b = buf[idx]
            let out = -x + b
            buf[idx] = x + b * 0.5
            idx += 1; if idx >= buf.count { idx = 0 }
            return out
        }
    }
    private let combsL = [1116, 1277, 1422, 1557].map { Comb($0 * 48 / 44) }
    private let combsR = [1139, 1300, 1445, 1580].map { Comb($0 * 48 / 44) }
    private let apL = [556, 441].map { Allpass($0 * 48 / 44) }
    private let apR = [579, 464].map { Allpass($0 * 48 / 44) }
    public var roomSize: Float = 0.84
    public var damp: Float = 0.3

    public init() {}

    @inline(__always) public func process(_ l: Float, _ r: Float) -> (Float, Float) {
        let input = (l + r) * 0.015
        var ol: Float = 0, or: Float = 0
        for c in combsL { ol += c.process(input, feedback: roomSize, damp: damp) }
        for c in combsR { or += c.process(input, feedback: roomSize, damp: damp) }
        for a in apL { ol = a.process(ol) }
        for a in apR { or = a.process(or) }
        return (ol, or)
    }
}
