// Every sound effect in the game, synthesized at startup (no audio files).
import Foundation

public final class SoundBuffer {
    public let name: String
    public let samples: [Float]
    public let loop: Bool
    public init(name: String, samples: [Float], loop: Bool = false) { self.name = name; self.samples = samples; self.loop = loop }
    public var duration: Float { Float(samples.count) / kSampleRate }
}

public final class SoundBank {
    public private(set) var sounds: [String: [SoundBuffer]] = [:]

    public init() {}

    public func variants(_ name: String) -> [SoundBuffer] { sounds[name] ?? [] }

    /// Synthesizes the full bank (parallel). Takes well under a second on Apple Silicon.
    public func generate() {
        typealias Job = (String, Int, Bool, () -> [Float])
        var jobs: [Job] = []
        func add(_ name: String, variants: Int = 1, loop: Bool = false, _ f: @escaping (UInt32) -> [Float]) {
            for v in 0..<variants { jobs.append((name, v, loop, { f(UInt32(v * 7919 + name.count * 131 + 1)) })) }
        }
        // --- Metal clashes and parries.
        add("clash", variants: 4) { s in
            var b = DSP.modal(0.55, base: 900 + Float(s % 5) * 90, ratios: [1, 2.37, 3.9, 5.3, 7.1, 9.6], decays: [0.25, 0.18, 0.12, 0.09, 0.06, 0.04],
                              amps: [1, 0.8, 0.6, 0.5, 0.35, 0.25], seed: s, strike: 0.006)
            DSP.finalize(&b, peak: 0.8); return b
        }
        add("parry", variants: 3) { s in
            let ring = DSP.modal(1.1, base: 1380 + Float(s % 3) * 60, ratios: [1, 2.76, 5.4, 8.93, 13.3], decays: [0.7, 0.45, 0.3, 0.2, 0.12],
                                 amps: [1, 0.7, 0.5, 0.3, 0.2], seed: s, strike: 0.003)
            var body = DSP.modal(0.4, base: 520, ratios: [1, 1.8, 2.9], decays: [0.15, 0.1, 0.07], amps: [0.6, 0.4, 0.3], seed: s &+ 9)
            body = DSP.mix(body, ring, 1)
            DSP.finalize(&body, peak: 0.85); return body
        }
        add("parry_perfect", variants: 2) { s in
            let a = DSP.modal(1.8, base: 1760, ratios: [1, 2.76, 5.4, 8.93, 13.3, 17.8], decays: [1.2, 0.8, 0.5, 0.35, 0.2, 0.15],
                              amps: [1, 0.75, 0.55, 0.4, 0.3, 0.2], seed: s, strike: 0.002)
            let b = DSP.modal(1.6, base: 1768, ratios: [1, 2.01, 3.02], decays: [1.0, 0.7, 0.5], amps: [0.6, 0.35, 0.2], seed: s &+ 5)
            let ting = DSP.modal(0.9, base: 5200, ratios: [1, 1.5], decays: [0.5, 0.3], amps: [0.4, 0.2], seed: s &+ 11)
            let sub = DSP.render(0.4) { t, _ in sin(t * 90 * kTwoPi * (1 - t)) * exp(-t / 0.12) * 0.8 }
            var out = DSP.mix(DSP.mix(DSP.mix(a, b, 0.8), ting, 0.7), sub, 1)
            DSP.finalize(&out, peak: 0.9); return out
        }
        add("block", variants: 3) { s in
            let clank = DSP.modal(0.3, base: 420 + Float(s % 4) * 30, ratios: [1, 2.1, 3.3, 4.7], decays: [0.12, 0.08, 0.05, 0.03], amps: [1, 0.6, 0.4, 0.3], seed: s)
            var n = NoiseGen(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 900, q: 0.7)
            let thud = DSP.render(0.2) { t, _ in lp.process(n.next()) * exp(-t / 0.04) * 1.5 + sin(t * 110 * kTwoPi) * exp(-t / 0.06) }
            var out = DSP.mix(thud, clank, 0.8)
            DSP.finalize(&out, peak: 0.8); return out
        }
        // --- Impacts.
        add("hit_flesh", variants: 4) { s in
            var n = NoiseGen(seed: s)
            var bp = Biquad(); bp.set(.bandpass, freq: 700 + Float(s % 4) * 120, q: 0.9)
            var out = DSP.render(0.32) { t, _ in
                let thump = sin(t * kTwoPi * (95 - 50 * t)) * exp(-t / 0.07) * 1.2
                let squelch = bp.process(n.next()) * exp(-t / 0.05) * 1.6
                return thump + squelch
            }
            DSP.finalize(&out, peak: 0.85); return out
        }
        add("hit_heavy", variants: 3) { s in
            var n = NoiseGen(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 1400, q: 0.8)
            let body = DSP.render(0.7) { t, _ in
                sin(t * kTwoPi * (62 - 30 * t)) * exp(-t / 0.18) * 1.4 + lp.process(n.next()) * exp(-t / 0.09) * 1.3
            }
            let crunch = DSP.modal(0.35, base: 300, ratios: [1, 2.3, 3.7], decays: [0.1, 0.07, 0.05], amps: [0.6, 0.4, 0.3], seed: s &+ 2)
            var out = DSP.mix(body, crunch, 0.7)
            DSP.finalize(&out, peak: 0.9); return out
        }
        add("hit_blunt", variants: 3) { s in
            var n = NoiseGen(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 700, q: 0.9)
            var out = DSP.render(0.4) { t, _ in sin(t * kTwoPi * (75 - 40 * t)) * exp(-t / 0.1) * 1.3 + lp.process(n.next()) * exp(-t / 0.05) }
            DSP.finalize(&out, peak: 0.85); return out
        }
        // --- Whooshes by weapon speed.
        add("whoosh_fast", variants: 4) { s in var b = DSP.whoosh(0.14, from: 3200, to: 900, q: 1.4, seed: s, shape: 1.5); DSP.finalize(&b, peak: 0.55); return b }
        add("whoosh_med", variants: 4) { s in var b = DSP.whoosh(0.24, from: 2200, to: 600, q: 1.2, seed: s, shape: 1.8); DSP.finalize(&b, peak: 0.6); return b }
        add("whoosh_heavy", variants: 3) { s in var b = DSP.whoosh(0.42, from: 1100, to: 260, q: 1.0, seed: s, shape: 2.2); DSP.finalize(&b, peak: 0.7); return b }
        add("whoosh_chain", variants: 3) { s in
            let w = DSP.whoosh(0.36, from: 1800, to: 500, q: 1.1, seed: s)
            var rng = NoiseGen(seed: s &+ 4)
            var clinks = [Float](repeating: 0, count: w.count)
            for _ in 0..<9 {
                let at = Int(abs(rng.next()) * Float(w.count - 4000))
                let c = DSP.modal(0.06, base: 3000 + abs(rng.next()) * 2500, ratios: [1, 1.6], decays: [0.02, 0.015], amps: [0.4, 0.2], seed: s)
                for i in 0..<c.count where at + i < clinks.count { clinks[at + i] += c[i] }
            }
            var out = DSP.mix(w, clinks, 0.6)
            DSP.finalize(&out, peak: 0.6); return out
        }
        add("dodge", variants: 3) { s in var b = DSP.whoosh(0.22, from: 900, to: 350, q: 0.9, seed: s); DSP.finalize(&b, peak: 0.45); return b }
        add("slowmo") { s in
            var a = DSP.whoosh(0.9, from: 2600, to: 180, q: 2.5, seed: s, shape: 0.8)
            let tone = DSP.render(0.9) { t, _ in sin(t * kTwoPi * (600 * exp(-t * 2))) * exp(-t / 0.4) * 0.3 }
            a = DSP.mix(a, tone)
            DSP.finalize(&a, peak: 0.6); return a
        }
        // --- Footsteps per material.
        for (mat, freq, q, dec) in [("stone", Float(2200), Float(1.2), Float(0.03)), ("dirt", 700, 0.8, 0.05), ("wood", 900, 3.0, 0.06),
                                    ("snow", 1600, 0.6, 0.09), ("metal", 2600, 6.0, 0.08), ("water", 1400, 0.7, 0.1), ("sand", 1200, 0.5, 0.06)] {
            add("step_\(mat)", variants: 4) { s in
                var n = NoiseGen(seed: s)
                var bp = Biquad(); bp.set(.bandpass, freq: freq * (0.9 + Float(s % 5) * 0.05), q: q)
                var out = DSP.render(dec * 4) { t, _ in bp.process(n.next()) * exp(-t / dec) + (mat == "wood" ? sin(t * 180 * kTwoPi) * exp(-t / 0.03) * 0.5 : 0) }
                DSP.finalize(&out, peak: 0.4); return out
            }
        }
        add("cloth", variants: 3) { s in var b = DSP.whoosh(0.3, from: 1800, to: 1200, q: 0.5, seed: s, shape: 1); DSP.finalize(&b, peak: 0.25); return b }
        // --- Telegraph cues (distinct by ear).
        add("tele_white") { s in
            var b = DSP.modal(0.45, base: 2640, ratios: [1, 2, 3.01], decays: [0.25, 0.15, 0.1], amps: [1, 0.4, 0.2], seed: s, strike: 0.001)
            DSP.finalize(&b, peak: 0.6); return b
        }
        add("tele_red") { s in
            var saws = [SawOsc(phase: 0), SawOsc(phase: 0.3), SawOsc(phase: 0.6)]
            var lp = Biquad()
            var out = DSP.render(0.75) { t, i in
                if i % 64 == 0 { lp.set(.lowpass, freq: 300 + 1600 * sin(kPi * min(1, t / 0.6)), q: 1.2) }
                let f: Float = 98
                let x = saws[0].next(f) + saws[1].next(f * 1.012) + saws[2].next(f * 0.5)
                return DSP.softClip(lp.process(x) * 1.5) * sin(kPi * min(1, t / 0.75))
            }
            let shing = DSP.whoosh(0.5, from: 800, to: 4200, q: 3, seed: s)
            out = DSP.mix(out, shing, 0.5, offset: Int(0.2 * kSampleRate))
            DSP.finalize(&out, peak: 0.7); return out
        }
        add("tele_purple") { s in
            var n = NoiseGen(seed: s)
            var bp = Biquad(); bp.set(.bandpass, freq: 1500, q: 4)
            var out = DSP.render(0.6) { t, _ in
                let swell = pow(t / 0.6, 2.5)
                let trem = 0.6 + 0.4 * sin(t * 38 * kTwoPi)
                return (bp.process(n.next()) * 0.8 + sin(t * 660 * kTwoPi) * 0.3 + sin(t * 663 * kTwoPi) * 0.3) * swell * trem
            }
            DSP.finalize(&out, peak: 0.6, fadeOut: 0.004); return out
        }
        add("tele_gold") { s in
            // FM bell.
            var out = DSP.render(1.4) { t, _ in
                let mod = sin(t * 880 * 3.5 * kTwoPi) * 2.2 * exp(-t / 0.3)
                return sin(t * 880 * kTwoPi + mod) * exp(-t / 0.5) + sin(t * 1320 * kTwoPi) * exp(-t / 0.3) * 0.3
            }
            DSP.finalize(&out, peak: 0.6); _ = s; return out
        }
        // --- Big moments.
        add("posture_break") { s in
            var n = NoiseGen(seed: s)
            let crack = DSP.render(0.4) { t, _ in n.next() * exp(-t / 0.05) * 1.4 + sin(t * kTwoPi * (55 - 20 * t)) * exp(-t / 0.2) * 1.5 }
            let gong = DSP.modal(2.4, base: 180, ratios: [1, 1.52, 2.26, 2.93, 3.8], decays: [1.8, 1.2, 0.9, 0.6, 0.4], amps: [1, 0.7, 0.5, 0.4, 0.3], seed: s)
            var out = DSP.mix(crack, gong, 0.8)
            DSP.finalize(&out, peak: 0.9); return out
        }
        add("deathblow") { s in
            let slash = DSP.whoosh(0.3, from: 3000, to: 500, q: 1.5, seed: s)
            let drop = DSP.render(1.4) { t, _ in sin(t * kTwoPi * (70 * exp(-t * 0.8))) * exp(-t / 0.6) * 1.2 }
            let ring = DSP.modal(1.6, base: 1100, ratios: [1, 2.76, 5.4], decays: [0.9, 0.5, 0.3], amps: [0.5, 0.3, 0.2], seed: s)
            var out = DSP.mix(DSP.mix(drop, slash, 0.8), ring, 0.5)
            DSP.finalize(&out, peak: 0.95); return out
        }
        add("boss_death") { s in
            let gong = DSP.modal(4.0, base: 110, ratios: [1, 1.52, 2.26, 2.93, 3.8, 4.4], decays: [3, 2, 1.4, 1, 0.8, 0.6], amps: [1, 0.8, 0.6, 0.5, 0.4, 0.3], seed: s)
            var saws = (0..<6).map { SawOsc(phase: Float($0) * 0.17) }
            var lp = Biquad(); lp.set(.lowpass, freq: 1200, q: 0.7)
            let freqs: [Float] = [110, 164.8, 220, 261.6, 329.6, 440]
            let chord = DSP.render(4.0) { t, _ in
                var x: Float = 0
                for k in 0..<6 { x += saws[k].next(freqs[k] * (1 + 0.002 * Float(k))) }
                return lp.process(x) * 0.25 * sin(kPi * min(1, t / 4))
            }
            var out = DSP.mix(gong, chord, 0.8)
            DSP.finalize(&out, peak: 0.85); return out
        }
        add("player_death") { s in
            var n = NoiseGen(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 300, q: 0.7)
            var out = DSP.render(2.6) { t, _ in
                sin(t * kTwoPi * (48 - 10 * t)) * exp(-t / 0.9) * 1.2 + lp.process(n.next()) * exp(-t / 1.2) * 0.8
            }
            DSP.finalize(&out, peak: 0.9); return out
        }
        add("heal") { s in
            var out: [Float] = []
            for (k, f) in [Float(523.3), 659.3, 784.0, 1046.5].enumerated() {
                let note = DSP.render(1.2) { t, _ in sin(t * f * kTwoPi) * exp(-t / 0.5) * 0.4 + sin(t * f * 2 * kTwoPi) * exp(-t / 0.2) * 0.15 }
                out = DSP.mix(out, note, 1, offset: Int(Float(k) * 0.07 * kSampleRate))
            }
            DSP.finalize(&out, peak: 0.5); _ = s; return out
        }
        add("ui_move") { _ in var b = DSP.render(0.05) { t, _ in sin(t * 1800 * kTwoPi) * exp(-t / 0.012) }; DSP.finalize(&b, peak: 0.25); return b }
        add("ui_confirm") { _ in
            var b = DSP.mix(DSP.render(0.25) { t, _ in sin(t * 880 * kTwoPi) * exp(-t / 0.08) },
                            DSP.render(0.3) { t, _ in sin(t * 1320 * kTwoPi) * exp(-t / 0.1) }, 1, offset: Int(0.06 * kSampleRate))
            DSP.finalize(&b, peak: 0.35); return b
        }
        add("ui_back") { _ in var b = DSP.render(0.12) { t, _ in sin(t * 440 * kTwoPi * (1 - t)) * exp(-t / 0.04) }; DSP.finalize(&b, peak: 0.3); return b }
        // --- Elemental bursts.
        add("burst_fire", variants: 2) { s in
            var n = NoiseGen(seed: s)
            var lp = Biquad()
            var out = DSP.render(1.0) { t, i in
                if i % 64 == 0 { lp.set(.lowpass, freq: 3000 * exp(-t * 2) + 300, q: 0.8) }
                return lp.process(n.next()) * (t < 0.05 ? t / 0.05 : exp(-(t - 0.05) / 0.35)) * 1.3
            }
            DSP.finalize(&out, peak: 0.8); return out
        }
        add("burst_ice", variants: 2) { s in
            var out: [Float] = []
            var rng = NoiseGen(seed: s)
            for k in 0..<18 {
                let c = DSP.modal(0.3, base: 2500 + abs(rng.next()) * 4000, ratios: [1, 1.7, 2.6], decays: [0.1, 0.07, 0.04], amps: [0.5, 0.3, 0.2], seed: s &+ UInt32(k))
                out = DSP.mix(out, c, 1, offset: Int(abs(rng.next()) * 0.25 * kSampleRate))
            }
            DSP.finalize(&out, peak: 0.7); return out
        }
        add("burst_lightning", variants: 2) { s in
            var n = NoiseGen(seed: s)
            var hp = Biquad(); hp.set(.highpass, freq: 1500, q: 0.7)
            var out = DSP.render(0.8) { t, _ in
                hp.process(n.next()) * exp(-t / 0.06) * 1.5 + sin(t * kTwoPi * (3000 * exp(-t * 8) + 80)) * exp(-t / 0.2) * 0.6
                    + n.next() * exp(-t / 0.3) * 0.3 * (sin(t * 70 * kTwoPi) > 0 ? 1 : 0.2)
            }
            DSP.finalize(&out, peak: 0.85); return out
        }
        add("burst_shadow", variants: 2) { s in
            var b = DSP.whoosh(0.9, from: 180, to: 1600, q: 1.5, seed: s, shape: 3)
            b = DSP.mix(b, DSP.render(0.9) { t, _ in sin(t * 55 * kTwoPi) * pow(t / 0.9, 2) * 0.7 })
            DSP.finalize(&b, peak: 0.8, fadeOut: 0.005); return b
        }
        add("burst_holy", variants: 1) { s in
            let chime = DSP.modal(1.5, base: 1046, ratios: [1, 1.5, 2, 3], decays: [0.9, 0.7, 0.5, 0.3], amps: [0.6, 0.4, 0.3, 0.2], seed: s)
            var b = DSP.mix(DSP.whoosh(0.7, from: 400, to: 3000, q: 1, seed: s), chime, 0.8)
            DSP.finalize(&b, peak: 0.8); return b
        }
        add("burst_earth", variants: 2) { s in
            var n = NoiseGen(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 500, q: 0.7)
            var out = DSP.render(0.9) { t, _ in lp.process(n.next()) * exp(-t / 0.25) * 2 + sin(t * kTwoPi * (50 - 20 * t)) * exp(-t / 0.3) }
            DSP.finalize(&out, peak: 0.9); return out
        }
        add("thunder", variants: 2) { s in
            var n = PinkNoise(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 260, q: 0.6)
            var rng = NoiseGen(seed: s &+ 1)
            var out = DSP.render(4.5) { t, _ in
                let env = exp(-t / 1.6) * (0.7 + 0.3 * sin(t * 3 + abs(rng.next()) * 0.3))
                return lp.process(n.next()) * env * 4 + (t < 0.08 ? n.next() * (1 - t / 0.08) * 0.8 : 0)
            }
            DSP.finalize(&out, peak: 0.9, fadeOut: 0.3); return out
        }
        add("swap") { s in var b = DSP.whoosh(0.25, from: 4000, to: 2500, q: 6, seed: s, shape: 1); DSP.finalize(&b, peak: 0.4); return b }
        add("ability") { s in
            var b = DSP.whoosh(0.7, from: 200, to: 2800, q: 2, seed: s, shape: 2.5)
            b = DSP.mix(b, DSP.modal(0.8, base: 660, ratios: [1, 1.5, 2], decays: [0.5, 0.3, 0.2], amps: [0.4, 0.3, 0.2], seed: s), 0.8,
                        offset: Int(0.5 * kSampleRate))
            DSP.finalize(&b, peak: 0.7); return b
        }
        add("grab") { s in
            var n = NoiseGen(seed: s)
            var b = DSP.render(0.4) { t, _ in n.next() * exp(-t / 0.08) + sin(t * kTwoPi * 70) * exp(-t / 0.15) }
            DSP.finalize(&b, peak: 0.8); return b
        }
        add("counter") { s in
            var b = DSP.mix(DSP.whoosh(0.3, from: 5000, to: 800, q: 2, seed: s),
                            DSP.modal(1.0, base: 1980, ratios: [1, 2.76, 5.4], decays: [0.6, 0.35, 0.2], amps: [0.7, 0.4, 0.2], seed: s), 1)
            DSP.finalize(&b, peak: 0.8); return b
        }
        add("roar") { s in
            var saws = [SawOsc(), SawOsc(phase: 0.4)]
            var bp = Biquad()
            var n = NoiseGen(seed: s)
            var out = DSP.render(1.6) { t, i in
                if i % 64 == 0 { bp.set(.bandpass, freq: 500 + 300 * sin(t * 5), q: 2) }
                let f: Float = 70 + 20 * sin(t * 3)
                return DSP.softClip((bp.process(saws[0].next(f) + saws[1].next(f * 1.5) + n.next() * 0.6)) * 3) * sin(kPi * min(1, t / 1.6))
            }
            DSP.finalize(&out, peak: 0.8); return out
        }
        // --- Ambience loops (crossfaded to loop seamlessly).
        func loopify(_ b: [Float], fade: Int) -> [Float] {
            guard b.count > fade * 2 else { return b }
            var out = Array(b[fade..<b.count])
            for i in 0..<fade {
                let k = Float(i) / Float(fade)
                out[out.count - fade + i] = out[out.count - fade + i] * (1 - k) + b[i] * k
            }
            return out
        }
        add("amb_wind", loop: true) { s in
            var n = PinkNoise(seed: s)
            var bp = Biquad()
            var b = DSP.render(8) { t, i in
                if i % 128 == 0 { bp.set(.bandpass, freq: 400 + 300 * sin(t * 0.7) + 200 * sin(t * 1.9), q: 0.8) }
                return bp.process(n.next()) * (0.6 + 0.4 * sin(t * 0.45))
            }
            b = loopify(b, fade: 24000); DSP.finalize(&b, peak: 0.5, fadeIn: 0, fadeOut: 0); return b
        }
        add("amb_rain", loop: true) { s in
            var n = NoiseGen(seed: s)
            var hp = Biquad(); hp.set(.highpass, freq: 1800, q: 0.5)
            var lp = Biquad(); lp.set(.lowpass, freq: 9000, q: 0.5)
            var rng = NoiseGen(seed: s &+ 9)
            var b = DSP.render(6) { _, _ in
                var x = lp.process(hp.process(n.next())) * 0.6
                if abs(rng.next()) > 0.9993 { x += 0.8 }
                return x
            }
            b = loopify(b, fade: 12000); DSP.finalize(&b, peak: 0.45, fadeIn: 0, fadeOut: 0); return b
        }
        add("amb_fire", loop: true) { s in
            var n = NoiseGen(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 600, q: 0.7)
            var rng = NoiseGen(seed: s &+ 5)
            var crack: Float = 0
            var b = DSP.render(6) { _, _ in
                if abs(rng.next()) > 0.9985 { crack = 1 }
                crack *= 0.985
                return lp.process(n.next()) * 0.5 + n.next() * crack * 0.6
            }
            b = loopify(b, fade: 12000); DSP.finalize(&b, peak: 0.45, fadeIn: 0, fadeOut: 0); return b
        }
        add("amb_sea", loop: true) { s in
            var n = PinkNoise(seed: s)
            var lp = Biquad()
            var b = DSP.render(10) { t, i in
                if i % 128 == 0 { lp.set(.lowpass, freq: 500 + 900 * pow(sin(t * 0.55) * 0.5 + 0.5, 2), q: 0.6) }
                return lp.process(n.next()) * (0.5 + 0.5 * sin(t * 0.55))
            }
            b = loopify(b, fade: 24000); DSP.finalize(&b, peak: 0.45, fadeIn: 0, fadeOut: 0); return b
        }
        add("amb_hum", loop: true) { s in
            var n = PinkNoise(seed: s)
            var lp = Biquad(); lp.set(.lowpass, freq: 180, q: 0.8)
            var b = DSP.render(8) { t, _ in lp.process(n.next()) * 2 + sin(t * 55 * kTwoPi) * 0.15 * (0.7 + 0.3 * sin(t * 0.5)) }
            b = loopify(b, fade: 24000); DSP.finalize(&b, peak: 0.4, fadeIn: 0, fadeOut: 0); return b
        }

        var results = [[Float]](repeating: [], count: jobs.count)
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in buf[i] = jobs[i].3() }
        }
        var out: [String: [SoundBuffer]] = [:]
        for (i, j) in jobs.enumerated() {
            out[j.0, default: []].append(SoundBuffer(name: j.0, samples: results[i], loop: j.2))
        }
        sounds = out
    }
}
