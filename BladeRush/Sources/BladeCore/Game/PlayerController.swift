// The player's combat state machine.
//
// Cancel rules (all times from the move's frame data):
//   * Light attacks chain into the next light after `comboFrame` (default: end of active).
//   * Any attack cancels into dodge / parry after `cancelFrame` (default: end of active + 2f).
//   * Dodges cancel into attacks / parry after `timing.dodgeCancelAfter`.
//   * Blocking and locomotion accept everything; hitstun, heal and posture break accept nothing.
//   * Presses up to `timing.inputBuffer` early are buffered and fire at the first legal frame.
import Foundation

public enum PlayerState: String {
    case locomotion, attacking, charging, dodging, parrying, blocking, deflecting, parryWhiff
    case blockstun, hitstun, postureBroken, healing, swapping, grabbed, stance, chainThrow, deathblow, dead
}

public enum MoveKind: Equatable {
    case light(Int), heavy(Int), ability, counter, riposte, swapStrike, deathblow, bloodDance
}

public final class PlayerController {
    public let fighter: Fighter
    public private(set) var state: PlayerState = .locomotion
    public private(set) var stateTime: Double = 0
    public private(set) var weapons: [PlayerWeaponDef]
    public private(set) var weaponIndex = 0
    public var stamina: StaminaMeter
    public var abilityMeter: Float = 0
    public var flasks: Int
    public var maxFlasks: Int
    public var buffer: InputBuffer
    public var defense = DefenseState()
    public private(set) var moveKind: MoveKind?
    public private(set) var comboIndex = 0
    private var comboQueued = false
    public private(set) var charge: Float = 0
    public private(set) var chargeLevel = 0
    private var heavyHeld = false
    private var parryHeld = false
    private var parryLockUntil: Double = -1
    private var dodgeDir = Vec3(0, 0, -1)
    private var dodgeDistance: Float = 3.8
    private var dodgeApplied: Float = 0
    public private(set) var dodgeStartTime: Double = -100
    private var stateDuration: Double = 0
    private var healed = false
    private var swapTarget = 0
    private var swapped = false
    // Weapon bonuses.
    public private(set) var nextPostureMult: Float = 1
    public private(set) var instantCharge = false
    private var bloodDanceExtensions = 0
    private var stanceUntil: Double = 0
    private var chainPhase = 0
    private var chainHit = false
    // Movement.
    public var moveInput = Vec2.zero       // x = right, y = forward (camera relative)
    public var cameraYaw: Float = 0
    public var lockTarget: Fighter?
    public var stats = FightStats()
    public var invincible = false          // debug
    public var grabbedUntil: Double = 0
    private var grabDamage: Float = 0
    private var grabAttacker: Fighter?
    public private(set) var lastPerfectDodge: Double = -100
    public private(set) var lastPerfectParry: Double = -100

    public init(fighter: Fighter, weapons: [PlayerWeaponDef], startWeapon: Int, tuning: PlayerTuning, timing: TimingTuning) {
        self.fighter = fighter
        self.weapons = weapons
        stamina = StaminaMeter(max: tuning.maxStamina)
        flasks = tuning.flasks
        maxFlasks = tuning.flasks
        buffer = InputBuffer(window: timing.inputBuffer)
        weaponIndex = max(0, min(startWeapon, weapons.count - 1))
        if !weapons.isEmpty { fighter.setWeapon(weapons[weaponIndex].visual) }
    }

    public var weapon: PlayerWeaponDef { weapons[weaponIndex] }
    public var isDodging: Bool { state == .dodging }
    public var abilityReady: Bool { abilityMeter >= weapon.stats.abilityCost }

    // MARK: - State helpers

    private func enter(_ s: PlayerState, duration: Double = 0, ctx: CombatContext) {
        if state == .parrying || state == .blocking, s != .parrying, s != .blocking, s != .deflecting, s != .blockstun {
            defense.parryPressTime = nil
        }
        state = s
        stateTime = 0
        stateDuration = duration
        if s != .dodging { defense.dodgeStartTime = nil }
        defense.counterStance = (s == .stance)
        defense.parryHeld = (s == .blocking || s == .parrying) && parryHeld
        fighter.hyperArmor = false
    }

    private func pose(_ name: String, ctx: CombatContext, inTime: Double, hold: Double, outTime: Double, lockFeet: Bool = false, mirrored: Bool = false) {
        let p = ctx.lib.pose(name, grip: fighter.grip, mirrored: mirrored)
        let track = AnimTrack.pose(from: fighter.animator.pose, to: p, inTime: inTime, hold: hold, outTime: outTime,
                                   end: fighter.animator.stance(), lockFeet: lockFeet)
        fighter.animator.play(track, fade: 0.03)
    }

    // MARK: - Input

    public func press(_ a: PlayerAction, ctx: CombatContext) {
        if state == .dead { return }
        switch a {
        case .parry: parryHeld = true
        case .heavy: heavyHeld = true
        default: break
        }
        // Katana stance counter / blood dance dodge-extension are handled on press directly.
        if a == .dodge && state == .attacking, case .bloodDance = moveKind ?? .ability, bloodDanceExtensions < Int(weapon.ability.extra) {
            bloodDanceExtensions += 1
            startDodge(ctx: ctx, keepMove: true)
            return
        }
        buffer.push(a, at: ctx.now)
        tryConsumeBuffer(ctx: ctx)
    }

    public func release(_ a: PlayerAction, ctx: CombatContext) {
        switch a {
        case .parry:
            parryHeld = false
            defense.parryHeld = false
            if state == .blocking { enter(.locomotion, ctx: ctx); fighter.animator.stop(fade: 0.1) }
        case .heavy:
            heavyHeld = false
            if state == .charging { releaseHeavy(ctx: ctx) }
        default: break
        }
    }

    /// Actions allowed right now (the buffer holds anything else until it becomes legal).
    private func allowed(_ a: PlayerAction, ctx: CombatContext) -> Bool {
        let t = ctx.tuning.timing
        switch state {
        case .locomotion:
            return true
        case .blocking:
            return a != .heal
        case .attacking:
            guard let mv = fighter.move, let st = mv.strike else { return true }
            let ft = mv.strikeTime * 60
            let comboF = Double(st.comboFrame >= 0 ? st.comboFrame : st.startup + st.delay + max(st.active, 1))
            let cancelF = Double(st.cancelFrame >= 0 ? st.cancelFrame : st.startup + st.delay + max(st.active, 1) + 2)
            switch a {
            case .light:
                if case .light = moveKind ?? .ability { return ft >= comboF }
                return mv.isDone
            case .swapNext, .swapPrev:
                return ft >= comboF
            case .dodge, .parry:
                return ft >= cancelF
            default:
                return mv.isDone
            }
        case .dodging:
            return stateTime >= t.dodgeCancelAfter && a != .heal
        case .deflecting:
            return stateTime >= 0.1 && a != .heal
        case .charging:
            return a == .dodge || a == .parry
        case .stance:
            return a == .dodge || a == .parry
        default:
            return false
        }
    }

    private func tryConsumeBuffer(ctx: CombatContext) {
        guard let a = buffer.take(now: ctx.now, allowed: { self.allowed($0, ctx: ctx) }) else { return }
        execute(a, ctx: ctx)
    }

    private func execute(_ a: PlayerAction, ctx: CombatContext) {
        switch a {
        case .light:
            if let tgt = lockOrNearest(ctx), let boss = ctx.boss(for: tgt), boss.canBeDeathblowed,
               vlength(vflat(tgt.position - fighter.position)) <= ctx.tuning.player.deathblowRange + tgt.radius {
                startDeathblow(boss: boss, ctx: ctx)
                return
            }
            if state == .attacking, case .light(let i) = moveKind ?? .ability {
                startLight(index: (i + 1) % max(1, weapon.light.count), ctx: ctx)
            } else {
                startLight(index: 0, ctx: ctx)
            }
        case .heavy:
            startCharge(ctx: ctx)
        case .ability:
            startAbility(ctx: ctx)
        case .parry:
            startParry(ctx: ctx)
        case .dodge:
            startDodge(ctx: ctx, keepMove: false)
        case .heal:
            startHeal(ctx: ctx)
        case .swapNext, .swapPrev:
            let n = weapons.count
            let target = a == .swapNext ? (weaponIndex + 1) % n : (weaponIndex - 1 + n) % n
            swap(to: target, ctx: ctx)
        }
    }

    // MARK: - Moves

    private func lockOrNearest(_ ctx: CombatContext) -> Fighter? {
        if let l = lockTarget, !l.dead { return l }
        return ctx.target(for: fighter)
    }

    private func startMove(_ strikes: [StrikeDef], kind: MoveKind, speedMul: Float = 1, ctx: CombatContext) {
        guard !strikes.isEmpty else { return }
        let st = weapon.stats
        var scaled = strikes
        for i in scaled.indices {
            scaled[i].damage *= st.damage
            scaled[i].posture *= st.posture * nextPostureMult
        }
        if nextPostureMult != 1 { nextPostureMult = 1 }
        let mv = MoveRunner(strikes: scaled, speed: Double(st.speed * speedMul), tag: "\(kind)")
        mv.reach = st.reach
        fighter.move = mv
        moveKind = kind
        // Snap facing toward the target or the stick direction at the start of a move.
        if let t = lockOrNearest(ctx), vlength(vflat(t.position - fighter.position)) < 7 {
            fighter.yaw = approachAngle(fighter.yaw, dirToYaw(t.position - fighter.position), 1.2)
        } else if vlength2(moveInput) > 0.3 {
            fighter.yaw = dirToYaw(worldMoveDir())
        }
        enter(.attacking, ctx: ctx)
        fighter.velocity = .zero
    }

    private func startLight(index: Int, ctx: CombatContext) {
        let cost = weapon.stats.staminaLight
        guard stamina.canAct else { return }
        stamina.spend(cost, now: ctx.now)
        comboIndex = index
        startMove([weapon.light[index % weapon.light.count]], kind: .light(index), ctx: ctx)
    }

    private func startCharge(ctx: CombatContext) {
        guard stamina.canAct else { return }
        enter(.charging, ctx: ctx)
        charge = 0
        chargeLevel = 0
        if instantCharge {
            chargeLevel = max(0, min(weapon.stats.chargeLevels - 1, weapon.heavy.count - 1))
            charge = Float(chargeLevel) * weapon.stats.chargeTime
            instantCharge = false
            releaseHeavy(ctx: ctx)
            return
        }
        pose("charge", ctx: ctx, inTime: 0.18, hold: 10, outTime: 0.1)
        if !heavyHeld { releaseHeavy(ctx: ctx) }
    }

    private func releaseHeavy(ctx: CombatContext) {
        let lvl = max(0, min(chargeLevel, weapon.heavy.count - 1))
        stamina.spend(weapon.stats.staminaHeavy * (1 + 0.25 * Float(lvl)), now: ctx.now)
        var strikes = [weapon.heavy[lvl]]
        let mult: Float = 1 + 0.3 * Float(chargeLevel)
        strikes[0].damage *= mult
        strikes[0].posture *= mult
        if chargeLevel > 0 && lvl == weapon.heavy.count - 1 && chargeLevel > lvl {
            strikes[0].weight = .huge
        }
        startMove(strikes, kind: .heavy(chargeLevel), ctx: ctx)
    }

    private func startAbility(ctx: CombatContext) {
        let ab = weapon.ability
        guard abilityMeter >= weapon.stats.abilityCost else { return }
        abilityMeter -= weapon.stats.abilityCost
        stats.abilityUses += 1
        ctx.emit(.ability(weapon: weapon.id, position: fighter.center))
        switch ab.kind {
        case "iaido":
            enter(.stance, ctx: ctx)
            stanceUntil = ctx.now + Double(ab.duration)
            pose("iaido_stance", ctx: ctx, inTime: 0.12, hold: Double(ab.duration), outTime: 0.15)
        case "chainPull":
            enter(.chainThrow, ctx: ctx)
            chainPhase = 0
            chainHit = false
            startMoveKeepState(ab.strikes, ctx: ctx)
        case "bloodDance":
            bloodDanceExtensions = 0
            startMove(ab.strikes, kind: .bloodDance, ctx: ctx)
        default: // earthsplitter, vault: the strikes carry leaps / hyper armor; hazards spawn on impact
            startMove(ab.strikes, kind: .ability, ctx: ctx)
        }
    }

    private func startMoveKeepState(_ strikes: [StrikeDef], ctx: CombatContext) {
        let saved = state
        startMove(strikes, kind: .ability, ctx: ctx)
        state = saved
    }

    private func startParry(ctx: CombatContext) {
        if ctx.now < parryLockUntil { return }
        enter(.parrying, ctx: ctx)
        defense.parryPressTime = ctx.now
        defense.parryHeld = parryHeld
        fighter.move = nil
        pose("parry", ctx: ctx, inTime: 0.04, hold: ctx.windows.parry, outTime: 0.1)
    }

    private func startDodge(ctx: CombatContext, keepMove: Bool) {
        let t = ctx.tuning
        guard stamina.canAct else { return }
        stamina.spend(t.player.dodgeStamina, now: ctx.now)
        let input = vlength2(moveInput) > 0.2
        dodgeDir = input ? worldMoveDir() : -fighter.forward
        dodgeDistance = input ? t.timing.dodgeDistance : t.timing.backstepDistance
        dodgeApplied = 0
        if !keepMove { fighter.move = nil; moveKind = nil }
        enter(.dodging, duration: t.timing.dodgeDuration, ctx: ctx)
        dodgeStartTime = ctx.now
        defense.dodgeStartTime = ctx.now
        stats.dodges += 1
        // Unlocked forward dodges turn the body; locked dodges keep facing the target.
        if lockTarget == nil && input { fighter.yaw = dirToYaw(dodgeDir) }
        let local = Quat.yaw(fighter.yaw).conjugate.rotate(dodgeDir)
        let name: String
        if abs(local.z) >= abs(local.x) { name = local.z >= 0 ? "dodge_f" : "dodge_b" } else { name = local.x > 0 ? "dodge_l" : "dodge_r" }
        pose(name, ctx: ctx, inTime: 0.06, hold: t.timing.dodgeDuration * 0.5, outTime: 0.18, lockFeet: true)
        ctx.emit(.whoosh(fighter: fighter.id, position: fighter.center, sound: .dagger, weight: 0.3, speed: 1.2))
    }

    private func startHeal(ctx: CombatContext) {
        guard flasks > 0 else { ctx.emit(.healEmpty); return }
        enter(.healing, duration: ctx.tuning.player.healDuration, ctx: ctx)
        healed = false
        pose("heal", ctx: ctx, inTime: 0.2, hold: ctx.tuning.player.healDuration - 0.4, outTime: 0.2)
    }

    public func swap(to index: Int, ctx: CombatContext) {
        guard index != weaponIndex, index >= 0, index < weapons.count else { return }
        if state == .attacking, let mv = fighter.move, let st = mv.strike {
            // Swap strike: swapping inside a combo window instantly strikes with the new weapon.
            let ft = mv.strikeTime * 60
            let comboF = Double(st.comboFrame >= 0 ? st.comboFrame : st.startup + st.delay + max(st.active, 1))
            if ft >= comboF {
                weaponIndex = index
                fighter.setWeapon(weapon.visual)
                ctx.emit(.swap(weapon: weapon.id))
                let strikes = weapon.swapStrike.isEmpty ? [weapon.light[0]] : weapon.swapStrike
                startMove(strikes, kind: .swapStrike, ctx: ctx)
                return
            }
        }
        guard state == .locomotion || state == .blocking else { return }
        swapTarget = index
        swapped = false
        enter(.swapping, duration: ctx.tuning.player.swapDuration, ctx: ctx)
        pose("sheathe", ctx: ctx, inTime: ctx.tuning.player.swapDuration * 0.5, hold: 0, outTime: ctx.tuning.player.swapDuration * 0.5)
    }

    private func startDeathblow(boss: BossController, ctx: CombatContext) {
        boss.receiveDeathblowStart(from: fighter, ctx: ctx)
        let strikes = weapon.deathblow.isEmpty ? [weapon.heavy[0]] : weapon.deathblow
        startMove(strikes, kind: .deathblow, ctx: ctx)
        state = .deathblow
        fighter.invulnerableUntil = ctx.now + 1.5
        if let t = lockOrNearest(ctx) { fighter.yaw = dirToYaw(t.position - fighter.position) }
    }

    // MARK: - Reactions (called by the combat system)

    /// Result of an incoming boss hit after defense resolution.
    public func receive(outcome: DefenseOutcome, strike: StrikeDef, attacker: Fighter, point: Vec3, ctx: CombatContext) {
        let t = ctx.tuning
        switch outcome {
        case .dodged(let perfect):
            if perfect { onPerfectDodge(attacker: attacker, ctx: ctx) }
        case .parried(let perfect):
            stats.parries += 1
            if perfect { stats.perfectParries += 1 }
            let post = CombatMath.playerPostureDamage(outcome: outcome, attackPosture: strike.posture, t: t.player)
            if fighter.posture.add(post, now: ctx.now) { postureBreak(ctx: ctx); return }
            abilityMeter = min(t.player.abilityMax, abilityMeter + (perfect ? t.player.abilityGainPerfectParry : t.player.abilityGainParry))
            enter(.deflecting, duration: perfect ? 0.14 : 0.24, ctx: ctx)
            fighter.move = nil
            let recoil = AnimTrack.pose(from: fighter.animator.pose, to: ctx.lib.pose("parry", grip: fighter.grip), inTime: 0.02,
                                        hold: 0.04, outTime: perfect ? 0.12 : 0.2, end: fighter.animator.stance())
            fighter.animator.play(recoil, fade: 0.02)
            fighter.animator.hitReact(dirLocal: Vec3(0, 0, 1), strength: perfect ? 0.3 : 0.7)
            if perfect {
                lastPerfectParry = ctx.now
                onPerfectParry(attacker: attacker, strike: strike, ctx: ctx)
            }
            fighter.position -= attackerDir(attacker) * (perfect ? 0.05 : 0.2)
        case .blocked:
            stats.blocks += 1
            let post = CombatMath.playerPostureDamage(outcome: outcome, attackPosture: strike.posture, t: t.player)
            let dmg = CombatMath.playerHealthDamage(outcome: outcome, attackDamage: strike.damage, t: t.player)
            takeDamage(dmg, ctx: ctx)
            if fighter.posture.add(post, now: ctx.now) { postureBreak(ctx: ctx); return }
            enter(.blockstun, duration: 0.22 + Double(strike.weight == .heavy || strike.weight == .huge ? 0.12 : 0), ctx: ctx)
            fighter.animator.hitReact(dirLocal: Vec3(0, 0, 1), strength: 0.8)
            fighter.knockback = attackerDir(attacker) * (0.35 + strike.knockback * 0.3)
        case .hit:
            if invincible { return }
            stats.hitsTaken += 1
            takeDamage(strike.damage, ctx: ctx)
            fighter.lastHitTime = ctx.now
            fighter.invulnerableUntil = ctx.now + t.timing.hitInvulnerability
            let post = CombatMath.playerPostureDamage(outcome: .hit, attackPosture: strike.posture, t: t.player)
            _ = fighter.posture.add(post, now: ctx.now)
            fighter.move = nil
            if fighter.health <= 0 { die(ctx: ctx); return }
            if strike.hitbox == .grab {
                enter(.grabbed, ctx: ctx)
                grabbedUntil = ctx.now + Double(strike.grabHold)
                grabDamage = strike.damage * 0.8
                grabAttacker = attacker
                pose("grabbed", ctx: ctx, inTime: 0.1, hold: Double(strike.grabHold), outTime: 0.2)
                ctx.emit(.grab(position: point))
                return
            }
            let stun: Double
            switch strike.weight {
            case .light: stun = 0.32
            case .medium: stun = 0.45
            case .heavy: stun = 0.62
            case .huge: stun = 0.85
            }
            enter(.hitstun, duration: stun, ctx: ctx)
            let dirLocal = Quat.yaw(fighter.yaw).conjugate.rotate(-attackerDir(attacker))
            fighter.animator.hitReact(dirLocal: dirLocal, strength: 1.2)
            pose("hit", ctx: ctx, inTime: 0.05, hold: stun * 0.4, outTime: stun * 0.5)
            fighter.knockback = attackerDir(attacker) * (0.6 + strike.knockback)
            fighter.hitFlash = 1
            fighter.flashColor = Vec3(1, 0.25, 0.2)
        case .counter:
            // Katana Iaido auto-counter.
            let ab = weapon.ability
            fighter.invulnerableUntil = ctx.now + 0.8
            ctx.emit(.counter(position: fighter.center))
            ctx.slowMotion(duration: 0.35, scale: 0.35)
            startMove(ab.strikes, kind: .counter, speedMul: 1.3, ctx: ctx)
            if let boss = ctx.boss(for: attacker) { boss.interrupt(stagger: 0.9, ctx: ctx) }
        case .ignored:
            break
        }
    }

    private func attackerDir(_ a: Fighter) -> Vec3 { vnormalize(vflat(fighter.position - a.position), fallback: -fighter.forward) }

    private func takeDamage(_ d: Float, ctx: CombatContext) {
        if invincible || d <= 0 { return }
        fighter.applyDamage(d)
        stats.damageTaken += d
        if fighter.health <= 0 { die(ctx: ctx) }
    }

    private func postureBreak(ctx: CombatContext) {
        enter(.postureBroken, duration: ctx.tuning.player.postureBreakStagger, ctx: ctx)
        fighter.move = nil
        pose("stagger", ctx: ctx, inTime: 0.12, hold: ctx.tuning.player.postureBreakStagger - 0.3, outTime: 0.2)
        ctx.emit(.postureBreak(target: fighter.id, position: fighter.center, isPlayer: true))
        ctx.hitstop(ctx.tuning.hitstop.postureBreak)
    }

    private func die(ctx: CombatContext) {
        guard state != .dead else { return }
        enter(.dead, ctx: ctx)
        fighter.dead = true
        fighter.move = nil
        let p = ctx.lib.pose("dead", grip: fighter.grip)
        fighter.animator.play(AnimTrack(keys: [AnimTrack.Key(0, fighter.animator.pose, .linear), AnimTrack.Key(0.7, p, .outQuad), AnimTrack.Key(30, p, .linear)],
                                        lockFeet: true), fade: 0.05)
        ctx.emit(.death(fighter: fighter.id, position: fighter.center, isPlayer: true))
    }

    private func onPerfectDodge(attacker: Fighter, ctx: CombatContext) {
        let t = ctx.tuning
        stats.perfectDodges += 1
        lastPerfectDodge = ctx.now
        abilityMeter = min(t.player.abilityMax, abilityMeter + t.player.abilityGainPerfectDodge)
        ctx.slowMotion(duration: t.timing.perfectDodgeSlowDuration, scale: t.timing.perfectDodgeTimeScale)
        ctx.emit(.dodged(perfect: true, position: fighter.center))
        ctx.emit(.afterimage(fighter: fighter.id))
        switch weapon.perfectDodgeBonus {
        case "counterSlash":
            if !weapon.counter.isEmpty { startMove(weapon.counter, kind: .counter, speedMul: 1.2, ctx: ctx) }
        case "instantCharge":
            instantCharge = true
        case "invisibility":
            fighter.visibility = 0.25
            ctx.boss(for: attacker)?.confuse(until: ctx.now + 1.0, decoy: fighter.position)
        case "autoLunge":
            if !weapon.counter.isEmpty { startMove(weapon.counter, kind: .counter, speedMul: 1.1, ctx: ctx) }
        case "chainLash":
            if let boss = ctx.boss(for: attacker), vlength(vflat(attacker.position - fighter.position)) < 6.5 {
                boss.receiveBonusHit(damage: 14 * weapon.stats.damage, posture: 18, from: fighter, ctx: ctx)
                ctx.emit(.chainHit(position: attacker.center))
            }
        default: break
        }
    }

    private func onPerfectParry(attacker: Fighter, strike: StrikeDef, ctx: CombatContext) {
        guard let boss = ctx.boss(for: attacker) else { return }
        switch weapon.perfectParryBonus {
        case "doublePosture":
            nextPostureMult = 2
        case "stagger":
            boss.interrupt(stagger: 0.7, ctx: ctx)
        case "riposte":
            if !weapon.riposte.isEmpty { startMove(weapon.riposte, kind: .riposte, speedMul: 1.15, ctx: ctx) }
        case "pushback":
            boss.push(from: fighter.position, distance: 2.4, ctx: ctx)
            boss.interrupt(stagger: 0.6, ctx: ctx)
            if !weapon.riposte.isEmpty { startMove(weapon.riposte, kind: .riposte, ctx: ctx) }
        case "disarm":
            boss.disarm(duration: 2.0, ctx: ctx)
            ctx.emit(.disarm(position: attacker.center))
        default: break
        }
    }

    /// Called when one of the player's hits connects.
    public func onHitLanded(target: Fighter, strike: StrikeDef, ctx: CombatContext) {
        abilityMeter = min(ctx.tuning.player.abilityMax, abilityMeter + ctx.tuning.player.abilityGainHit)
    }

    // MARK: - Update

    public func worldMoveDir() -> Vec3 {
        let f = yawToDir(cameraYaw)
        let r = Vec3(-f.z, 0, f.x)
        return vnormalize(f * moveInput.y + r * moveInput.x, fallback: fighter.forward)
    }

    public func step(dt: Double, ctx: CombatContext) {
        let t = ctx.tuning
        let fdt = Float(dt)
        stateTime += dt
        stats.time += dt
        stamina.regen(dt: dt, now: ctx.now, rate: t.player.staminaRegen, delay: t.player.staminaRegenDelay)
        let guarding = state == .blocking
        fighter.posture.recover(dt: dt, now: ctx.now, delay: t.player.postureRecoverDelay, rate: t.player.postureRecoverRate,
                                healthFraction: fighter.healthFraction, boost: guarding ? 1.6 : 1)
        fighter.visibility = min(1, fighter.visibility + Float(dt) * 1.2)
        if let l = lockTarget, l.dead { lockTarget = nil }
        buffer.window = t.timing.inputBuffer

        var desiredVel = Vec3.zero
        var running = false
        switch state {
        case .dead:
            break
        case .locomotion, .blocking, .charging:
            let input = vlength2(moveInput)
            if input > 0.05 {
                let dir = worldMoveDir()
                var speed: Float
                if lockTarget != nil { speed = t.player.lockedMoveSpeed } else { speed = input > 0.6 ? t.player.runSpeed : t.player.walkSpeed; running = input > 0.6 }
                if state == .blocking { speed *= 0.45 }
                if state == .charging { speed *= 0.3 }
                desiredVel = dir * speed * min(1, input)
            }
            // Facing.
            if let l = lockTarget {
                fighter.yaw = approachAngle(fighter.yaw, dirToYaw(l.position - fighter.position), t.player.turnRate * kDeg2Rad * fdt)
            } else if input > 0.05 && state == .locomotion {
                fighter.yaw = approachAngle(fighter.yaw, dirToYaw(desiredVel), t.player.turnRate * kDeg2Rad * fdt)
            }
            if state == .charging {
                charge += fdt
                let lvl = Int(charge / weapon.stats.chargeTime)
                let newLevel = min(lvl, max(0, weapon.stats.chargeLevels - 1))
                if newLevel > chargeLevel { chargeLevel = newLevel; ctx.emit(.ability(weapon: "charge\(newLevel)", position: fighter.center)) }
                if !heavyHeld || charge > weapon.stats.chargeTime * Float(weapon.stats.chargeLevels) + 0.5 { releaseHeavy(ctx: ctx) }
            }
        case .attacking, .deathblow, .chainThrow:
            if let mv = fighter.move {
                let tgt = lockOrNearest(ctx).map { $0.position }
                let events = mv.step(dt: dt, fighter: fighter, target: tgt, lib: ctx.lib)
                for e in events {
                    if case .activeBegan = e, let st = mv.strike {
                        ctx.emit(.whoosh(fighter: fighter.id, position: fighter.weapon.trailTipWorld, sound: fighter.weapon.type.sound,
                                         weight: fighter.weapon.type.weight, speed: weapon.stats.speed))
                        if st.hyperArmor { fighter.hyperArmor = true }
                        if st.invulnerable { fighter.invulnerableUntil = max(fighter.invulnerableUntil, ctx.now + st.activeTime + 0.1) }
                        handleAbilityImpact(st, ctx: ctx)
                    }
                    if case .strikeBegan(let i) = e, i < mv.timeline.strikes.count {
                        let st = mv.timeline.strikes[i]
                        if st.invulnerable { fighter.invulnerableUntil = max(fighter.invulnerableUntil, ctx.now + st.startupTime + st.activeTime) }
                        if st.hyperArmor { fighter.hyperArmor = true }
                        if st.hitbox != .none { fighter.weapon.chainExtension = 0 }
                    }
                }
                // Flexible weapons extend during the active phase.
                if fighter.weapon.type.flex != nil {
                    let target: Float = (mv.phase == .active || (mv.phase == .startup && mv.timeline.timeToActive < 0.06)) ? 1 : 0
                    fighter.weapon.chainExtension = approachf(fighter.weapon.chainExtension, target, fdt * (target > 0 ? 9 : 4))
                }
                if state == .chainThrow { updateChainPull(mv: mv, ctx: ctx) }
                if mv.isDone {
                    fighter.move = nil
                    moveKind = nil
                    fighter.hyperArmor = false
                    enter(.locomotion, ctx: ctx)
                }
            } else {
                enter(.locomotion, ctx: ctx)
            }
        case .dodging:
            let u = Float(min(1, stateTime / max(stateDuration * 0.8, 1e-3)))
            let target = dodgeDistance * Ease.outQuad.apply(u)
            fighter.position += dodgeDir * (target - dodgeApplied)
            dodgeApplied = target
            if stateTime >= stateDuration { enter(.locomotion, ctx: ctx) }
            if let mv = fighter.move, case .bloodDance = moveKind ?? .ability, stateTime >= 0.22 {
                // Resume the blood dance after the dodge.
                enter(.attacking, ctx: ctx)
                _ = mv
            }
        case .parrying:
            if let tp = defense.parryPressTime, ctx.now - tp > ctx.windows.parry {
                if parryHeld {
                    enter(.blocking, ctx: ctx)
                    defense.parryHeld = true
                    let bp = ctx.lib.pose("block", grip: fighter.grip)
                    fighter.animator.play(AnimTrack(keys: [AnimTrack.Key(0, fighter.animator.pose, .linear), AnimTrack.Key(0.1, bp, .outQuad),
                                                           AnimTrack.Key(3600, bp, .linear)]), fade: 0.03)
                } else {
                    // Whiffed: short vulnerable recovery, and the parry button locks briefly.
                    enter(.parryWhiff, duration: t.timing.parryWhiffRecovery, ctx: ctx)
                    parryLockUntil = ctx.now + t.timing.parryWhiffRecovery + t.timing.parrySpamCooldown
                }
            }
        case .deflecting, .blockstun, .hitstun, .parryWhiff, .postureBroken:
            if stateTime >= stateDuration {
                if state == .blockstun && parryHeld {
                    enter(.blocking, ctx: ctx)
                    defense.parryHeld = true
                } else {
                    enter(.locomotion, ctx: ctx)
                }
            }
        case .healing:
            if !healed && stateTime >= t.player.healHealTime {
                healed = true
                flasks -= 1
                stats.heals += 1
                fighter.health = min(fighter.maxHealth, fighter.health + t.player.healAmount)
                ctx.emit(.heal(position: fighter.center))
            }
            desiredVel = worldMoveDir() * t.player.walkSpeed * 0.35 * min(1, vlength2(moveInput))
            if stateTime >= stateDuration { enter(.locomotion, ctx: ctx) }
        case .swapping:
            if !swapped && stateTime >= stateDuration * 0.5 {
                swapped = true
                weaponIndex = swapTarget
                fighter.setWeapon(weapon.visual)
                ctx.emit(.swap(weapon: weapon.id))
            }
            if stateTime >= stateDuration { enter(.locomotion, ctx: ctx) }
        case .grabbed:
            if ctx.now >= grabbedUntil {
                takeDamage(grabDamage, ctx: ctx)
                if let a = grabAttacker { fighter.knockback = attackerDir(a) * 2.2 }
                if fighter.health > 0 { enter(.hitstun, duration: 0.6, ctx: ctx) }
                ctx.shake(0.5)
                ctx.emit(.hit(attacker: grabAttacker?.id ?? 0, target: fighter.id, point: fighter.center, dir: fighter.forward,
                              weight: .heavy, damage: grabDamage, playerVictim: true, element: .none, sound: .blunt))
            } else if let a = grabAttacker {
                // Held in front of the attacker.
                let hold = a.position + a.forward * (a.radius + fighter.radius + 0.25)
                fighter.position = vdamp(fighter.position, hold, 18, fdt)
                fighter.yaw = dirToYaw(a.position - fighter.position)
            }
        case .stance:
            if ctx.now >= stanceUntil { enter(.locomotion, ctx: ctx); fighter.animator.stop() }
        }

        // Velocity integration with acceleration (locomotion) and knockback.
        let accel = t.player.acceleration * fdt
        let flatVel = vflat(fighter.velocity)
        let dv = desiredVel - flatVel
        let step = vlength(dv) > accel ? vnormalize(dv) * accel : dv
        fighter.velocity = flatVel + step
        if state != .locomotion && state != .blocking && state != .charging && state != .healing { fighter.velocity = .zero }
        fighter.position += fighter.velocity * fdt
        if vlengthSq(fighter.knockback) > 1e-6 {
            let k = fighter.knockback * min(1, fdt * 10)
            fighter.position += k
            fighter.knockback -= k
        }
        fighter.position = ctx.clampToArena(fighter.position, margin: fighter.radius)
        if state != .attacking && state != .deathblow && state != .chainThrow { fighter.position.y = 0 }

        tryConsumeBuffer(ctx: ctx)
        fighter.updateAnimation(dt: fdt, running: running)
        fighter.hitFlash = max(0, fighter.hitFlash - fdt * 6)
    }

    // MARK: - Abilities on impact

    private func handleAbilityImpact(_ st: StrikeDef, ctx: CombatContext) {
        guard let kind = moveKind else { return }
        let ab = weapon.ability
        switch kind {
        case .ability where ab.kind == "earthsplitter":
            // Crack line of delayed bursts along the facing direction.
            let fwd = fighter.forward
            let n = max(3, Int(ab.range / 1.1))
            for k in 0..<n {
                let p = fighter.position + fwd * (1.2 + Float(k) * 1.1)
                ctx.spawnHazard(Hazard(owner: fighter.id, center: p, radius: 1.0, delay: Double(k) * 0.045, damage: ab.damage,
                                       posture: ab.posture, telegraph: .none, element: .none, weight: .heavy, ownerIsPlayer: true))
            }
            ctx.emit(.crack(from: fighter.position + fwd, to: fighter.position + fwd * (1.2 + Float(n) * 1.1), element: .none))
            ctx.shake(0.6)
        case .ability where ab.kind == "vault":
            if st.aoeRadius > 0 {
                ctx.spawnHazard(Hazard(owner: fighter.id, center: fighter.position + fighter.forward * 0.8, radius: st.aoeRadius, delay: 0,
                                       damage: ab.damage, posture: ab.posture, telegraph: .none, element: .none, weight: .heavy, ownerIsPlayer: true))
                ctx.emit(.landing(position: fighter.position, weight: 1))
            }
        default:
            break
        }
    }

    private func updateChainPull(mv: MoveRunner, ctx: CombatContext) {
        let ab = weapon.ability
        guard !chainHit, mv.phase == .active, let tgt = lockOrNearest(ctx), let boss = ctx.boss(for: tgt) else { return }
        let to = vflat(tgt.position - fighter.position)
        let dist = vlength(to)
        let ang = abs(angleDelta(fighter.yaw, dirToYaw(to)))
        if dist <= ab.range && ang < 0.6 {
            chainHit = true
            ctx.emit(.chainHit(position: tgt.center))
            boss.pulled(toward: fighter.position + fighter.forward * (fighter.radius + tgt.radius + 1.0), ctx: ctx)
            boss.receiveBonusHit(damage: ab.damage * weapon.stats.damage, posture: ab.posture, from: fighter, ctx: ctx)
        }
    }
}
