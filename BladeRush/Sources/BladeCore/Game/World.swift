// A single fight: player, one or more bosses, the arena, the combat clock and all
// hit resolution. Simulation runs at a fixed 240 Hz so parry/dodge timing is resolved
// with ~4 ms precision regardless of frame rate; input events carry timestamps and are
// applied at the matching simulation step.
import Foundation

public struct TimedInput {
    public var action: PlayerAction
    public var pressed: Bool
    /// Seconds since the start of this frame (0 ... frame duration).
    public var offset: Double
    public init(action: PlayerAction, pressed: Bool, offset: Double) { self.action = action; self.pressed = pressed; self.offset = offset }
}

public enum FightPhase: Equatable { case intro, fighting, victory, defeat }

public final class World: CombatContext {
    public static let simRate: Double = 240
    public let data: GameDataStore
    public let arena: BuiltArena
    public let player: PlayerController
    public private(set) var bosses: [BossController] = []
    public let encounter: EncounterDef
    public let camera = GameCamera()
    public private(set) var events: [GameEvent] = []
    public private(set) var fightPhase: FightPhase = .intro
    public private(set) var phaseTime: Double = 0
    public private(set) var now: Double = 0
    public private(set) var realTime: Double = 0
    public private(set) var hitstopRemaining: Double = 0
    private var accumulator: Double = 0
    private var slowUntil: Double = 0
    private var slowScale: Double = 1
    public var debugTimeScale: Double = 1
    public var radialOpen = false
    public private(set) var hazards: [Hazard] = []
    public var hardMode: Bool
    public var timingAssist: Double = 1
    public private(set) var windows: DefenseWindows
    public let director: GauntletDirector?
    public var lighting: String = ""
    public private(set) var lightingBlend: Float = 0
    public var subtitles: [(String, String, Double)] = []
    public private(set) var stepCount = 0
    public var lastStepsPerFrame = 0
    public let trails = TrailBuilder()
    /// Recent defense results with timing, for the frame-data overlay.
    public private(set) var defenseLog: [(String, Double)] = []

    public var tuning: CombatTuning { data.tuning.tuning }
    public var lib: AnimLibrary { data.anims }

    public init(data: GameDataStore, encounter: EncounterDef, playerWeapons: [PlayerWeaponDef], startWeapon: Int, playerVisual: CharacterVisual,
                hardMode: Bool, timingAssist: Double, quality: Float, flasks: Int? = nil) {
        self.data = data
        self.encounter = encounter
        self.hardMode = hardMode
        self.timingAssist = timingAssist
        let arenaId = encounter.arena.isEmpty ? (data.bosses[encounter.bosses.first ?? ""]?.arena ?? "") : encounter.arena
        let arenaDef = data.arenas[arenaId] ?? data.arenas.values.first ?? ArenaDef()
        arena = timed("arena \(arenaDef.id)", "load") { ContentCache.arena(arenaDef, quality: quality) }
        let t = data.tuning.tuning
        windows = DefenseWindows.from(t.timing, assist: timingAssist, hardModeMult: hardMode ? t.hardMode.windowMult : 1)
        let pf = Fighter(isPlayer: true, name: "The Blade", visual: playerVisual, weapons: playerWeapons.map { $0.visual },
                         maxHealth: t.player.maxHealth, maxPosture: t.player.maxPosture, radius: t.player.radius, lib: data.anims, quality: quality)
        player = PlayerController(fighter: pf, weapons: playerWeapons, startWeapon: startWeapon, tuning: t.player, timing: t.timing)
        if let f = flasks { player.flasks = f }
        director = encounter.bosses.count > 1 ? GauntletDirector() : nil
        for (i, bid) in encounter.bosses.enumerated() {
            guard let def = data.bosses[bid] else { continue }
            let hpMult = t.boss.healthMult * (encounter.bosses.count > 1 ? 0.7 : 1) * (hardMode ? 1.15 : 1)
            let bf = Fighter(isPlayer: false, name: def.name, visual: def.visual, weapons: def.weapons,
                             maxHealth: def.stats.health * hpMult, maxPosture: def.stats.posture,
                             radius: def.stats.radius, lib: data.anims, quality: quality)
            bf.title = def.title
            let angle = encounter.bosses.count > 1 ? (Float(i) - 0.5) * 1.1 : 0
            let spawnR = min(arena.def.boundingRadius * 0.55, 8)
            bf.position = Vec3(sin(angle) * spawnR, 0, cos(angle) * spawnR)
            bf.yaw = kPi + angle
            bf.animator.teleport(position: bf.position, yaw: bf.yaw)
            let bc = BossController(fighter: bf, def: def, attacks: data.resolveAttacks(def), hardMode: hardMode, tuning: t)
            bc.director = director
            bosses.append(bc)
        }
        pf.position = Vec3(0, 0, -min(arena.def.boundingRadius * 0.55, 8))
        pf.yaw = 0
        pf.animator.teleport(position: pf.position, yaw: pf.yaw)
        for b in bosses {
            if let d = director {
                let id = b.fighter.id
                b.ai.mayAttack = { [unowned self] in d.request(id, now: self.now) }
                b.ai.flankAngle = b === bosses.first ? 0.8 : -0.8
            }
        }
        camera.snap(player: pf, target: bosses.first?.fighter)
        // Warm up animation so the first rendered frame is posed.
        pf.updateAnimation(dt: 0.016, running: false)
        for b in bosses { b.fighter.updateAnimation(dt: 0.016, running: false) }
        startIntro()
    }

    // MARK: - CombatContext

    public func emit(_ e: GameEvent) { events.append(e) }

    public func target(for f: Fighter) -> Fighter? {
        if f.isPlayer {
            if let l = player.lockTarget, !l.dead { return l }
            return bosses.filter { !$0.fighter.dead }.min { vlengthSq($0.fighter.position - f.position) < vlengthSq($1.fighter.position - f.position) }?.fighter
        }
        return player.fighter
    }

    public func boss(for f: Fighter) -> BossController? { bosses.first { $0.fighter === f } }

    public func slowMotion(duration: Double, scale: Double) {
        slowUntil = realTime + duration
        slowScale = scale
    }

    public func shake(_ amount: Float) { camera.addTrauma(amount) }

    public func hitstop(_ seconds: Double) { hitstopRemaining = max(hitstopRemaining, seconds) }

    public func clampToArena(_ p: Vec3, margin: Float) -> Vec3 {
        var q = arena.def.clamp(p, margin: margin + 0.3)
        // Pillars and big props block movement.
        for c in arena.colliders where c.radius > 0 {
            let d = Vec2(q.x - c.center.x, q.z - c.center.y)
            let l = vlength2(d)
            let r = c.radius + margin
            if l < r && l > 1e-4 { let k = r / l; q.x = c.center.x + d.x * k; q.z = c.center.y + d.y * k }
        }
        return q
    }

    public func spawnHazard(_ h: Hazard) { hazards.append(h) }

    // MARK: - Flow

    private func startIntro() {
        fightPhase = .intro
        phaseTime = 0
        let introDur = 2.8
        for b in bosses {
            b.beginIntro(ctx: self, duration: introDur)
            emit(.bossIntro(name: b.def.name, title: b.def.title))
            if !b.def.intro.isEmpty { emit(.subtitle(speaker: b.def.name, text: b.def.intro, duration: 3.2)) }
        }
        if let b = bosses.first?.fighter {
            let yaw = dirToYaw(b.position - player.fighter.position) + 2.4
            camera.startCinematic(focus: b.position + Vec3(0, b.height * 0.7, 0), yaw: yaw + kPi, distance: 2.6 + b.height * 0.8,
                                  height: 0.2, until: introDur - 0.4)
        }
    }

    public func skipIntro() {
        guard fightPhase == .intro else { return }
        beginFight()
    }

    private func beginFight() {
        fightPhase = .fighting
        phaseTime = 0
        for b in bosses where b.state == .intro { b.startFight(ctx: self) }
        camera.mode = .follow
        if player.lockTarget == nil { player.lockTarget = bosses.first?.fighter }
    }

    public func drainEvents() -> [GameEvent] {
        let e = events
        events.removeAll(keepingCapacity: true)
        return e
    }

    public var timeScale: Double {
        var s = debugTimeScale
        if realTime < slowUntil { s *= slowScale }
        if radialOpen { s *= 0.15 }
        if fightPhase == .victory { s *= phaseTime < 1.2 ? 0.35 : 1 }
        return s
    }

    public var aliveBosses: [BossController] { bosses.filter { !$0.fighter.dead } }

    public func toggleLockOn() {
        if player.lockTarget != nil {
            // Cycle between bosses in gauntlets, otherwise release.
            let alive = aliveBosses.map { $0.fighter }
            if alive.count > 1, let cur = player.lockTarget, let idx = alive.firstIndex(where: { $0 === cur }) {
                player.lockTarget = alive[(idx + 1) % alive.count]
            } else {
                player.lockTarget = nil
            }
        } else {
            player.lockTarget = target(for: player.fighter)
        }
    }

    // MARK: - Update

    /// Advances the world by one rendered frame.
    public func update(realDt rdt: Double, inputs: [TimedInput], moveInput: Vec2, look: Vec2, freeMove: Vec3 = .zero) {
        let realDt = min(rdt, 0.1)
        realTime += realDt
        phaseTime += realDt
        windows = DefenseWindows.from(tuning.timing, assist: timingAssist, hardModeMult: hardMode ? tuning.hardMode.windowMult : 1)
        player.moveInput = moveInput
        player.cameraYaw = camera.forwardFlat == .zero ? camera.yaw : dirToYaw(camera.forwardFlat)
        for i in inputs where i.pressed { for b in bosses { b.ai.habits.observe(i.action) } }

        if fightPhase == .intro {
            if phaseTime > 2.8 || inputs.contains(where: { $0.pressed && $0.action == .light }) { beginFight() }
        }

        var steps = 0
        if hitstopRemaining > 0 {
            hitstopRemaining -= realDt
            // Inputs during hitstop still register (buffered) at the frozen time.
            for i in inputs { deliver(i) }
        } else {
            let scale = timeScale
            accumulator += realDt * scale
            let stepDt = 1 / World.simRate
            let n = min(Int(accumulator / stepDt), 48)
            accumulator -= Double(n) * stepDt
            if n == 0 { for i in inputs { deliver(i) } }
            var pending = inputs.sorted { $0.offset < $1.offset }
            for s in 0..<n {
                let stepEndOffset = realDt * Double(s + 1) / Double(n)
                while let first = pending.first, first.offset <= stepEndOffset || s == n - 1 {
                    deliver(first)
                    pending.removeFirst()
                }
                simStep(stepDt)
                steps += 1
                if hitstopRemaining > 0 {
                    // Remaining inputs are delivered immediately; the rest of the frame is frozen.
                    for i in pending { deliver(i) }
                    pending.removeAll()
                    accumulator = 0
                    break
                }
            }
        }
        lastStepsPerFrame = steps
        // Cloth and camera run at render rate.
        let fdt = Float(realDt * min(1, timeScale * 1.5 + 0.1))
        if hitstopRemaining <= 0 {
            player.fighter.updateCloth(dt: fdt)
            for b in bosses { b.fighter.updateCloth(dt: fdt) }
        }
        let lock: Fighter? = fightPhase == .fighting ? player.lockTarget : nil
        let radius = arena.def.boundingRadius
        camera.update(dt: Float(realDt), now: realTime, player: player.fighter, lockTarget: lock, look: look, tuning: tuning.camera,
                      colliders: arena.colliders, arenaRadius: radius, freeMove: freeMove)
        subtitles = subtitles.filter { $0.2 > realTime }
        lightingBlend = approachf(lightingBlend, lighting.isEmpty ? 0 : 1, Float(realDt) * 0.6)
        updateFlow()
    }

    private func deliver(_ i: TimedInput) {
        guard fightPhase == .fighting || fightPhase == .intro else { return }
        if i.pressed { player.press(i.action, ctx: self) } else { player.release(i.action, ctx: self) }
    }

    private func updateFlow() {
        switch fightPhase {
        case .fighting:
            if player.fighter.dead {
                fightPhase = .defeat
                phaseTime = 0
            } else if aliveBosses.isEmpty {
                fightPhase = .victory
                phaseTime = 0
                emit(.victory)
                if let b = bosses.last?.fighter {
                    camera.startCinematic(focus: b.position + Vec3(0, 1, 0), yaw: dirToYaw(b.position - player.fighter.position) + 0.6,
                                          distance: 4.5, height: 0.6, until: realTime + 2.5)
                }
            }
        default: break
        }
    }

    private func simStep(_ dt: Double) {
        now += dt
        stepCount += 1
        // Deathblow and phase-transition camera shots.
        if fightPhase == .fighting {
            for b in bosses where (b.state == .phaseTransition && b.stateTime < dt * 1.5) || (b.state == .deathblowed && b.stateTime < dt * 1.5) {
                let f = b.fighter
                let side: Float = b.state == .deathblowed ? 1.2 : 2.3
                camera.startCinematic(focus: f.position + Vec3(0, f.height * 0.6, 0),
                                      yaw: dirToYaw(f.position - player.fighter.position) + side,
                                      distance: b.state == .deathblowed ? 2.8 : 3.4 + f.height * 0.6, height: 0.3,
                                      until: realTime + (b.state == .deathblowed ? 1.4 : 2.2))
            }
        }
        if fightPhase != .defeat { player.step(dt: dt, ctx: self) } else { player.fighter.updateAnimation(dt: Float(dt), running: false) }
        for b in bosses {
            if fightPhase == .intro || fightPhase == .fighting || b.fighter.dead || fightPhase == .victory {
                b.step(dt: dt, target: player.fighter, ctx: self)
            } else {
                b.fighter.updateAnimation(dt: Float(dt), running: false)
            }
        }
        separate()
        if fightPhase == .fighting {
            resolveAttacks(player.fighter)
            for b in bosses where !b.fighter.dead { resolveAttacks(b.fighter) }
            updateHazards(dt)
        }
        recordTrails()
    }

    private func recordTrails() {
        for f in [player.fighter] + bosses.map({ $0.fighter }) {
            var emit = false
            var side = "R"
            if let mv = f.move, let st = mv.strike, !st.feint, st.hitbox != .none {
                emit = mv.isActive || (mv.phase == .startup && mv.timeline.timeToActive < 0.035 * mv.timeline.speed)
                side = st.hitbox == .offhand ? "L" : st.side
            }
            trails.record(f.weapon, emitting: emit && side != "L", time: now)
            if let off = f.offhand, f.grip != .shield || side == "L" {
                trails.record(off, emitting: emit && (side == "L" || side == "both"), time: now)
            }
        }
    }

    private func logDefense(_ text: String) {
        defenseLog.append((text, realTime))
        if defenseLog.count > 6 { defenseLog.removeFirst() }
        logDebug(text, "combat")
    }

    /// Keeps fighters from overlapping.
    private func separate() {
        var all = [player.fighter] + bosses.filter { !$0.fighter.dead }.map { $0.fighter }
        if player.state == .grabbed || player.state == .deathblow { all.removeFirst() }
        for i in 0..<all.count {
            for j in (i + 1)..<max(i + 1, all.count) {
                let a = all[i], b = all[j]
                let d = vflat(b.position - a.position)
                let l = vlength(d)
                let r = a.radius + b.radius
                if l < r {
                    let n = l > 1e-4 ? d / l : Vec3(1, 0, 0)
                    let push = (r - l)
                    let wa: Float = a.isPlayer ? 0.7 : 0.5
                    a.position -= n * push * wa
                    b.position += n * push * (1 - wa)
                }
            }
        }
    }

    // MARK: - Hit detection

    private func strikingWeapons(_ f: Fighter, _ st: StrikeDef) -> [WeaponInstance] {
        if st.hitbox == .offhand { return f.offhand.map { [$0] } ?? [f.weapon] }
        switch st.side {
        case "L": return [f.offhand ?? f.weapon]
        case "both": return [f.weapon] + (f.offhand.map { [$0] } ?? [])
        default: return [f.weapon]
        }
    }

    private func resolveAttacks(_ attacker: Fighter) {
        guard let mv = attacker.move, let st = mv.strike, !st.feint, st.hitbox != .none else { return }
        guard mv.isActive else { return }
        let targets: [Fighter] = attacker.isPlayer ? aliveBosses.map { $0.fighter } : (player.fighter.dead ? [] : [player.fighter])
        // Multi-hit strikes re-arm periodically during the active window.
        if st.hits > 1 {
            mv.multiHitTimer += 1 / World.simRate * mv.timeline.speed
            let interval = st.activeTime / Double(st.hits)
            if mv.multiHitTimer >= interval { mv.multiHitTimer = 0; mv.hitTargets.removeAll() }
        }
        // Short-range burst on the first active frame.
        if st.aoeRadius > 0 && !mv.burstDone {
            mv.burstDone = true
            let tip = attacker.weapon.trailTipWorld
            let center = st.hitbox == .body || st.hitbox == .aoe ? attacker.position + attacker.forward * st.aoeOffset : Vec3(tip.x, 0, tip.z)
            emit(.burst(position: center, radius: st.aoeRadius, element: st.element))
            for t in targets where !mv.hitTargets.contains(t.id) {
                let tc = t.bodyCapsule()
                if Geometry.sphereCapsuleOverlap(Sphere(center + Vec3(0, 0.6, 0), st.aoeRadius), tc) != nil {
                    mv.hitTargets.insert(t.id)
                    applyHit(attacker: attacker, target: t, strike: st, point: t.center, move: mv)
                }
            }
            if st.hitbox == .aoe { return }
        }
        for t in targets where !mv.hitTargets.contains(t.id) {
            if let point = detect(attacker: attacker, target: t, strike: st, move: mv) {
                mv.hitTargets.insert(t.id)
                applyHit(attacker: attacker, target: t, strike: st, point: point, move: mv)
            }
        }
    }

    private func detect(attacker: Fighter, target: Fighter, strike st: StrikeDef, move mv: MoveRunner) -> Vec3? {
        let hurt = target.hurtboxes()
        let reach = mv.reach * st.reach
        if st.hitbox == .body || st.hitbox == .weaponAndBody {
            let body = attacker.bodyCapsule(inflate: 0.15)
            if let p = Geometry.capsuleOverlap(body, target.bodyCapsule()) { return p }
            if st.hitbox == .body { return nil }
        }
        for w in strikingWeapons(attacker, st) {
            let from = w.capsules(at: w.prevFrame, reach: reach)
            let to = w.capsules(at: w.frame, reach: reach)
            for k in 0..<min(from.count, to.count) {
                let sub = Geometry.sweepSubsteps(from: from[k], to: to[k], maxStep: 0.06)
                for (_, hb) in hurt {
                    if let p = Geometry.sweptCapsuleOverlap(from: from[k], to: to[k], target: hb, substeps: sub) { return p }
                }
            }
        }
        return nil
    }

    private func applyHit(attacker: Fighter, target: Fighter, strike st: StrikeDef, point: Vec3, move mv: MoveRunner) {
        let t = tuning
        let dir = vnormalize(vflat(target.position - attacker.position), fallback: attacker.forward)
        if attacker.isPlayer {
            guard let boss = boss(for: target) else { return }
            if now < target.invulnerableUntil && boss.state != .deathblowed { return }
            let isDeathblow = mv.tag == "\(MoveKind.deathblow)"
            let deflected = boss.receiveHit(strike: st, weaponPostureParryMult: player.weapon.stats.parryPostureMult, attacker: attacker,
                                            point: point, isDeathblowMove: isDeathblow, ctx: self)
            if deflected {
                // Recoil: the player's attack bounces and costs a little posture.
                _ = player.fighter.posture.add(st.posture * 0.25, now: now)
                player.fighter.animator.hitReact(dirLocal: Vec3(0, 0, -1), strength: 0.6)
                shake(t.camera.shakeParry * 0.5)
                return
            }
            player.stats.damageDealt += st.damage
            player.onHitLanded(target: target, strike: st, ctx: self)
            emit(.hit(attacker: attacker.id, target: target.id, point: point, dir: dir, weight: st.weight, damage: st.damage,
                      playerVictim: false, element: st.element, sound: attacker.weapon.type.sound))
            hitstop(t.hitstop.value(for: st.weight))
            shake(st.weight == .light ? t.camera.shakeLight * 0.6 : (st.weight == .medium ? t.camera.shakeLight : t.camera.shakeHeavy))
        } else {
            guard let boss = boss(for: attacker) else { return }
            var outcome = DefenseResolver.resolve(now: now, telegraph: st.telegraph, isGrab: st.hitbox == .grab, state: player.defense, windows: windows)
            let ms = { (t: Double?) -> String in t.map { String(format: "%+.0f ms", (self.now - $0) * 1000) } ?? "n/a" }
            switch outcome {
            case .parried(let p): logDefense("\(p ? "PERFECT PARRY" : "PARRY") \(ms(player.defense.parryPressTime)) after press [\(st.telegraph.rawValue)]")
            case .dodged(let p): logDefense("\(p ? "PERFECT DODGE" : "DODGE") \(ms(player.defense.dodgeStartTime)) into dodge")
            case .blocked: logDefense("BLOCK [\(st.telegraph.rawValue)]")
            case .hit:
                if let tp = player.defense.parryPressTime, now - tp < 0.6 { logDefense("HIT - parry pressed \(Int((now - tp) * 1000)) ms early (window \(Int(windows.parry * 1000)) ms) [\(st.telegraph.rawValue)]") }
                else if st.telegraph == .red { logDefense("HIT - red attack must be dodged") }
                else { logDefense("HIT [\(st.telegraph.rawValue)]") }
            case .counter: logDefense("IAIDO COUNTER")
            case .ignored: break
            }
            if player.invincible, case .hit = outcome { outcome = .ignored }
            if player.state == .deathblow || player.state == .dead { outcome = .ignored }
            switch outcome {
            case .parried(let perfect):
                emit(.parried(point: point, perfect: perfect, telegraph: st.telegraph, playerParried: true))
                hitstop(perfect ? t.hitstop.perfectParry : t.hitstop.parry)
                shake(perfect ? t.camera.shakeParry : t.camera.shakeParry * 0.6)
                if perfect { camera.fovKick = -4 }
                boss.wasParried(strike: st, perfect: perfect, weaponParryMult: player.weapon.stats.parryPostureMult, ctx: self)
            case .blocked:
                emit(.blocked(target: target.id, point: point, playerVictim: true))
                hitstop(t.hitstop.block)
                shake(t.camera.shakeLight)
            case .hit:
                emit(.hit(attacker: attacker.id, target: target.id, point: point, dir: dir, weight: st.weight, damage: st.damage,
                          playerVictim: true, element: st.element, sound: attacker.weapon.type.sound))
                hitstop(t.hitstop.playerHit)
                shake(st.weight == .huge || st.weight == .heavy ? t.camera.shakeSlam : t.camera.shakeHeavy)
                boss.stats.damageDealt += st.damage
            case .dodged(let perfect):
                if !perfect { emit(.dodged(perfect: false, position: player.fighter.center)) }
            case .counter, .ignored:
                break
            }
            player.receive(outcome: outcome, strike: st, attacker: attacker, point: point, ctx: self)
        }
    }

    private func updateHazards(_ dt: Double) {
        var keep: [Hazard] = []
        for var h in hazards {
            h.delay -= dt
            if h.delay > 0 { keep.append(h); continue }
            emit(.burst(position: h.center, radius: h.radius, element: h.element))
            var st = StrikeDef()
            st.damage = h.damage; st.posture = h.posture; st.telegraph = h.telegraph; st.weight = h.weight; st.element = h.element; st.bleed = h.bleed
            if h.ownerIsPlayer {
                for b in aliveBosses where Geometry.sphereCapsuleOverlap(Sphere(h.center + Vec3(0, 0.5, 0), h.radius), b.fighter.bodyCapsule()) != nil {
                    b.receiveHit(strike: st, weaponPostureParryMult: 1, attacker: player.fighter, point: b.fighter.center, isDeathblowMove: false, ctx: self)
                    emit(.hit(attacker: player.fighter.id, target: b.fighter.id, point: b.fighter.center, dir: vnormalize(b.fighter.position - h.center),
                              weight: h.weight, damage: h.damage, playerVictim: false, element: h.element, sound: .blunt))
                }
            } else if Geometry.sphereCapsuleOverlap(Sphere(h.center + Vec3(0, 0.5, 0), h.radius), player.fighter.bodyCapsule()) != nil,
                      let owner = bosses.first(where: { $0.fighter.id == h.owner }) {
                let outcome = DefenseResolver.resolve(now: now, telegraph: h.telegraph, isGrab: false, state: player.defense, windows: windows)
                player.receive(outcome: outcome, strike: st, attacker: owner.fighter, point: player.fighter.center, ctx: self)
            }
        }
        hazards = keep
    }

    // MARK: - Debug

    public func debugKillBoss() {
        for b in aliveBosses { b.fighter.health = 1; b.applyDamage(99999, posture: 0, ctx: self) }
    }

    /// Multi-line state dump for bug reports (F10).
    public func debugDump() -> String {
        var s = "=== WORLD DUMP t=\(String(format: "%.3f", now)) phase=\(fightPhase) steps=\(stepCount)\n"
        let p = player
        s += String(format: "player state=%@ t=%.3f hp=%.1f posture=%.1f stamina=%.1f ability=%.1f flasks=%d weapon=%@ pos=(%.2f,%.2f,%.2f) yaw=%.2f\n",
                    p.state.rawValue, p.stateTime, p.fighter.health, p.fighter.posture.value, p.stamina.value, p.abilityMeter, p.flasks,
                    p.weapon.id, p.fighter.position.x, p.fighter.position.y, p.fighter.position.z, p.fighter.yaw)
        for b in bosses {
            s += String(format: "boss %@ state=%@ t=%.3f phase=%d hp=%.1f/%.1f posture=%.1f/%.1f attack=%@ pos=(%.2f,%.2f,%.2f)\n",
                        b.def.id, b.state.rawValue, b.stateTime, b.phase, b.fighter.health, b.fighter.maxHealth, b.fighter.posture.value,
                        b.fighter.posture.max, b.currentAttack?.name ?? "-", b.fighter.position.x, b.fighter.position.y, b.fighter.position.z)
            s += "  habits parry=\(b.ai.habits.parry) dodge=\(b.ai.habits.dodge) weights=\(b.ai.lastWeights.prefix(6).map { "\($0.0):\(String(format: "%.2f", $0.1))" })\n"
        }
        s += String(format: "windows parry=%.0fms perfect=%.0fms iframes=%.0fms perfectDodge=%.0fms\n",
                    windows.parry * 1000, windows.perfectParry * 1000, windows.iframes * 1000, windows.perfectDodge * 1000)
        return s
    }
}
