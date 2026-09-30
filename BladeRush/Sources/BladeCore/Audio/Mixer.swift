// Real-time software mixer. The platform audio callback calls `render`, which runs on
// the audio thread; the game thread only enqueues commands (lock held for microseconds).
import Foundation

public enum AudioBus: Int { case sfx = 0, ui, ambience, music }

public final class AudioMixer {
    struct Voice {
        var buffer: SoundBuffer
        var pos: Double = 0
        var rate: Double = 1
        var gain: Float = 1
        var target: Float = 1
        var fade: Float = 0          // gain change per sample toward target
        var pan: Float = 0
        var bus: AudioBus = .sfx
        var loop = false
        var spatial = false
        var position = Vec3.zero
        var id: Int = 0
        var reverbSend: Float = 0.25
        var active = true
    }

    enum Command {
        case play(Voice)
        case stop(Int, Float)
        case gain(Int, Float, Float)
        case listener(Vec3, Vec3, Vec3)
        case volumes(Float, Float, Float, Float, Float)
        case music(MusicCommand)
        case reverb(Float, Float)
    }

    private let lock = NSLock()
    private var pending: [Command] = []
    private var processing: [Command] = []
    private var voices: [Voice] = []
    private let maxVoices = 56
    private var nextId = 1
    private var listenerPos = Vec3.zero
    private var listenerRight = Vec3(-1, 0, 0)
    private var listenerFwd = Vec3(0, 0, 1)
    private var busGain: [Float] = [1, 1, 1, 1]
    private var master: Float = 0.8
    public let music: MusicEngine
    private let reverb = Reverb()
    private var scratchL: [Float] = []
    private var scratchR: [Float] = []
    /// Peak meter for the debug overlay.
    public private(set) var peak: Float = 0

    public init() {
        music = MusicEngine()
        voices.reserveCapacity(maxVoices)
    }

    // MARK: Game thread API

    private func enqueue(_ c: Command) {
        lock.lock(); pending.append(c); lock.unlock()
    }

    @discardableResult
    public func play(_ buffer: SoundBuffer, gain: Float = 1, pitch: Float = 1, pan: Float = 0, at position: Vec3? = nil,
                     bus: AudioBus = .sfx, loop: Bool = false, fadeIn: Float = 0, reverb: Float = 0.25) -> Int {
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        var v = Voice(buffer: buffer)
        v.rate = Double(pitch)
        v.gain = fadeIn > 0 ? 0 : gain
        v.target = gain
        v.fade = fadeIn > 0 ? gain / (fadeIn * kSampleRate) : 0
        v.pan = pan
        v.bus = bus
        v.loop = loop
        v.spatial = position != nil
        v.position = position ?? .zero
        v.id = id
        v.reverbSend = reverb
        enqueue(.play(v))
        return id
    }

    public func stop(_ id: Int, fade: Float = 0.05) { enqueue(.stop(id, fade)) }
    public func setGain(_ id: Int, _ gain: Float, fade: Float = 0.2) { enqueue(.gain(id, gain, fade)) }
    public func setListener(position: Vec3, forward: Vec3, right: Vec3) { enqueue(.listener(position, forward, right)) }
    public func setVolumes(master: Float, music: Float, sfx: Float, ui: Float, ambience: Float) {
        enqueue(.volumes(master, music, sfx, ui, ambience))
    }
    public func musicCommand(_ c: MusicCommand) { enqueue(.music(c)) }
    public func setReverb(room: Float, damp: Float) { enqueue(.reverb(room, damp)) }

    // MARK: Audio thread

    private func applyCommands() {
        lock.lock()
        swap(&pending, &processing)
        lock.unlock()
        defer { processing.removeAll(keepingCapacity: true) }
        for c in processing {
            switch c {
            case .play(let v):
                if voices.count >= maxVoices {
                    // Steal the quietest non-looping voice.
                    if let idx = voices.indices.filter({ !voices[$0].loop }).min(by: { voices[$0].gain < voices[$1].gain }) { voices.remove(at: idx) } else { continue }
                }
                voices.append(v)
            case .stop(let id, let fade):
                for i in voices.indices where voices[i].id == id {
                    voices[i].target = 0
                    voices[i].fade = voices[i].gain / max(1, fade * kSampleRate)
                }
            case .gain(let id, let g, let fade):
                for i in voices.indices where voices[i].id == id {
                    voices[i].target = g
                    voices[i].fade = abs(g - voices[i].gain) / max(1, fade * kSampleRate)
                }
            case .listener(let p, let f, let r):
                listenerPos = p; listenerFwd = f; listenerRight = r
            case .volumes(let m, let mu, let s, let u, let a):
                master = m
                busGain = [s, u, a, mu]
            case .music(let mc):
                music.apply(mc)
            case .reverb(let room, let damp):
                reverb.roomSize = room; reverb.damp = damp
            }
        }
    }

    /// Renders `frames` stereo samples (non-interleaved).
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        applyCommands()
        if scratchL.count < frames {
            scratchL = [Float](repeating: 0, count: frames)
            scratchR = [Float](repeating: 0, count: frames)
        }
        for i in 0..<frames { left[i] = 0; right[i] = 0; scratchL[i] = 0; scratchR[i] = 0 }

        // Music.
        music.render(frames: frames, left: left, right: right, gain: busGain[AudioBus.music.rawValue], reverbL: &scratchL, reverbR: &scratchR)

        // Voices.
        var i = 0
        while i < voices.count {
            var v = voices[i]
            var pan = v.pan
            var dist: Float = 1
            if v.spatial {
                let d = v.position - listenerPos
                let l = vlength(d)
                if l > 0.01 { pan = clampf(vdot(d / l, listenerRight), -1, 1) * min(1, l / 2.5) }
                dist = max(0.25, 1 / (1 + pow(l / 9, 2)))
            }
            let a = (pan + 1) * kPi * 0.25
            let gl = cos(a) * dist, gr = sin(a) * dist
            let bus = busGain[v.bus.rawValue]
            let samples = v.buffer.samples
            let n = samples.count
            if n == 0 { voices.remove(at: i); continue }
            var done = false
            for f in 0..<frames {
                let p = Int(v.pos)
                if p >= n - 1 {
                    if v.loop { v.pos -= Double(n - 1); continue } else { done = true; break }
                }
                let frac = Float(v.pos - Double(p))
                let s = samples[p] + (samples[p + 1] - samples[p]) * frac
                if v.gain != v.target {
                    if v.gain < v.target { v.gain = min(v.target, v.gain + v.fade) } else { v.gain = max(v.target, v.gain - v.fade) }
                }
                let x = s * v.gain * bus
                left[f] += x * gl
                right[f] += x * gr
                scratchL[f] += x * gl * v.reverbSend
                scratchR[f] += x * gr * v.reverbSend
                v.pos += v.rate
            }
            if done || (v.target == 0 && v.gain <= 0.0001) {
                voices.remove(at: i)
            } else {
                voices[i] = v
                i += 1
            }
        }

        // Reverb send and master.
        var pk: Float = 0
        for f in 0..<frames {
            let (rl, rr) = reverb.process(scratchL[f], scratchR[f])
            var l = (left[f] + rl) * master
            var r = (right[f] + rr) * master
            // Gentle limiter.
            l = l > 0.8 ? 0.8 + tanh(l - 0.8) * 0.2 : (l < -0.8 ? -0.8 + tanh(l + 0.8) * 0.2 : l)
            r = r > 0.8 ? 0.8 + tanh(r - 0.8) * 0.2 : (r < -0.8 ? -0.8 + tanh(r + 0.8) * 0.2 : r)
            left[f] = l
            right[f] = r
            pk = max(pk, abs(l), abs(r))
        }
        peak = max(pk, peak * 0.95)
    }
}
