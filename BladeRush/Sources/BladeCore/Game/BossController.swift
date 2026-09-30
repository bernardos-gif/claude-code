// Boss hierarchical state machine: intro -> combat { neutral (spacing), attacking,
// recovering (deliberate opening), flinch, deflect } -> staggered (posture broken,
// deathblow window) -> phase transitions -> death. Special states for player abilities:
// pulled (chain), disarmed, confused (afterimage decoy).
import Foundation

public enum BossState: String {
    case intro, neutral, attacking, recovering, flinch, deflecting, staggered, deathblowed, phaseTransition, pulled, dead
}

public final class BossController {
    public let fighter: Fighter
    public let def: BossDef
    public private(set) var attacks: [ResolvedAttack]
    public private(set) var phase = 1
    public private(set) var state: BossState = .intro
    public private(set) var stateTime: Double = 0
    private var stateDuration: Double = 0
    public let ai: BossAI
    public private(set) var currentAttack: ResolvedAttack?
    public private(set) var speedMult: Float = 1
    public private(set) var damageMult: Float = 1
    public private(set) var aggression: Float = 1
    public private(set) var disarmedUntil: Double = 0
    public private(set) var confusedUntil: Double = 0
    public private(set) var decoy: Vec3 = .zero
    private var poiseDamage: Float = 0
    private var pendingPhase: Int?
    private var phaseApplied = false
    private var pullTarget: Vec3 = .zero
    private var pullStart: Vec3 = .zero
    private var telegraphSent: Set<Int> = []
    public private(set) var telegraph: Telegraph = .none
    public private(set) var telegraphIntensity: Float = 0
    public var director: GauntletDirector?
    public let hardMode: Bool
    public var preferredRange: Float = 2.5
    public private(set) var deathblowDamagePending = false
    public var stats = FightStats()
    public private(set) var lastDeflectCounter: Double = -10
    public var postureMax: Float

    public init(fighter: Fighter, def: BossDef, attacks: [ResolvedAttack], hardMode: Bool, tuning: CombatTuning) {
        self.fighter = fighter
        self.def = def
        self.attacks = attacks
        self.hardMode = hardMode
        ai = BossAI(seed: Rng.hash(def.id) &+ UInt64(fighter.id))
        postureMax = def.stats.posture * (hardMode ? tuning.hardMode.bossPostureMult : 1)
        fighter.posture = PostureMeter(max: postureMax)
        let ranges = attacks.map { ($0.minRange + $0.maxRange) * 0.5 }.sorted()
        preferredRange = ranges.isEmpty ? 2.5 : ranges[ranges.count / 2]
        applyPhaseStats(tuning: tuning)
    }

    public var canBeDeathblowed: Bool { state == .staggered }
    public var isAttacking: Bool { state == .attacking }
    public var isDisarmed: Bool { false }
    public var phaseCount: Int { def.phases.count }
    public var phaseDef: PhaseDef { def.phases[min(phase - 1, def.phases.count - 1)] }

    private func applyPhaseStats(tuning: CombatTuning) {
        let p = phaseDef
        let hard = hardMode ? tuning.hardMode.bossSpeedMult : 1
        speedMult = def.stats.speed * p.speed * tuning.boss.speedMult * hard
        damageMult = p.damage * tuning.boss.damageMult * (hardMode ? tuning.hardMode.bossDamageMult : 1)
        aggression = def.stats.aggression * p.aggression * tuning.boss.globalAggression
    }

    private func enter(_ s: BossState, duration: Double = 0) {
        state = s
        stateTime = 0
        stateDuration = duration
        if s != .attacking { telegraph = .none; telegraphIntensity = 0 }
    }

    private func pose(_ name: String, _ ctx: CombatContext, inTime: Double, hold: Double, outTime: Double, lockFeet: Bool = false) {
        let p = ctx.lib.pose(name, grip: fighter.grip)
        fighter.animator.play(AnimTrack.pose(from: fighter.animator.pose, to: p, inTime: inTime, hold: hold, outTime: outTime,
                                             end: fighter.animator.stance(), lockFeet: lockFeet), fade: 0.04)
    }

    // MARK: - External effects

    public func startFight(ctx: CombatContext) {
        enter(.neutral)
        ai.nextAttackTime = ctx.now + 1.2
    }

    public func beginIntro(ctx: CombatContext, duration: Double) {
        enter(.intro, duration: duration)
        pose("taunt", ctx, inTime: 0.4, hold: duration - 0.8, outTime: 0.4)
    }

    public func interrupt(stagger: Double, ctx: CombatContext) {
        guard state != .dead && state != .phaseTransition && state != .staggered && state != .deathblowed else { return }
        endAttack(ctx: ctx, cancelled: true)
        enter(.flinch, duration: stagger)
        pose("stagger", ctx, inTime: 0.08, hold: max(0.05, stagger - 0.3), outTime: 0.22)
    }

    public func push(from p: Vec3, distance: Float, ctx: CombatContext) {
        let dir = vnormalize(vflat(fighter.position - p), fallback: -fighter.forward)
        fighter.knockback += dir * distance
    }

    public func disarm(duration: Double, ctx: CombatContext) {
        disarmedUntil = ctx.now + duration
        interrupt(stagger: 0.5, ctx: ctx)
    }

    public func confuse(until: Double, decoy: Vec3) {
        confusedUntil = until
        self.decoy = decoy
    }

    public func pulled(toward p: Vec3, ctx: CombatContext) {
        guard state != .dead && state != .phaseTransition && state != .deathblowed else { return }
        let wasWindingUp = state == .attacking && (fighter.move?.phase == .startup)
        endAttack(ctx: ctx, cancelled: true)
        pullStart = fighter.position
        pullTarget = ctx.clampToArena(p, margin: fighter.radius)
        enter(.pulled, duration: wasWindingUp ? 1.1 : 0.7)
        pose("stagger", ctx, inTime: 0.05, hold: stateDuration - 0.25, outTime: 0.2, lockFeet: true)
    }

    /// Extra hits from weapon bonuses (chain lash, chain pull).
    public func receiveBonusHit(damage: Float, posture: Float, from attacker: Fighter, ctx: CombatContext) {
        applyDamage(damage, posture: posture, ctx: ctx)
        fighter.hitFlash = 1
        fighter.flashColor = Vec3(1, 1, 1)
    }

    public func receiveDeathblowStart(from player: Fighter, ctx: CombatContext) {
        enter(.deathblowed, duration: 3.0)
        deathblowDamagePending = true
        fighter.yaw = dirToYaw(player.position - fighter.position)
        pose("kneel", ctx, inTime: 0.15, hold: 2.4, outTime: 0.4, lockFeet: true)
        ctx.slowMotion(duration: 0.9, scale: 0.45)
    }

    /// The deathblow strike connected: end the phase or deal massive damage.
    public func applyDeathblow(ctx: CombatContext) {
        guard deathblowDamagePending else { return }
        deathblowDamagePending = false
        stats.deathblows += 1
        ctx.emit(.deathblow(point: fighter.center))
        ctx.hitstop(ctx.tuning.hitstop.deathblow)
        ctx.shake(0.9)
        fighter.posture.reset()
        if phase < def.phases.count {
            // Deathblow ends the current phase.
            let next = def.phases[phase].threshold
            fighter.health = min(fighter.health, fighter.maxHealth * next)
            pendingPhase = phase + 1
            enter(.flinch, duration: 1.0)
        } else {
            let dmg = fighter.maxHealth * ctx.tuning.boss.deathblowDamageFraction
            fighter.applyDamage(dmg)
            if fighter.health <= 0 { die(ctx: ctx) } else { enter(.flinch, duration: 1.2) }
        }
    }

    /// Player hit this boss. Returns true if the boss deflected it.
    @discardableResult
    public func receiveHit(strike: StrikeDef, weaponPostureParryMult: Float, attacker: Fighter, point: Vec3, isDeathblowMove: Bool, ctx: CombatContext) -> Bool {
        if state == .dead || state == .phaseTransition { return false }
        if state == .deathblowed {
            if isDeathblowMove { applyDeathblow(ctx: ctx) }
            return false
        }
        // Counter stance (mirrored Iaido): deflect and release the draw cut instantly.
        if state == .attacking, let mv = fighter.move, let st = mv.strike, st.counterStance, mv.phase == .startup {
            _ = fighter.posture.add(strike.posture * 0.2, now: ctx.now)
            ctx.emit(.bossDeflect(point: point))
            ctx.emit(.counter(position: fighter.center))
            ctx.hitstop(ctx.tuning.hitstop.parry)
            fighter.yaw = dirToYaw(attacker.position - fighter.position)
            mv.releaseCounter()
            return true
        }
        // Skilled bosses deflect hits while idle (Sekiro-style), then counter.
        if state == .neutral || state == .recovering && stateTime > stateDuration * 0.7 {
            let chance = def.stats.deflect * (0.7 + 0.3 * Float(phase)) * (hardMode ? 1.3 : 1)
            if ai.rng.chance(min(0.85, chance)) && ctx.now >= disarmedUntil {
                enter(.deflecting, duration: 0.32)
                pose("parry", ctx, inTime: 0.03, hold: 0.12, outTime: 0.15)
                fighter.yaw = dirToYaw(attacker.position - fighter.position)
                _ = fighter.posture.add(strike.posture * 0.3, now: ctx.now)
                ctx.emit(.bossDeflect(point: point))
                ctx.hitstop(ctx.tuning.hitstop.block)
                ai.nextAttackTime = ctx.now + 0.12
                lastDeflectCounter = ctx.now
                return true
            }
        }
        var dmg = strike.damage
        var post = strike.posture
        if strike.bleed > 0 { dmg *= def.weakTo["bleed"] ?? 1 }
        post *= def.weakTo["posture"] ?? 1
        if strike.weight == .heavy || strike.weight == .huge { dmg *= def.weakTo["heavy"] ?? 1; post *= def.weakTo["heavy"] ?? 1 }
        if state == .staggered { post = 0; dmg *= 1.2 }
        applyDamage(dmg, posture: post, ctx: ctx)
        if strike.bleed > 0 {
            fighter.bleedStacks = min(ctx.tuning.player.maxBleedStacks, fighter.bleedStacks + strike.bleed)
            fighter.bleedUntil = ctx.now + ctx.tuning.player.bleedDuration
            ctx.emit(.bleed(position: point))
        }
        // Flinch when poise is exceeded outside of attacks (bosses keep swinging through light hits).
        poiseDamage += dmg
        if (state == .neutral || state == .recovering) && poiseDamage > def.stats.poise && state != .staggered {
            poiseDamage = 0
            enter(.flinch, duration: 0.38)
            let dirLocal = Quat.yaw(fighter.yaw).conjugate.rotate(vnormalize(vflat(fighter.position - attacker.position)))
            fighter.animator.hitReact(dirLocal: dirLocal, strength: 1)
        } else {
            let dirLocal = Quat.yaw(fighter.yaw).conjugate.rotate(vnormalize(vflat(fighter.position - attacker.position)))
            fighter.animator.hitReact(dirLocal: dirLocal, strength: 0.5)
        }
        if strike.launch && def.stats.radius < 0.6 && state != .staggered {
            interrupt(stagger: 0.8, ctx: ctx)
            fighter.knockback += vnormalize(vflat(fighter.position - attacker.position)) * 0.8
        }
        if strike.knockback > 0 { fighter.knockback += vnormalize(vflat(fighter.position - attacker.position)) * strike.knockback * 0.5 }
        return false
    }

    /// The player parried one of this boss's strikes.
    public func wasParried(strike: StrikeDef, perfect: Bool, weaponParryMult: Float, ctx: CombatContext) {
        let post = CombatMath.bossPostureFromParry(perfect: perfect, telegraph: strike.telegraph, attackPosture: strike.posture,
                                                   weaponParryMult: weaponParryMult, t: ctx.tuning.boss)
        applyDamage(0, posture: post, ctx: ctx)
        fighter.animator.hitReact(dirLocal: Vec3(0, 0, -1), strength: perfect ? 0.9 : 0.4)
        if perfect && strike.telegraph == .gold && state == .attacking {
            // Gold combo ender perfectly parried: big punish window.
            interrupt(stagger: ctx.tuning.boss.goldPunishStagger, ctx: ctx)
        }
    }

    func applyDamage(_ dmg: Float, posture: Float, ctx: CombatContext) {
        guard state != .dead else { return }
        if dmg > 0 {
            // Phases cannot be skipped: clamp at the next threshold.
            var floorHP: Float = 0
            if phase < def.phases.count { floorHP = fighter.maxHealth * def.phases[phase].threshold }
            fighter.health = max(floorHP, fighter.health - dmg)
            stats.damageTaken += dmg
            fighter.hitFlash = 1
            fighter.flashColor = Vec3(1, 0.9, 0.8)
            if phase < def.phases.count && fighter.health <= floorHP + 0.01 && pendingPhase == nil {
                pendingPhase = phase + 1
            }
            if fighter.health <= 0 && phase >= def.phases.count { die(ctx: ctx); return }
        }
        if posture > 0 && state != .staggered && state != .deathblowed {
            if fighter.posture.add(posture, now: ctx.now) {
                endAttack(ctx: ctx, cancelled: true)
                enter(.staggered, duration: ctx.tuning.boss.staggerDuration)
                pose("stagger", ctx, inTime: 0.1, hold: ctx.tuning.boss.staggerDuration - 0.4, outTime: 0.3)
                ctx.emit(.postureBreak(target: fighter.id, position: fighter.center, isPlayer: false))
                ctx.hitstop(ctx.tuning.hitstop.postureBreak)
                ctx.shake(0.55)
            }
        }
    }

    private func die(ctx: CombatContext) {
        endAttack(ctx: ctx, cancelled: true)
        enter(.dead)
        fighter.dead = true
        fighter.health = 0
        let p = ctx.lib.pose("dead", grip: fighter.grip)
        fighter.animator.play(AnimTrack(keys: [AnimTrack.Key(0, fighter.animator.pose, .linear), AnimTrack.Key(1.1, p, .outBack),
                                               AnimTrack.Key(3600, p, .linear)], lockFeet: true), fade: 0.05)
        ctx.emit(.death(fighter: fighter.id, position: fighter.center, isPlayer: false))
        if !def.death.isEmpty { ctx.emit(.subtitle(speaker: def.name, text: def.death, duration: 4)) }
    }

    private func endAttack(ctx: CombatContext, cancelled: Bool) {
        if currentAttack != nil { director?.finished(fighter.id, now: ctx.now) }
        currentAttack = nil
        fighter.move = nil
        fighter.hyperArmor = false
        fighter.weapon.chainExtension = 0
        fighter.animator.tremble = 0
        telegraph = .none
        telegraphIntensity = 0
    }

    // MARK: - Update

    public func step(dt: Double, target: Fighter, ctx: CombatContext) {
        let fdt = Float(dt)
        stateTime += dt
        ai.habits.decay(fdt)
        telegraphIntensity = max(0, telegraphIntensity - fdt * 2.5)
        fighter.hitFlash = max(0, fighter.hitFlash - fdt * 6)
        fighter.posture.recover(dt: dt, now: ctx.now, delay: ctx.tuning.boss.postureRecoverDelay,
                                rate: ctx.tuning.boss.postureRecoverRate * def.stats.postureRegen,
                                healthFraction: fighter.healthFraction, boost: state == .neutral ? 1.3 : 1)
        // Bleed damage over time.
        if fighter.bleedStacks > 0 {
            if ctx.now > fighter.bleedUntil { fighter.bleedStacks = 0 } else {
                fighter.bleedTick += dt
                if fighter.bleedTick >= 0.5 {
                    fighter.bleedTick = 0
                    applyDamage(Float(fighter.bleedStacks) * ctx.tuning.player.bleedDamagePerStack * 0.5, posture: 0, ctx: ctx)
                }
            }
        }
        let confused = ctx.now < confusedUntil
        let aimPoint = confused ? decoy : target.position
        let toTarget = vflat(aimPoint - fighter.position)
        let dist = max(0, vlength(toTarget) - target.radius - fighter.radius)
        fighter.animator.lookTarget = target.headPosition

        // Phase transitions start as soon as the boss is free to act.
        if let np = pendingPhase, state != .attacking, state != .deathblowed, state != .dead, state != .phaseTransition {
            pendingPhase = nil
            phase = min(np, def.phases.count)
            phaseApplied = false
            endAttack(ctx: ctx, cancelled: true)
            enter(.phaseTransition, duration: ctx.tuning.boss.phaseTransitionDuration)
            fighter.invulnerableUntil = ctx.now + ctx.tuning.boss.phaseTransitionDuration
            pose("roar", ctx, inTime: 0.4, hold: ctx.tuning.boss.phaseTransitionDuration - 0.9, outTime: 0.5)
        }

        var desiredVel = Vec3.zero
        switch state {
        case .dead:
            break
        case .intro:
            fighter.yaw = dampAngle(fighter.yaw, dirToYaw(toTarget), 4, fdt)
            if stateTime >= stateDuration { startFight(ctx: ctx) }
        case .neutral:
            fighter.yaw = approachAngle(fighter.yaw, dirToYaw(toTarget), 4.5 * fdt)
            let canAttack = ctx.now >= disarmedUntil && target.dead == false
            var attacked = false
            // Punish heals and exploit openings.
            if case .healing = (ctx as? World)?.player.state ?? .locomotion, dist < preferredRange + 2 {
                ai.nextAttackTime = min(ai.nextAttackTime, ctx.now + 0.1)
            }
            if canAttack && ctx.now >= ai.nextAttackTime && ai.mayAttack() {
                let preferFast = ctx.now - lastDeflectCounter < 0.5
                if let a = ai.chooseAttack(attacks, distance: dist, phase: phase, hardMode: hardMode, now: ctx.now,
                                           adaptStrength: ctx.tuning.boss.adaptiveStrength, preferFast: preferFast) {
                    startAttack(a, ctx: ctx)
                    attacked = true
                } else if dist > preferredRange {
                    ai.mode = .approach
                }
            }
            if !attacked {
                if ctx.now >= ai.modeUntil { ai.chooseSpacing(distance: dist, preferred: preferredRange, now: ctx.now, aggression: aggression) }
                let fwd = vnormalize(toTarget, fallback: fighter.forward)
                let side = Vec3(-fwd.z, 0, fwd.x)
                let speed = def.stats.moveSpeed * speedMult
                switch ai.mode {
                case .approach: desiredVel = fwd * speed * (dist > 6 ? 1.7 : 1)
                case .retreat: desiredVel = -fwd * speed * 0.9
                case .circleLeft: desiredVel = side * speed * 0.55 + fwd * (dist - preferredRange) * 0.4
                case .circleRight: desiredVel = -side * speed * 0.55 + fwd * (dist - preferredRange) * 0.4
                case .flank:
                    let want = target.position + Vec3(sin(ai.flankAngle), 0, cos(ai.flankAngle)) * (preferredRange + 1.5)
                    desiredVel = vclampLength(vflat(want - fighter.position) * 2, speed)
                case .wait: desiredVel = .zero
                }
                if let d = director, d.holder != nil, d.holder != fighter.id {
                    // Partner holds the token: flank the player from the other side.
                    ai.mode = .flank
                }
            }
        case .attacking:
            guard let mv = fighter.move, let atk = currentAttack else { enter(.neutral); break }
            let events = mv.step(dt: dt, fighter: fighter, target: aimPoint, lib: ctx.lib)
            for e in events {
                switch e {
                case .strikeBegan(let i):
                    telegraphSent.remove(i)
                    let st = mv.timeline.strikes[i]
                    if st.telegraph == .red || st.telegraph == .purple {
                        telegraph = st.telegraph; telegraphIntensity = 1
                        telegraphSent.insert(i)
                        ctx.emit(.telegraph(fighter: fighter.id, kind: st.telegraph, position: fighter.weapon.trailTipWorld))
                    }
                    if st.hyperArmor { fighter.hyperArmor = true }
                case .activeBegan:
                    if let st = mv.strike {
                        ctx.emit(.whoosh(fighter: fighter.id, position: fighter.weapon.trailTipWorld, sound: fighter.weapon.type.sound,
                                         weight: fighter.weapon.type.weight, speed: Float(mv.timeline.speed)))
                        if st.leap > 0 { ctx.emit(.landing(position: fighter.position, weight: 1)) }
                    }
                default: break
                }
            }
            // White / gold flashes fire a fixed lead time before the hit.
            if let st = mv.strike, mv.phase == .startup, !telegraphSent.contains(mv.timeline.index) {
                let lead = min(0.36, st.startupTime * 0.75) / mv.timeline.speed
                if (st.telegraph == .white || st.telegraph == .gold) && mv.timeline.timeToActive / mv.timeline.speed <= lead {
                    telegraphSent.insert(mv.timeline.index)
                    telegraph = st.telegraph; telegraphIntensity = 1
                    ctx.emit(.telegraph(fighter: fighter.id, kind: st.telegraph, position: fighter.weapon.trailTipWorld))
                }
            }
            if let st = mv.strike, (st.telegraph == .red || st.telegraph == .purple), mv.phase == .startup {
                telegraphIntensity = max(telegraphIntensity, 0.8)
            }
            if fighter.weapon.type.flex != nil {
                let extend: Float = (mv.phase == .active || (mv.phase == .startup && mv.timeline.timeToActive < 0.08)) ? 1 : 0
                fighter.weapon.chainExtension = approachf(fighter.weapon.chainExtension, extend, fdt * (extend > 0 ? 8 : 3))
            }
            if mv.isDone {
                let opening = Double(atk.opening)
                endAttack(ctx: ctx, cancelled: false)
                if opening > 0 {
                    enter(.recovering, duration: opening / Double(max(speedMult, 0.5)))
                    pose("rest", ctx, inTime: 0.2, hold: max(0.1, stateDuration - 0.5), outTime: 0.3)
                } else {
                    enter(.neutral)
                }
                // Pressure strings: aggressive bosses sometimes chain straight into another attack.
                let chain = ai.rng.chance(min(0.45, 0.12 * aggression + 0.08 * Float(phase)))
                let interval = ctx.tuning.boss.attackInterval / Double(max(0.3, aggression))
                ai.nextAttackTime = ctx.now + (chain ? 0.15 : interval * Double(ai.rng.range(0.6, 1.4))) + opening
            }
        case .recovering, .flinch, .deflecting:
            if state == .deflecting { fighter.yaw = approachAngle(fighter.yaw, dirToYaw(toTarget), 8 * fdt) }
            if stateTime >= stateDuration { enter(.neutral) }
        case .staggered:
            if stateTime >= stateDuration {
                fighter.posture.value = fighter.posture.max * 0.5
                enter(.neutral)
                ai.nextAttackTime = ctx.now + 0.4
            }
        case .deathblowed:
            if stateTime >= stateDuration { deathblowDamagePending = false; enter(.neutral) }
        case .phaseTransition:
            if !phaseApplied && stateTime >= stateDuration * 0.4 {
                phaseApplied = true
                applyPhaseStats(tuning: ctx.tuning)
                let p = phaseDef
                if let w = p.weapon { fighter.switchWeapon(w) }
                fighter.glow = max(fighter.glow, p.glow)
                fighter.weapon.glow = max(fighter.weapon.glow, p.glow)
                if let e = p.element { fighter.elementGlow = e }
                fighter.posture.reset()
                ctx.emit(.phaseStart(fighter: fighter.id, phase: phase, line: p.line, lighting: p.lighting))
                if !p.line.isEmpty { ctx.emit(.subtitle(speaker: def.name, text: p.line, duration: 3.5)) }
                ctx.shake(0.5)
            }
            if stateTime >= stateDuration {
                enter(.neutral)
                ai.nextAttackTime = ctx.now + 0.3
            }
        case .pulled:
            let u = Float(min(1, stateTime / 0.3))
            fighter.position = vlerp(pullStart, pullTarget, Ease.outCubic.apply(u))
            if stateTime >= stateDuration { enter(.neutral) }
        }

        // Movement integration.
        let fv = vflat(fighter.velocity)
        let accel: Float = 14 * fdt
        let dv = desiredVel - fv
        fighter.velocity = fv + (vlength(dv) > accel ? vnormalize(dv) * accel : dv)
        if state != .neutral { fighter.velocity = .zero }
        fighter.position += fighter.velocity * fdt
        if vlengthSq(fighter.knockback) > 1e-6 {
            let k = fighter.knockback * min(1, fdt * 8)
            fighter.position += k
            fighter.knockback -= k
        }
        fighter.position = ctx.clampToArena(fighter.position, margin: fighter.radius)
        if fighter.move == nil { fighter.position.y = 0 }
        fighter.updateAnimation(dt: fdt, running: vlength(fighter.velocity) > 3.5)
    }

    private func startAttack(_ a: ResolvedAttack, ctx: CombatContext) {
        currentAttack = a
        ai.noteUsed(a, now: ctx.now)
        var strikes = a.strikes
        for i in strikes.indices { strikes[i].damage *= damageMult }
        let mv = MoveRunner(strikes: strikes, speed: Double(speedMult * a.speed), tag: a.name)
        mv.trackingScale = hardMode ? 1.25 : 1
        fighter.move = mv
        telegraphSent.removeAll()
        enter(.attacking)
        director?.began(fighter.id, now: ctx.now, rng: &ai.rng)
    }
}
