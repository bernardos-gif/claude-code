// Procedural adaptive music: taiko/war drums, bass, string and choir pads, plucked or
// bell leads. Intensity (0..1) brings layers in and out; boss phases shift harmony and
// tempo; deathblows drop the whole mix out for a beat of silence.
import Foundation

public enum MusicCommand {
    case style(MusicStyle)
    case intensity(Float)
    case phase(Int)
    case drop(Double)          // seconds of silence
    case stinger(Int)          // 0 victory, 1 defeat
    case menu(Bool)
    case enabled(Bool)
}

public final class MusicEngine {
    private var style = MusicStyle()
    private var intensity: Float = 0.2
    private var intensityTarget: Float = 0.2
    private var phase = 1
    private var menuMode = true
    private var enabled = true
    private var dropSamples = 0
    private var master: Float = 0
    private var sample = 0
    private var stepIndex = 0
    private var samplesToStep = 0
    private var bar = 0
    // Drum samples.
    private var kit: [String: [Float]] = [:]
    private struct DrumVoice { var buf: [Float]; var pos: Int; var gain: Float; var pan: Float }
    private var drums: [DrumVoice] = []
    // Pads.
    private var padOsc = [SawOsc](repeating: SawOsc(), count: 8)
    private var padFreq = [Float](repeating: 110, count: 4)
    private var padTarget = [Float](repeating: 110, count: 4)
    private var padLP = [Biquad(), Biquad()]
    private var choirOsc = [SawOsc](repeating: SawOsc(), count: 3)
    private var choirF1 = [Biquad(), Biquad(), Biquad()]
    private var choirF2 = [Biquad(), Biquad(), Biquad()]
    private var vowel: Float = 0
    // Bass.
    private var bassOsc = SawOsc()
    private var bassSubPhase: Float = 0
    private var bassFreq: Float = 55
    private var bassEnv: Float = 0
    private var bassLP = Biquad()
    // Lead (Karplus-Strong strings, bells).
    private final class KS {
        var line: [Float]; var idx = 0; var damp: Float
        init(freq: Float, seed: UInt32, damp: Float) {
            let n = max(2, Int(kSampleRate / freq))
            var g = NoiseGen(seed: seed)
            line = (0..<n).map { _ in g.next() }
            self.damp = damp
        }
        @inline(__always) func next() -> Float {
            let a = line[idx], b = line[(idx + 1) % line.count]
            line[idx] = (a + b) * 0.5 * damp
            idx = (idx + 1) % line.count
            return a
        }
    }
    private var plucks: [(KS, Float, Int)] = []   // string, gain, remaining samples
    private struct Bell { var freq: Float; var t: Float; var gain: Float }
    private var bells: [Bell] = []
    private var breath = NoiseGen(seed: 91)
    private var breathBP = Biquad()
    private var leadTone: (freq: Float, t: Float, gain: Float) = (0, 99, 0)
    private var noise = NoiseGen(seed: 5)
    private var rng = Rng(seed: 17)
    private var chordIndex = 0
    private var stingerQueue: Int?

    public init() {
        buildKit()
        padLP[0].set(.lowpass, freq: 900, q: 0.7)
        padLP[1].set(.lowpass, freq: 900, q: 0.7)
        bassLP.set(.lowpass, freq: 320, q: 1.1)
        breathBP.set(.bandpass, freq: 900, q: 1.5)
        for i in 0..<8 { padOsc[i].phase = Float(i) * 0.137 }
    }

    private func buildKit() {
        var n = NoiseGen(seed: 3)
        var lp = Biquad(); lp.set(.lowpass, freq: 400, q: 0.8)
        kit["taiko"] = DSP.render(0.6) { t, _ in sin(t * kTwoPi * (78 - 30 * t)) * exp(-t / 0.18) * 1.2 + lp.process(n.next()) * exp(-t / 0.04) * 0.8 }
        kit["boom"] = DSP.render(1.0) { t, _ in sin(t * kTwoPi * (48 - 12 * t)) * exp(-t / 0.35) * 1.3 }
        var bp = Biquad(); bp.set(.bandpass, freq: 1800, q: 0.8)
        kit["snare"] = DSP.render(0.3) { t, _ in bp.process(n.next()) * exp(-t / 0.07) * 1.4 + sin(t * 190 * kTwoPi) * exp(-t / 0.05) * 0.5 }
        var hp = Biquad(); hp.set(.highpass, freq: 7000, q: 0.7)
        kit["hat"] = DSP.render(0.08) { t, _ in hp.process(n.next()) * exp(-t / 0.018) }
        kit["clack"] = DSP.render(0.08) { t, _ in (sin(t * 2200 * kTwoPi) + sin(t * 3400 * kTwoPi)) * exp(-t / 0.012) * 0.6 }
        kit["metal"] = DSP.modal(0.5, base: 420, ratios: [1, 2.3, 3.7, 5.1], decays: [0.25, 0.15, 0.1, 0.07], amps: [0.8, 0.5, 0.4, 0.3], seed: 8)
        for (k, var v) in kit { DSP.finalize(&v, peak: 0.9); kit[k] = v }
    }

    func apply(_ c: MusicCommand) {
        switch c {
        case .style(let s): style = s; chordIndex = 0
        case .intensity(let i): intensityTarget = clampf(i, 0, 1)
        case .phase(let p): phase = p
        case .drop(let s): dropSamples = Int(s * Double(kSampleRate))
        case .stinger(let k): stingerQueue = k
        case .menu(let m): menuMode = m
        case .enabled(let e): enabled = e
        }
    }

    private var scale: [Int] {
        switch style.mode {
        case "phrygian": return [0, 1, 3, 5, 7, 8, 10]
        case "harmonicMinor": return [0, 2, 3, 5, 7, 8, 11]
        case "dorian": return [0, 2, 3, 5, 7, 9, 10]
        case "locrian": return [0, 1, 3, 5, 6, 8, 10]
        default: return [0, 2, 3, 5, 7, 8, 10]
        }
    }

    private var progression: [[Int]] {
        switch style.mode {
        case "phrygian": return [[0, 3, 7, 12], [1, 5, 8, 13], [0, 3, 7, 15], [-2, 1, 5, 10]]
        case "harmonicMinor": return [[0, 3, 7, 12], [5, 8, 12, 15], [7, 11, 14, 19], [0, 3, 7, 15]]
        case "dorian": return [[0, 3, 7, 10], [5, 9, 12, 16], [-2, 2, 5, 10], [0, 3, 7, 14]]
        case "locrian": return [[0, 3, 6, 12], [1, 5, 8, 13], [5, 8, 12, 15], [0, 3, 6, 10]]
        default: return [[0, 3, 7, 12], [-4, 0, 3, 8], [-2, 2, 5, 10], [-5, -2, 2, 7]]
        }
    }

    private func pattern(_ voice: String) -> [Float] {
        // 16-step velocity patterns per drum style.
        switch (style.drums, voice) {
        case ("taiko", "boom"): return [1, 0, 0, 0, 0, 0, 0, 0, 0.8, 0, 0, 0.6, 0, 0, 0, 0]
        case ("taiko", "taiko"): return [1, 0, 0, 0.7, 0, 0, 0.8, 0, 1, 0, 0, 0.6, 0, 0, 0.9, 0.5]
        case ("taiko", "clack"): return [0, 0, 0, 0, 0.8, 0, 0, 0, 0, 0, 0, 0, 0.8, 0, 0, 0]
        case ("march", "boom"): return [1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
        case ("march", "snare"): return [0, 0, 0, 0, 1, 0, 0, 0.3, 0, 0, 0, 0, 1, 0, 0.4, 0.3]
        case ("march", "hat"): return [0.6, 0, 0.4, 0, 0.6, 0, 0.4, 0, 0.6, 0, 0.4, 0, 0.6, 0, 0.4, 0]
        case ("tribal", "taiko"): return [1, 0, 0.6, 0, 0, 0.8, 0, 0, 1, 0, 0.6, 0, 0, 0.8, 0, 0.5]
        case ("tribal", "clack"): return [0, 0, 0, 0.6, 0, 0, 0, 0.6, 0, 0, 0, 0.6, 0, 0, 0, 0.6]
        case ("tribal", "boom"): return [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case ("industrial", "metal"): return [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0.5, 0]
        case ("industrial", "boom"): return [1, 0, 0, 0, 0, 0, 0.8, 0, 1, 0, 0, 0, 0, 0, 0, 0]
        case ("industrial", "hat"): return [0.5, 0.3, 0.5, 0.3, 0.5, 0.3, 0.5, 0.3, 0.5, 0.3, 0.5, 0.3, 0.5, 0.3, 0.5, 0.3]
        case ("sparse", "boom"): return [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case ("sparse", "taiko"): return [0, 0, 0, 0, 0, 0, 0, 0, 0.8, 0, 0, 0, 0, 0, 0, 0]
        case ("sparse", "clack"): return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.6, 0, 0, 0]
        case ("war", "taiko"): return [1, 0.4, 0.6, 0.4, 0.9, 0.4, 0.6, 0.4, 1, 0.4, 0.6, 0.4, 0.9, 0.5, 0.7, 0.6]
        case ("war", "boom"): return [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
        case ("war", "snare"): return [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0]
        default: return [Float](repeating: 0, count: 16)
        }
    }

    private func trigger(_ name: String, _ vel: Float, pan: Float = 0) {
        guard vel > 0, let b = kit[name] else { return }
        if drums.count > 24 { drums.removeFirst() }
        drums.append(DrumVoice(buf: b, pos: 0, gain: vel, pan: pan))
    }

    private func noteFreq(_ semis: Int, octave: Int = 0) -> Float {
        let transpose = phase >= 3 ? 1 : 0   // final phases lift a semitone for tension
        return DSP.midiToFreq(Float(style.root + semis + transpose + octave * 12))
    }

    private func step() {
        let i = intensity
        let s = stepIndex % 16
        if menuMode {
            if s == 0 && bar % 2 == 0 { trigger("boom", 0.35) }
        } else if i > 0.12 {
            for v in ["boom", "taiko", "clack", "snare", "hat", "metal"] {
                let p = pattern(v)
                var vel = p[s]
                if i < 0.45 && (v == "hat" || v == "snare") { vel *= 0 }
                if i < 0.3 && v == "taiko" && s % 8 != 0 { vel = 0 }
                if vel > 0 && rng.chance(0.9) { trigger(v, vel * (0.6 + 0.5 * i), pan: v == "hat" ? 0.3 : (v == "clack" ? -0.25 : 0)) }
            }
        }
        // Harmony: new chord every 2 bars.
        if s == 0 && bar % 2 == 0 {
            let chord = progression[chordIndex % progression.count]
            for k in 0..<4 { padTarget[k] = noteFreq(chord[k], octave: 0) }
            chordIndex += 1
        }
        let chord = progression[(chordIndex + progression.count - 1) % progression.count]
        // Bass on 8ths with octave jumps.
        if !menuMode && i > 0.35 && (s % 2 == 0) {
            let pat: [Int] = [0, 0, 12, 0, 7, 0, 12, 10]
            bassFreq = noteFreq(chord[0] + pat[(s / 2) % 8], octave: -1)
            bassEnv = 1
        }
        // Lead.
        if i > 0.7 || (menuMode && s % 8 == 4) {
            let density = menuMode ? 8 : (i > 0.85 ? 2 : 4)
            if s % density == 0 {
                let tone = chord[(stepIndex / density) % 4] + (s % 8 == 0 ? 12 : 0)
                let f = noteFreq(tone, octave: 1)
                switch style.lead {
                case "bell":
                    bells.append(Bell(freq: f, t: 0, gain: 0.25))
                    if bells.count > 6 { bells.removeFirst() }
                case "shakuhachi", "brass":
                    leadTone = (f, 0, 0.3)
                case "none":
                    break
                default:
                    plucks.append((KS(freq: f, seed: UInt32(stepIndex & 0xffff), damp: 0.994), 0.35, Int(kSampleRate * 1.5)))
                    if plucks.count > 6 { plucks.removeFirst() }
                }
            }
        }
        stepIndex += 1
        if stepIndex % 16 == 0 { bar += 1 }
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, gain: Float,
                reverbL: inout [Float], reverbR: inout [Float]) {
        guard enabled else { return }
        let tempo = style.tempo * (1 + 0.04 * Float(max(0, phase - 1)))
        let stepLen = Int(60 / tempo / 4 * kSampleRate)
        for f in 0..<frames {
            if samplesToStep <= 0 { step(); samplesToStep = stepLen }
            samplesToStep -= 1
            sample += 1
            if f % 64 == 0 {
                intensity += (intensityTarget - intensity) * 0.002 * 64 / 8
                let cutoff = 500 + 2600 * intensity * intensity
                padLP[0].set(.lowpass, freq: cutoff, q: 0.7)
                padLP[1].set(.lowpass, freq: cutoff * 1.1, q: 0.7)
                vowel = 0.5 + 0.5 * sin(Float(sample) / kSampleRate * 0.2)
                for k in 0..<3 {
                    choirF1[k].set(.bandpass, freq: 500 + 300 * vowel, q: 5)
                    choirF2[k].set(.bandpass, freq: 800 + 400 * vowel, q: 6)
                }
            }
            let targetMaster: Float = dropSamples > 0 ? 0 : 1
            if dropSamples > 0 { dropSamples -= 1 }
            master += (targetMaster - master) * (targetMaster > master ? 0.0002 : 0.01)
            var l: Float = 0, r: Float = 0
            // Pads.
            for k in 0..<4 { padFreq[k] += (padTarget[k] - padFreq[k]) * 0.0005 }
            var padL: Float = 0, padR: Float = 0
            for k in 0..<4 {
                padL += padOsc[k * 2].next(padFreq[k] * 0.997)
                padR += padOsc[k * 2 + 1].next(padFreq[k] * 1.003)
            }
            let padGain: Float = (menuMode ? 0.09 : 0.06) * (0.6 + 0.4 * (1 - intensity * 0.5))
            l += padLP[0].process(padL) * padGain
            r += padLP[1].process(padR) * padGain
            // Choir (formant filtered saws) for mid/high intensity or choir styles.
            let choirLevel: Float = (style.pad == "choir" ? 0.7 : 0.25) * saturatef((intensity - 0.4) * 2.5) + (menuMode ? 0.3 : 0)
            if choirLevel > 0.01 {
                var c: Float = 0
                for k in 0..<3 {
                    let x = choirOsc[k].next(padFreq[k] * (k == 0 ? 1 : 1.002))
                    c += choirF1[k].process(x) + choirF2[k].process(x) * 0.6
                }
                l += c * 0.06 * choirLevel
                r += c * 0.06 * choirLevel
            }
            // Bass.
            if bassEnv > 0.001 {
                bassSubPhase += bassFreq / kSampleRate
                if bassSubPhase > 1 { bassSubPhase -= 1 }
                let b = bassLP.process(bassOsc.next(bassFreq)) * 0.6 + sin(bassSubPhase * kTwoPi) * 0.8
                bassEnv *= 0.99985
                let v = b * bassEnv * 0.18 * saturatef((intensity - 0.3) * 3)
                l += v; r += v
            }
            // Leads.
            var lead: Float = 0
            var pi = 0
            while pi < plucks.count {
                lead += plucks[pi].0.next() * plucks[pi].1
                plucks[pi].2 -= 1
                if plucks[pi].2 <= 0 { plucks.remove(at: pi) } else { pi += 1 }
            }
            var bi = 0
            while bi < bells.count {
                let b = bells[bi]
                let mod = sin(b.t * b.freq * 3.5 * kTwoPi) * 1.8 * exp(-b.t / 0.4)
                lead += sin(b.t * b.freq * kTwoPi + mod) * exp(-b.t / 0.9) * b.gain
                bells[bi].t += 1 / kSampleRate
                if bells[bi].t > 3 { bells.remove(at: bi) } else { bi += 1 }
            }
            if leadTone.t < 1.2 {
                let t = leadTone.t
                let env = min(1, t / 0.08) * exp(-t / 0.5)
                let tone = style.lead == "brass" ? (padOsc[0].phase * 2 - 1) * 0.3 + sin(t * leadTone.freq * kTwoPi) * 0.7
                                                 : sin(t * leadTone.freq * kTwoPi + sin(t * 5 * kTwoPi) * 0.2)
                lead += (tone + breathBP.process(breath.next()) * 0.3) * env * leadTone.gain
                leadTone.t += 1 / kSampleRate
            }
            l += lead * 0.5
            r += lead * 0.5
            // Drums.
            var di = 0
            while di < drums.count {
                let d = drums[di]
                if d.pos >= d.buf.count { drums.remove(at: di); continue }
                let x = d.buf[d.pos] * d.gain * 0.5
                l += x * (1 - max(0, d.pan))
                r += x * (1 + min(0, d.pan))
                drums[di].pos += 1
                di += 1
            }
            let g = gain * master * style.intensity
            left[f] += l * g
            right[f] += r * g
            reverbL[f] += l * g * 0.6
            reverbR[f] += r * g * 0.6
        }
        if let s = stingerQueue {
            stingerQueue = nil
            if s == 0 { bells.append(Bell(freq: noteFreq(12, octave: 1), t: 0, gain: 0.4)); bells.append(Bell(freq: noteFreq(19, octave: 1), t: -0.15, gain: 0.3)) }
            else { trigger("boom", 1.0) }
        }
    }
}
