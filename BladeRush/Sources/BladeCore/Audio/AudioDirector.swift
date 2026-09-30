// Game-thread audio logic: gameplay events -> sounds (spatial), telegraph cues, footsteps,
// ambience beds per arena and adaptive music state.
import Foundation

public final class AudioDirector {
    public let bank = SoundBank()
    public let mixer = AudioMixer()
    private var rng = Rng(seed: 404)
    private var ambience: [String: Int] = [:]
    private var footsteps: [Int: Int] = [:]
    private var arenaId = ""
    public var footstepMaterial = "stone"
    public private(set) var ready = false

    public init() {}

    public func load() {
        timed("synthesize sound bank", "audio") { bank.generate() }
        ready = true
    }

    /// Synthesizes the sound bank on a background queue; `ready` flips on the main queue
    /// (the dispatch hop publishes the finished bank to the game thread).
    public func loadInBackground(_ done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            timed("synthesize sound bank", "audio") { self.bank.generate() }
            DispatchQueue.main.async {
                self.ready = true
                done()
            }
        }
    }

    @discardableResult
    public func play(_ name: String, gain: Float = 1, pitch: Float = 1, at pos: Vec3? = nil, bus: AudioBus = .sfx, pitchJitter: Float = 0.04,
                     reverb: Float = 0.25) -> Int {
        guard ready, let v = rng.pick(bank.variants(name)) else { return 0 }
        let p = pitch * (1 + rng.range(-pitchJitter, pitchJitter))
        return mixer.play(v, gain: gain, pitch: p, at: pos, bus: bus, reverb: reverb)
    }

    public func ui(_ name: String) { play(name, gain: 0.8, bus: .ui, pitchJitter: 0, reverb: 0.05) }

    public func setVolumes(_ s: Settings) {
        mixer.setVolumes(master: s.masterVolume, music: s.musicVolume, sfx: s.sfxVolume, ui: s.uiVolume, ambience: s.sfxVolume * 0.8)
    }

    // MARK: Arena / menu

    public func enterMenu() {
        stopAmbience()
        arenaId = ""
        var st = MusicStyle()
        st.tempo = 70; st.root = 45; st.mode = "aeolian"; st.pad = "choir"; st.lead = "bell"; st.drums = "sparse"
        mixer.musicCommand(.style(st))
        mixer.musicCommand(.menu(true))
        mixer.musicCommand(.phase(1))
        mixer.musicCommand(.intensity(0.1))
        mixer.setReverb(room: 0.86, damp: 0.35)
        startLoop("amb_wind", gain: 0.25)
    }

    public func enterArena(_ a: ArenaDef) {
        stopAmbience()
        arenaId = a.id
        footstepMaterial = a.footstep
        mixer.musicCommand(.style(a.music))
        mixer.musicCommand(.menu(false))
        mixer.musicCommand(.phase(1))
        mixer.musicCommand(.intensity(0.25))
        let enclosed = a.backdrop == "cave" || a.backdrop == "forge" || a.backdrop == "walls" || a.backdrop == "city"
        mixer.setReverb(room: enclosed ? 0.9 : 0.8, damp: enclosed ? 0.25 : 0.4)
        startLoop("amb_wind", gain: a.backdrop == "cave" || a.backdrop == "forge" ? 0.12 : 0.35)
        if a.weather == "rain" { startLoop("amb_rain", gain: 0.5 * a.weatherIntensity) }
        if a.props.contains(where: { ["brazier", "forge", "torch", "lantern"].contains($0.kind) }) || a.weather == "embers" { startLoop("amb_fire", gain: 0.3) }
        if a.backdrop == "sea" { startLoop("amb_sea", gain: 0.45) }
        if a.sky == "underground" || a.sky == "void" || a.sky == "eclipse" { startLoop("amb_hum", gain: 0.35) }
    }

    private func startLoop(_ name: String, gain: Float) {
        guard ready, let b = bank.variants(name).first else { return }
        ambience[name] = mixer.play(b, gain: gain, bus: .ambience, loop: true, fadeIn: 1.5, reverb: 0.1)
    }

    public func stopAmbience() {
        for (_, id) in ambience { mixer.stop(id, fade: 1.0) }
        ambience.removeAll()
    }

    // MARK: Per-frame

    public func update(world: World?, cameraPos: Vec3, cameraForward: Vec3, fx: FXSystem) {
        let fwd = vnormalize(vflat(cameraForward), fallback: Vec3(0, 0, 1))
        mixer.setListener(position: cameraPos, forward: fwd, right: Vec3(-fwd.z, 0, fwd.x))
        if fx.thunderPending {
            fx.thunderPending = false
            play("thunder", gain: 0.9, bus: .ambience, reverb: 0.4)
        }
        guard let w = world else { return }
        // Footsteps.
        for f in [w.player.fighter] + w.bosses.map({ $0.fighter }) {
            let c = f.animator.footstepCount
            if let prev = footsteps[f.id], c > prev {
                let big = f.height > 2.3
                play("step_\(footstepMaterial)", gain: big ? 0.9 : (f.isPlayer ? 0.35 : 0.5), pitch: big ? 0.6 : 1, at: f.animator.lastFootstep)
                if big && c % 2 == 0 { play("hit_blunt", gain: 0.25, pitch: 0.5, at: f.animator.lastFootstep) }
            }
            footsteps[f.id] = c
        }
        // Music intensity follows the fight.
        var intensity: Float = 0.35
        if let b = w.aliveBosses.first {
            let d = vlength(vflat(b.fighter.position - w.player.fighter.position))
            if d < 6 { intensity += 0.2 }
            if b.state == .attacking { intensity += 0.15 }
            intensity += 0.15 * Float(b.phase - 1)
            intensity += 0.15 * (1 - w.player.fighter.healthFraction)
        }
        switch w.fightPhase {
        case .intro: intensity = 0.3
        case .victory: intensity = 0.15
        case .defeat: intensity = 0.05
        case .fighting: break
        }
        mixer.musicCommand(.intensity(min(1, intensity)))
    }

    public func handle(_ events: [GameEvent], world: World) {
        for e in events {
            switch e {
            case let .hit(_, _, point, _, weight, _, playerVictim, element, sound):
                switch weight {
                case .light: play(sound == .blunt ? "hit_blunt" : "hit_flesh", gain: 0.8, at: point)
                case .medium: play(sound == .blunt ? "hit_blunt" : "hit_flesh", gain: 1.0, at: point)
                case .heavy, .huge: play("hit_heavy", gain: 1.0, at: point); play("clash", gain: 0.4, pitch: 0.7, at: point)
                }
                if playerVictim { play("hit_heavy", gain: 0.5, pitch: 1.2, at: point) }
                if element != .none { playElement(element, at: point, gain: 0.6) }
            case let .blocked(_, point, _):
                play("block", gain: 1, at: point)
            case let .parried(point, perfect, _, _):
                if perfect { play("parry_perfect", gain: 1, at: point, reverb: 0.45) } else { play("parry", gain: 0.9, at: point, reverb: 0.35) }
                play("clash", gain: perfect ? 0.6 : 0.5, at: point)
            case let .bossDeflect(point):
                play("parry", gain: 0.7, pitch: 0.85, at: point)
            case let .dodged(perfect, position):
                if perfect { play("slowmo", gain: 0.8, at: position) }
            case let .whoosh(_, position, sound, weight, speed):
                let name: String
                switch sound {
                case .chain: name = "whoosh_chain"
                case .heavyBlade, .blunt: name = weight > 0.6 ? "whoosh_heavy" : "whoosh_med"
                case .dagger, .fan: name = "whoosh_fast"
                default: name = weight > 0.5 ? "whoosh_med" : "whoosh_fast"
                }
                play(name, gain: 0.7, pitch: 0.9 + 0.2 * min(speed, 1.5), at: position)
            case let .telegraph(_, kind, position):
                switch kind {
                case .white, .none: play("tele_white", gain: 0.8, at: position, pitchJitter: 0)
                case .red: play("tele_red", gain: 0.9, at: position, pitchJitter: 0)
                case .purple: play("tele_purple", gain: 0.85, at: position, pitchJitter: 0)
                case .gold: play("tele_gold", gain: 0.8, at: position, pitchJitter: 0)
                }
            case let .postureBreak(_, position, _):
                play("posture_break", gain: 1, at: position, reverb: 0.5)
            case let .deathblow(point):
                play("deathblow", gain: 1, at: point, reverb: 0.5)
                mixer.musicCommand(.drop(1.3))
            case let .phaseStart(_, phase, _, _):
                play("roar", gain: 0.9, reverb: 0.5)
                mixer.musicCommand(.phase(phase))
                mixer.musicCommand(.drop(0.6))
            case let .death(_, position, isPlayer):
                play(isPlayer ? "player_death" : "boss_death", gain: 1, at: position, reverb: 0.6)
                mixer.musicCommand(.stinger(isPlayer ? 1 : 0))
            case let .heal(position): play("heal", gain: 0.8, at: position)
            case .healEmpty: play("ui_back", gain: 0.6, bus: .ui)
            case let .burst(position, _, element): playElement(element, at: position, gain: 1)
            case let .crack(from, _, _): play("burst_earth", gain: 1, at: from)
            case let .landing(position, _): play("burst_earth", gain: 0.7, at: position)
            case let .ability(weapon, position):
                play(weapon.hasPrefix("charge") ? "swap" : "ability", gain: 0.8, pitch: weapon.hasPrefix("charge") ? 1.3 : 1, at: position)
            case .swap: play("swap", gain: 0.7)
            case let .chainHit(position): play("whoosh_chain", gain: 0.8, at: position); play("clash", gain: 0.5, pitch: 1.4, at: position)
            case let .grab(position): play("grab", gain: 1, at: position)
            case let .counter(position): play("counter", gain: 1, at: position)
            case let .disarm(position): play("clash", gain: 0.8, pitch: 0.6, at: position)
            case .victory: break
            default: break
            }
        }
    }

    private func playElement(_ e: Element, at p: Vec3, gain: Float) {
        switch e {
        case .fire: play("burst_fire", gain: gain, at: p)
        case .ice: play("burst_ice", gain: gain, at: p)
        case .lightning: play("burst_lightning", gain: gain, at: p)
        case .shadow: play("burst_shadow", gain: gain, at: p)
        case .holy: play("burst_holy", gain: gain, at: p)
        case .water: play("burst_earth", gain: gain * 0.6, pitch: 1.5, at: p)
        default: play("burst_earth", gain: gain, at: p)
        }
    }
}
