// Visual effects director: turns gameplay events into GPU particle bursts, short-lived
// lights, decals, weapon ribbon trails, afterimages, weather and screen pulses.
import Foundation

public struct TrailSample {
    public var base: Vec3
    public var tip: Vec3
    public var time: Double
}

public struct Afterimage {
    public var mesh: MeshData
    public var materials: [MaterialDesc]
    public var palette: [Mat4]
    public var model: Mat4
    public var life: Float
    public var maxLife: Float
    public var color: Vec3
}

public struct Popup {
    public var text: String
    public var position: Vec3
    public var color: Vec4
    public var life: Float
    public var maxLife: Float
    public var size: Float
}

public final class FXSystem {
    public private(set) var spawns: [ParticleGPU] = []
    public private(set) var decals: [(DecalGPU, Float, Float)] = []       // decal, life, maxLife
    private struct TimedLight { var pos: Vec3; var color: Vec3; var intensity: Float; var radius: Float; var life: Float; var maxLife: Float }
    private var lights: [TimedLight] = []
    public private(set) var afterimages: [Afterimage] = []
    public private(set) var popups: [Popup] = []
    public var flash = Vec4.zero
    public var chromatic: Float = 0
    public var radial: Float = 0
    public var radialWorld = Vec3.zero
    public var lightning: Float = 0
    public var thunderPending = false
    private var lightningTimer: Double = 6
    private var rng = Rng(seed: 99)
    private var time: Double = 0
    public var particleScale: Float = 1
    public var flashingEnabled = true
    public var trailStyleForPlayer: (Vec3, Vec3)?
    private var weatherCarry: Float = 0

    public init() {}

    public func reset() {
        spawns.removeAll(); decals.removeAll(); lights.removeAll(); afterimages.removeAll(); popups.removeAll()
        flash = .zero; chromatic = 0; radial = 0; lightning = 0
    }

    public func takeSpawns() -> [ParticleGPU] {
        let s = spawns
        spawns.removeAll(keepingCapacity: true)
        return s
    }

    // MARK: - Emit helpers

    private func burst(_ at: Vec3, count: Int, kind: ParticleKind, color: Vec3, intensity: Float, speed: ClosedRange<Float>,
                       size: ClosedRange<Float>, life: ClosedRange<Float>, spread: Float = 1, dir: Vec3 = Vec3(0, 1, 0),
                       gravity: Float = 9, drag: Float = 1.5, growth: Float = 0, stretch: Float = 1) {
        let n = max(1, Int(Float(count) * particleScale))
        for _ in 0..<n {
            let d = vnormalize(dir * (1 - spread) + rng.unitVector() * spread + dir * 0.3)
            let v = d * rng.range(speed.lowerBound, speed.upperBound)
            let c = color * rng.range(0.7, 1.2) * intensity
            spawns.append(ParticleGPU(position: at + rng.unitVector() * 0.03, velocity: v, color: Vec4(c, 1),
                                      size: rng.range(size.lowerBound, size.upperBound), life: rng.range(life.lowerBound, life.upperBound),
                                      drag: drag, gravity: gravity, kind: kind, growth: growth, stretch: stretch, seed: rng.float()))
        }
    }

    private func light(_ p: Vec3, _ c: Vec3, _ intensity: Float, radius: Float, life: Float) {
        lights.append(TimedLight(pos: p, color: c, intensity: intensity, radius: radius, life: life, maxLife: life))
        if lights.count > 48 { lights.removeFirst() }
    }

    private func decal(_ p: Vec3, radius: Float, kind: DecalKind, color: Vec4, life: Float) {
        let d = DecalGPU(centerRadius: Vec4(p.x, 0.012, p.z, radius), params: Vec4(rng.range(0, kTwoPi), 0, Float(kind.rawValue), rng.float()), color: color)
        decals.append((d, life, life))
        if decals.count > 40 { decals.removeFirst() }
    }

    private func popup(_ text: String, _ p: Vec3, _ c: Vec4, size: Float = 30, life: Float = 0.9) {
        popups.append(Popup(text: text, position: p, color: c, life: life, maxLife: life, size: size))
    }

    static func elementColor(_ e: Element) -> Vec3 {
        switch e {
        case .fire: return Vec3(1.0, 0.42, 0.1)
        case .ice: return Vec3(0.55, 0.85, 1.0)
        case .lightning: return Vec3(0.6, 0.75, 1.0)
        case .shadow: return Vec3(0.55, 0.25, 1.0)
        case .blood: return Vec3(0.7, 0.05, 0.05)
        case .holy: return Vec3(1.0, 0.85, 0.45)
        case .water: return Vec3(0.4, 0.75, 0.9)
        case .none: return Vec3(1.0, 0.75, 0.45)
        }
    }

    // MARK: - Events

    public func process(_ events: [GameEvent], world: World) {
        for e in events {
            switch e {
            case let .hit(_, target, point, dir, weight, _, playerVictim, element, _):
                let k: Float = weight == .light ? 1 : (weight == .medium ? 1.4 : (weight == .heavy ? 2 : 2.6))
                burst(point, count: Int(16 * k), kind: .spark, color: Vec3(1, 0.62, 0.3), intensity: 6, speed: 3...9,
                      size: 0.012...0.03, life: 0.15...0.4, spread: 0.7, dir: dir, gravity: 9, drag: 2, stretch: 2)
                burst(point, count: Int(10 * k), kind: .blood, color: Vec3(0.35, 0.02, 0.02), intensity: 1, speed: 1.5...4.5,
                      size: 0.02...0.05, life: 0.3...0.7, spread: 0.6, dir: dir, gravity: 12, drag: 1)
                light(point, Vec3(1, 0.6, 0.35), 18 * k, radius: 4, life: 0.1)
                if element != .none {
                    burst(point, count: Int(18 * k), kind: .glow, color: FXSystem.elementColor(element), intensity: 4, speed: 1...3.5,
                          size: 0.05...0.12, life: 0.2...0.45, spread: 1, gravity: -1, growth: 0.3)
                }
                if weight == .heavy || weight == .huge {
                    decal(point, radius: 0.5, kind: .blood, color: Vec4(0.2, 0.01, 0.01, 0.8), life: 12)
                    radial = max(radial, playerVictim ? 0.25 : 0.35)
                    radialWorld = point
                    chromatic = max(chromatic, 0.35)
                }
                if playerVictim {
                    flash = Vec4(0.9, 0.05, 0.02, flashingEnabled ? 0.35 : 0.12)
                    chromatic = max(chromatic, 0.5)
                }
                _ = target
            case let .blocked(_, point, _):
                burst(point, count: 26, kind: .spark, color: Vec3(1, 0.7, 0.4), intensity: 6, speed: 3...8, size: 0.012...0.025,
                      life: 0.15...0.35, spread: 0.8, gravity: 9, drag: 2, stretch: 2)
                light(point, Vec3(1, 0.7, 0.4), 16, radius: 4, life: 0.08)
            case let .parried(point, perfect, telegraph, _):
                let c = perfect ? Vec3(1, 0.95, 0.8) : Vec3(1, 0.72, 0.4)
                burst(point, count: perfect ? 110 : 55, kind: .spark, color: c, intensity: perfect ? 14 : 8, speed: 4...(perfect ? 16 : 11),
                      size: 0.012...0.03, life: 0.2...0.55, spread: 1, gravity: 7, drag: 1.6, stretch: 2.5)
                burst(point, count: perfect ? 6 : 3, kind: .glow, color: c, intensity: perfect ? 30 : 12, speed: 0...0.2,
                      size: perfect ? 0.5...0.9 : 0.3...0.5, life: 0.08...0.14, spread: 1, gravity: 0, growth: 3)
                light(point, c, perfect ? 90 : 35, radius: perfect ? 8 : 5, life: perfect ? 0.14 : 0.1)
                if perfect {
                    popup("PERFECT", point + Vec3(0, 0.4, 0), UIColors.gold, size: 34)
                    if flashingEnabled { flash = Vec4(1, 0.96, 0.9, telegraph == .gold ? 0.45 : 0.28) }
                    chromatic = max(chromatic, 0.9)
                    radial = max(radial, 0.55)
                    radialWorld = point
                    if telegraph == .gold { popup("PUNISH!", point + Vec3(0, 0.75, 0), UIColors.gold, size: 28) }
                }
            case let .bossDeflect(point):
                burst(point, count: 40, kind: .spark, color: Vec3(1, 0.8, 0.5), intensity: 8, speed: 3...10, size: 0.012...0.025,
                      life: 0.15...0.4, spread: 1, gravity: 8, drag: 2, stretch: 2)
                light(point, Vec3(1, 0.8, 0.5), 30, radius: 5, life: 0.1)
                popup("DEFLECTED", point + Vec3(0, 0.5, 0), UIColors.dim, size: 22, life: 0.6)
            case let .dodged(perfect, position):
                if perfect {
                    popup("PERFECT DODGE", position + Vec3(0, 0.6, 0), Vec4(0.6, 0.85, 1, 1), size: 28)
                    chromatic = max(chromatic, 0.6)
                    burst(position, count: 30, kind: .glow, color: Vec3(0.5, 0.7, 1), intensity: 3, speed: 0.5...2, size: 0.04...0.09,
                          life: 0.3...0.6, spread: 1, gravity: -0.5)
                }
            case let .telegraph(_, kind, position):
                let c = UIColors.telegraph(kind).xyz
                burst(position, count: 1, kind: .glow, color: c, intensity: kind == .white ? 26 : 18, speed: 0...0.1, size: 0.55...0.65,
                      life: 0.16...0.2, spread: 0, gravity: 0, growth: 2.5)
                burst(position, count: 10, kind: .glow, color: c, intensity: 6, speed: 0.5...2, size: 0.03...0.06, life: 0.2...0.4, spread: 1, gravity: 0)
                light(position, c, kind == .white ? 30 : 24, radius: 5, life: 0.22)
            case let .postureBreak(_, position, isPlayer):
                burst(position, count: 70, kind: .glow, color: Vec3(1, 0.7, 0.2), intensity: 6, speed: 2...6, size: 0.04...0.09,
                      life: 0.3...0.7, spread: 1, gravity: 1)
                light(position, Vec3(1, 0.7, 0.3), 50, radius: 7, life: 0.25)
                popup(isPlayer ? "POSTURE BROKEN" : "POSTURE BREAK", position + Vec3(0, 0.8, 0), isPlayer ? UIColors.accent : UIColors.gold, size: 32, life: 1.2)
                chromatic = max(chromatic, 0.7)
            case let .deathblow(point):
                burst(point, count: 160, kind: .spark, color: Vec3(1, 0.5, 0.25), intensity: 10, speed: 3...14, size: 0.015...0.035,
                      life: 0.3...0.8, spread: 1, gravity: 8, drag: 1.2, stretch: 2.5)
                burst(point, count: 60, kind: .blood, color: Vec3(0.4, 0.02, 0.02), intensity: 1, speed: 2...7, size: 0.03...0.07,
                      life: 0.5...1.0, spread: 0.8, gravity: 12, drag: 0.8)
                light(point, Vec3(1, 0.3, 0.2), 120, radius: 9, life: 0.35)
                decal(point, radius: 1.3, kind: .blood, color: Vec4(0.25, 0.01, 0.01, 0.9), life: 30)
                if flashingEnabled { flash = Vec4(1, 0.2, 0.1, 0.4) }
                chromatic = 1; radial = 0.8; radialWorld = point
                popup("DEATHBLOW", point + Vec3(0, 0.9, 0), UIColors.accent, size: 44, life: 1.4)
            case let .burst(position, radius, element):
                let c = FXSystem.elementColor(element)
                let isNone = element == .none
                burst(position + Vec3(0, 0.1, 0), count: Int(40 * radius), kind: isNone ? .smoke : .glow, color: isNone ? Vec3(0.5, 0.45, 0.4) : c,
                      intensity: isNone ? 0.8 : 5, speed: 1...(3 * radius), size: isNone ? 0.25...0.5 : 0.06...0.14, life: 0.3...0.9, spread: 0.9,
                      dir: Vec3(0, 1, 0), gravity: isNone ? -0.2 : -1, drag: 2.5, growth: isNone ? 1.5 : 0.5)
                burst(position + Vec3(0, 0.1, 0), count: Int(30 * radius), kind: element == .ice ? .shard : .spark, color: c, intensity: element == .ice ? 1.2 : 6,
                      speed: 2...(5 * radius), size: element == .ice ? 0.04...0.09 : 0.012...0.03, life: 0.3...0.7, spread: 0.8, gravity: 9, drag: 1.2, stretch: 2)
                light(position + Vec3(0, 0.6, 0), isNone ? Vec3(1, 0.7, 0.4) : c, 45 * radius, radius: radius * 3.5, life: 0.3)
                let dk: DecalKind = element == .fire || element == .lightning ? .scorch : (element == .ice ? .frost : .crack)
                decal(position, radius: radius * 0.9, kind: dk, color: Vec4(c * (element == .fire ? 3 : 1), 1), life: 14)
            case let .crack(from, to, element):
                let n = 8
                for k in 0...n {
                    let p = vlerp(from, to, Float(k) / Float(n))
                    decal(p, radius: 0.75, kind: .crack, color: Vec4(FXSystem.elementColor(element) * 2.5, 1), life: 10)
                    burst(p, count: 8, kind: .smoke, color: Vec3(0.45, 0.4, 0.36), intensity: 0.8, speed: 0.5...2, size: 0.2...0.4,
                          life: 0.5...1.0, spread: 0.7, gravity: -0.3, drag: 2, growth: 1.2)
                }
            case let .landing(position, weight):
                burst(position + Vec3(0, 0.05, 0), count: Int(30 * weight), kind: .smoke, color: Vec3(0.5, 0.45, 0.4), intensity: 0.7,
                      speed: 1...3, size: 0.2...0.4, life: 0.5...1.0, spread: 0.2, dir: Vec3(0, 0.3, 0), gravity: -0.2, drag: 3, growth: 1.5)
                decal(position, radius: 1.0 * weight, kind: .crack, color: Vec4(1, 0.7, 0.4, 0.8), life: 10)
            case let .heal(position):
                burst(position, count: 40, kind: .glow, color: Vec3(0.9, 0.8, 0.4), intensity: 3, speed: 0.3...1.2, size: 0.04...0.08,
                      life: 0.6...1.2, spread: 1, gravity: -1.5)
                light(position, Vec3(1, 0.85, 0.5), 20, radius: 4, life: 0.6)
            case let .ability(weapon, position):
                if weapon.hasPrefix("charge") {
                    burst(position, count: 20, kind: .glow, color: Vec3(1, 0.7, 0.3), intensity: 4, speed: 0.5...2, size: 0.04...0.08, life: 0.3...0.5, spread: 1, gravity: -1)
                } else {
                    let c = world.player.weapon.trail.last.map { parseColor($0) } ?? Vec3(1, 1, 1)
                    burst(position, count: 50, kind: .glow, color: c, intensity: 5, speed: 1...3, size: 0.05...0.1, life: 0.3...0.6, spread: 1, gravity: -0.5)
                    light(position, c, 40, radius: 6, life: 0.3)
                }
            case let .counter(position):
                light(position, Vec3(0.7, 0.85, 1), 60, radius: 6, life: 0.2)
                popup("COUNTER", position + Vec3(0, 0.7, 0), Vec4(0.7, 0.85, 1, 1), size: 30)
                chromatic = max(chromatic, 0.8)
            case let .chainHit(position):
                burst(position, count: 30, kind: .spark, color: Vec3(0.8, 0.6, 1), intensity: 6, speed: 2...6, size: 0.012...0.025, life: 0.2...0.4, spread: 1, stretch: 2)
            case let .bleed(position):
                burst(position, count: 8, kind: .blood, color: Vec3(0.5, 0.02, 0.03), intensity: 1.2, speed: 0.5...2, size: 0.02...0.04, life: 0.4...0.8, spread: 1, gravity: 10)
            case let .grab(position):
                light(position, Vec3(1, 0.2, 0.1), 30, radius: 4, life: 0.3)
                if flashingEnabled { flash = Vec4(0.8, 0.05, 0.02, 0.3) }
            case let .disarm(position):
                popup("DISARMED", position + Vec3(0, 0.8, 0), Vec4(0.8, 0.6, 1, 1), size: 28)
            case let .phaseStart(fid, _, _, _):
                if let b = world.bosses.first(where: { $0.fighter.id == fid }) {
                    let c = b.fighter.elementGlow != .none ? FXSystem.elementColor(b.fighter.elementGlow) : Vec3(1, 0.4, 0.2)
                    burst(b.fighter.center, count: 120, kind: .glow, color: c, intensity: 5, speed: 2...7, size: 0.05...0.12, life: 0.5...1.2, spread: 1, gravity: -1)
                    light(b.fighter.center, c, 90, radius: 10, life: 0.6)
                    decal(b.fighter.position, radius: 2.4, kind: .glyph, color: Vec4(c * 3, 1), life: 8)
                    chromatic = 1
                }
            case let .afterimage(fid):
                if fid == world.player.fighter.id {
                    let f = world.player.fighter
                    afterimages.append(Afterimage(mesh: f.mesh, materials: f.materials, palette: f.animator.skinPalette(),
                                                  model: f.animator.worldMatrix, life: 0.55, maxLife: 0.55, color: Vec3(0.4, 0.7, 1)))
                }
            case let .death(_, position, isPlayer):
                burst(position, count: isPlayer ? 40 : 120, kind: .glow, color: isPlayer ? Vec3(0.8, 0.1, 0.05) : Vec3(1, 0.7, 0.4),
                      intensity: 3, speed: 0.5...3, size: 0.05...0.1, life: 0.8...1.6, spread: 1, gravity: -0.8)
            default:
                break
            }
        }
    }

    // MARK: - Per-frame update

    public func update(dt: Float, world: World?, arena: BuiltArena?, cameraPos: Vec3, timeScale: Float) {
        time += Double(dt)
        let gdt = dt * max(0.05, timeScale)
        for i in lights.indices { lights[i].life -= gdt }
        lights.removeAll { $0.life <= 0 }
        for i in decals.indices { decals[i].1 -= dt }
        decals.removeAll { $0.1 <= 0 }
        for i in afterimages.indices { afterimages[i].life -= dt }
        afterimages.removeAll { $0.life <= 0 }
        for i in popups.indices { popups[i].life -= dt; popups[i].position.y += dt * 0.4 }
        popups.removeAll { $0.life <= 0 }
        flash.w = max(0, flash.w - dt * 2.2)
        chromatic = max(0, chromatic - dt * 2.5)
        radial = max(0, radial - dt * 2.2)
        lightning = max(0, lightning - dt * 3)

        guard let arena = arena else { return }
        emitWeather(arena.def, cameraPos: cameraPos, dt: dt)
        for e in arena.emitters { emitEmitter(e, dt: dt) }
        if arena.def.lightning {
            lightningTimer -= Double(dt)
            if lightningTimer <= 0 {
                lightning = 1
                thunderPending = true
                lightningTimer = Double(rng.range(5, 14))
            }
        }
        if let w = world { continuousEffects(world: w, dt: gdt) }
    }

    private func continuousEffects(world: World, dt: Float) {
        // Telegraph glow particles along red/purple weapons while winding up.
        for b in world.bosses where b.telegraphIntensity > 0.3 && (b.telegraph == .red || b.telegraph == .purple) {
            if rng.chance(min(1, dt * 60)) {
                let w = b.fighter.weapon
                let p = vlerp(w.trailBaseWorld, w.trailTipWorld, rng.float())
                let c = UIColors.telegraph(b.telegraph).xyz
                spawns.append(ParticleGPU(position: p, velocity: Vec3(0, 0.6, 0) + rng.unitVector() * 0.3, color: Vec4(c * 5, 1), size: 0.05,
                                          life: 0.35, drag: 1, gravity: -1, kind: .glow))
            }
        }
        // Elemental weapons shed particles.
        for f in world.bosses.map({ $0.fighter }) + [world.player.fighter] where !f.dead {
            let w = f.weapon
            guard w.visual.element != .none, w.glow > 0.05 else { continue }
            if rng.chance(min(1, dt * 40 * w.glow)) {
                let p = vlerp(w.trailBaseWorld, w.trailTipWorld, rng.float())
                let c = FXSystem.elementColor(w.visual.element)
                let kind: ParticleKind = w.visual.element == .fire ? .ember : .glow
                spawns.append(ParticleGPU(position: p, velocity: Vec3(0, 0.8, 0) + rng.unitVector() * 0.2, color: Vec4(c * 4, 1),
                                          size: 0.025, life: 0.6, drag: 1, gravity: -1.5, kind: kind))
            }
        }
    }

    private func emitWeather(_ d: ArenaDef, cameraPos: Vec3, dt: Float) {
        let rate: Float
        switch d.weather {
        case "rain": rate = 900
        case "snow": rate = 160
        case "ash": rate = 90
        case "embers": rate = 70
        case "leaves", "petals": rate = 20
        case "dust": rate = 30
        case "spores": rate = 25
        case "sparks": rate = 35
        default: rate = 0
        }
        guard rate > 0 else { return }
        weatherCarry += rate * d.weatherIntensity * particleScale * dt
        let n = Int(weatherCarry)
        weatherCarry -= Float(n)
        let center = Vec3(cameraPos.x, 0, cameraPos.z)
        for _ in 0..<n {
            let off = Vec3(rng.range(-16, 16), 0, rng.range(-16, 16))
            switch d.weather {
            case "rain":
                spawns.append(ParticleGPU(position: center + off + Vec3(0, rng.range(8, 14), 0), velocity: Vec3(-1.5, -16, -0.5),
                                          color: Vec4(0.6, 0.65, 0.75, 0.35), size: 0.012, life: 1.0, drag: 0, gravity: 0, kind: .rain, stretch: 0.06))
            case "snow":
                spawns.append(ParticleGPU(position: center + off + Vec3(0, rng.range(6, 12), 0), velocity: Vec3(rng.range(-0.4, 0.4), -1.1, rng.range(-0.4, 0.4)),
                                          color: Vec4(0.95, 0.97, 1, 0.9), size: rng.range(0.02, 0.045), life: 9, drag: 0.5, gravity: 0.15, kind: .snow, seed: rng.float()))
            case "ash":
                spawns.append(ParticleGPU(position: center + off + Vec3(0, rng.range(4, 10), 0), velocity: Vec3(rng.range(-0.3, 0.3), -0.5, rng.range(-0.3, 0.3)),
                                          color: Vec4(0.25, 0.23, 0.22, 0.8), size: rng.range(0.02, 0.04), life: 10, drag: 0.6, gravity: 0.1, kind: .snow, seed: rng.float()))
            case "embers", "sparks":
                let c = d.weather == "embers" ? Vec3(1, 0.4, 0.1) * 5 : Vec3(1, 0.8, 0.4) * 5
                spawns.append(ParticleGPU(position: center + off + Vec3(0, rng.range(0, 2), 0), velocity: Vec3(rng.range(-0.3, 0.3), rng.range(0.6, 1.6), rng.range(-0.3, 0.3)),
                                          color: Vec4(c, 1), size: rng.range(0.012, 0.025), life: rng.range(3, 6), drag: 0.3, gravity: -0.2, kind: .ember, seed: rng.float()))
            case "petals", "leaves":
                let c = d.weather == "petals" ? Vec3(0.9, 0.35, 0.4) : Vec3(0.55, 0.35, 0.12)
                spawns.append(ParticleGPU(position: center + off + Vec3(0, rng.range(5, 10), 0), velocity: Vec3(rng.range(0.3, 0.9), -0.7, rng.range(-0.3, 0.3)),
                                          color: Vec4(c, 1), size: rng.range(0.035, 0.06), life: 11, drag: 0.7, gravity: 0.25, kind: .petal, seed: rng.float()))
            case "dust":
                spawns.append(ParticleGPU(position: center + off + Vec3(0, rng.range(0.2, 3), 0), velocity: Vec3(rng.range(-0.2, 0.2), rng.range(-0.05, 0.1), rng.range(-0.2, 0.2)),
                                          color: Vec4(1, 0.9, 0.7, 0.35), size: rng.range(0.01, 0.02), life: 6, drag: 0.2, gravity: 0, kind: .glow, seed: rng.float()))
            default: // spores
                spawns.append(ParticleGPU(position: center + off + Vec3(0, rng.range(0.2, 4), 0), velocity: Vec3(rng.range(-0.1, 0.1), rng.range(0.05, 0.25), rng.range(-0.1, 0.1)),
                                          color: Vec4(0.6, 0.35, 1, 1) * 2.5, size: rng.range(0.012, 0.03), life: 7, drag: 0.2, gravity: 0, kind: .ember, seed: rng.float()))
            }
        }
    }

    private func emitEmitter(_ e: EmitterDesc, dt: Float) {
        let n = Int(e.rate * dt * particleScale + rng.float())
        for _ in 0..<n {
            if e.kind == "runes" {
                spawns.append(ParticleGPU(position: e.position + Vec3(rng.range(-0.4, 0.4), rng.range(-1, 1), rng.range(-0.4, 0.4)),
                                          velocity: Vec3(0, rng.range(0.2, 0.6), 0), color: Vec4(0.6, 0.3, 1, 1) * 3, size: rng.range(0.02, 0.05),
                                          life: 1.5, drag: 0.5, gravity: 0, kind: .glow))
                continue
            }
            let flame = Vec3(1, rng.range(0.35, 0.6), 0.12) * rng.range(4, 8)
            spawns.append(ParticleGPU(position: e.position + Vec3(rng.range(-0.15, 0.15), 0, rng.range(-0.15, 0.15)) * e.scale,
                                      velocity: Vec3(rng.range(-0.2, 0.2), rng.range(0.8, 1.6), rng.range(-0.2, 0.2)) * e.scale,
                                      color: Vec4(flame, 1), size: rng.range(0.1, 0.2) * e.scale, life: rng.range(0.35, 0.6), drag: 1.2,
                                      gravity: -2, kind: .glow, growth: -0.25))
            if rng.chance(0.15) {
                spawns.append(ParticleGPU(position: e.position + Vec3(0, 0.3, 0) * e.scale, velocity: Vec3(rng.range(-0.3, 0.3), rng.range(1, 2.5), rng.range(-0.3, 0.3)),
                                          color: Vec4(1, 0.45, 0.1, 1) * 6, size: 0.015, life: rng.range(1, 2), drag: 0.4, gravity: -0.4, kind: .ember))
            }
            if rng.chance(0.1) {
                spawns.append(ParticleGPU(position: e.position + Vec3(0, 0.6, 0) * e.scale, velocity: Vec3(0, rng.range(0.6, 1.0), 0),
                                          color: Vec4(0.18, 0.16, 0.15, 0.4), size: 0.25 * e.scale, life: 2.5, drag: 0.5, gravity: -0.2, kind: .smoke, growth: 0.6))
            }
        }
    }

    // MARK: - Outputs

    public func lightList(arena: BuiltArena?, world: World?) -> [PointLightGPU] {
        var out: [PointLightGPU] = []
        if let a = arena {
            for l in a.lights {
                let fl = 1 + (Noise.simplex2(Float(time) * 7, l.position.x * 3) * 0.5) * l.flicker
                out.append(PointLightGPU(position: l.position, radius: l.radius, color: l.color, intensity: l.intensity * fl))
            }
        }
        for l in lights {
            let k = l.life / l.maxLife
            out.append(PointLightGPU(position: l.pos, radius: l.radius, color: l.color, intensity: l.intensity * k * k))
        }
        if let w = world {
            // Glowing weapons emit light.
            for f in [w.player.fighter] + w.bosses.map({ $0.fighter }) where !f.dead && f.weapon.glow > 0.2 {
                let c = parseColor(f.weapon.visual.glow)
                out.append(PointLightGPU(position: vlerp(f.weapon.trailBaseWorld, f.weapon.trailTipWorld, 0.6), radius: 3.5,
                                         color: c, intensity: 4 * f.weapon.glow))
            }
            for b in w.bosses where b.telegraphIntensity > 0.2 {
                let c = UIColors.telegraph(b.telegraph).xyz
                out.append(PointLightGPU(position: b.fighter.weapon.trailTipWorld, radius: 3, color: c, intensity: 10 * b.telegraphIntensity))
            }
        }
        if out.count > 64 { out = Array(out.prefix(64)) }
        return out
    }

    public func decalList() -> [DecalGPU] {
        decals.map { d, life, maxLife in
            var g = d
            g.params.y = 1 - life / maxLife
            return g
        }
    }
}

/// Builds ribbon trail geometry from weapon samples recorded at the simulation rate.
public final class TrailBuilder {
    public struct Style { public var head: Vec3; public var tail: Vec3; public var intensity: Float }
    private var history: [ObjectIdentifier: [TrailSample]] = [:]
    public var lifetime: Double = 0.16

    public init() {}

    public func record(_ weapon: WeaponInstance, emitting: Bool, time: Double) {
        let key = ObjectIdentifier(weapon)
        var h = history[key] ?? []
        if emitting {
            h.append(TrailSample(base: weapon.trailBaseWorld, tip: weapon.trailTipWorld, time: time))
        }
        h.removeAll { time - $0.time > lifetime }
        if h.isEmpty { history.removeValue(forKey: key) } else { history[key] = h }
    }

    public func clear() { history.removeAll() }

    public func build(time: Double, styleFor: (ObjectIdentifier) -> Style?, vertices: inout [TrailVertexGPU], indices: inout [UInt32]) {
        for (key, h) in history where h.count >= 2 {
            guard let style = styleFor(key) else { continue }
            // Catmull-Rom subdivision for smooth arcs.
            var pts: [TrailSample] = []
            for i in 0..<(h.count - 1) {
                let p0 = h[max(0, i - 1)], p1 = h[i], p2 = h[i + 1], p3 = h[min(h.count - 1, i + 2)]
                let sub = 4
                for s in 0..<sub {
                    let t = Float(s) / Float(sub)
                    func cr(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) -> Vec3 {
                        let t2: Float = t * t
                        let t3: Float = t2 * t
                        let k0: Vec3 = b * 2
                        let k1: Vec3 = (c - a) * t
                        let k2a: Vec3 = a * 2 - b * 5
                        let k2: Vec3 = (k2a + c * 4 - d) * t2
                        let k3a: Vec3 = b * 3 - a
                        let k3: Vec3 = (k3a - c * 3 + d) * t3
                        return (k0 + k1 + k2 + k3) * 0.5
                    }
                    pts.append(TrailSample(base: cr(p0.base, p1.base, p2.base, p3.base), tip: cr(p0.tip, p1.tip, p2.tip, p3.tip),
                                           time: p1.time + (p2.time - p1.time) * Double(t)))
                }
            }
            pts.append(h[h.count - 1])
            let base = UInt32(vertices.count)
            let n = pts.count
            for (i, p) in pts.enumerated() {
                let age = Float((time - p.time) / lifetime)
                let u = saturatef(age)
                let fade = (1 - u) * (1 - u)
                let col = vlerp(style.head, style.tail, u) * style.intensity
                // Inner edge fades to transparent, tip is brightest.
                vertices.append(TrailVertexGPU(position: Vec4(vlerp(p.base, p.tip, 0.35), u), color: Vec4(col, 0)))
                vertices.append(TrailVertexGPU(position: Vec4(p.tip, u), color: Vec4(col, fade)))
                if i < n - 1 {
                    let a = base + UInt32(i * 2)
                    indices += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
                }
            }
        }
    }
}
