// Fighter: shared runtime state for the player and bosses — body, animation, weapons,
// health/posture, hurtboxes, and the move runner that plays attacks with synchronized
// animation, root motion, leaps, spins and target tracking.
import Foundation

public enum HurtRegion: String { case head, torso, armL, armR, legL, legR }

/// A weapon held by a fighter (mesh, materials, hitboxes, flexible chain state).
public final class WeaponInstance {
    public let visual: WeaponVisual
    public let type: WeaponType
    public let mesh: MeshData
    public var materials: [MaterialDesc]
    public let flexHead: MeshData?
    public let linkMesh: MeshData?
    public let chain: VerletChain?
    /// 0 = dangling, 1 = fully extended (flexible weapons).
    public var chainExtension: Float = 0
    public var glow: Float = 0
    public private(set) var frame = BoneXform()
    public private(set) var prevFrame = BoneXform()
    public private(set) var framesValid = false
    public let isLeft: Bool

    public init(visual: WeaponVisual, isLeft: Bool = false) {
        self.visual = visual
        self.isLeft = isLeft
        type = WeaponCatalog.get(visual.type)
        mesh = WeaponCatalog.mesh(visual)
        materials = WeaponCatalog.materials(visual)
        glow = visual.glowStrength
        if let f = type.flex {
            flexHead = WeaponCatalog.flexHeadMesh(visual, head: f.head, radius: f.headRadius * visual.scale)
            linkMesh = WeaponCatalog.chainLinkMesh(rope: visual.type == "meteor_hammer")
            chain = VerletChain(count: f.links, segment: f.restLength / Float(f.links), start: .zero)
        } else {
            flexHead = nil; linkMesh = nil; chain = nil
        }
    }

    public func setFrame(_ f: BoneXform) {
        prevFrame = framesValid ? frame : f
        frame = f
        framesValid = true
    }

    public func invalidate() { framesValid = false }

    /// World-space hit capsules at a given frame (reach multiplies distance along the blade).
    public func capsules(at f: BoneXform, reach: Float) -> [Capsule] {
        if type.flex != nil, let ch = chain {
            // Flexible: capsule from the hand along the chain to the head, plus the head.
            let head = ch.head
            var caps = [Capsule(f.pos, head, 0.05 * visual.scale), Capsule(head, head, (type.flex?.headRadius ?? 0.12) * visual.scale)]
            for hb in type.hitboxes {
                caps.append(Capsule(f.transform(hb.a * visual.scale), f.transform(hb.b * visual.scale), hb.radius * visual.scale))
            }
            return caps
        }
        return type.hitboxes.map { hb in
            Capsule(f.transform(hb.a * visual.scale * Vec3(1, 1, reach)), f.transform(hb.b * visual.scale * Vec3(1, 1, reach)), hb.radius * visual.scale)
        }
    }

    public var trailBaseWorld: Vec3 {
        if type.flex != nil, let ch = chain { return ch.points[max(0, ch.points.count - 3)] }
        return frame.transform(type.trailBase * visual.scale)
    }
    public var trailTipWorld: Vec3 {
        if type.flex != nil, let ch = chain { return ch.head }
        return frame.transform(type.trailTip * visual.scale)
    }

    /// Updates the flexible chain: extended toward the blade direction while striking.
    public func updateFlex(dt: Float, reachMul: Float) {
        guard let f = type.flex, let ch = chain else { return }
        let len = (f.restLength + (f.chainLength * reachMul - f.restLength) * chainExtension) * visual.scale
        let seg = len / Float(max(f.links - 1, 1))
        let dir = frame.rot.rotate(Vec3(0, 0, 1))
        let tip: Vec3? = chainExtension > 0.05 ? frame.pos + dir * len : nil
        ch.step(dt: dt, root: frame.pos, tip: tip, tipStrength: chainExtension > 0.05 ? min(1, 0.35 + chainExtension * 0.65) : 0, segmentLength: seg)
    }
}

/// Runtime playback of an attack: strike timeline + animation + root motion.
public final class MoveRunner {
    public private(set) var timeline: StrikeTimeline
    public let tag: String
    public let attackId: Int
    public var hitTargets: Set<Int> = []
    public var multiHitTimer: Double = 0
    public var burstDone = false
    public var interrupted = false
    private var startYaw: Float = 0
    private var spinApplied: Float = 0
    private var moveApplied: Float = 0
    private var lateralApplied: Float = 0
    private var baseY: Float = 0
    private static var nextId = 1
    public var reach: Float = 1
    public var trackingScale: Float = 1

    public init(strikes: [StrikeDef], speed: Double, tag: String) {
        timeline = StrikeTimeline(strikes: strikes, speed: speed)
        self.tag = tag
        attackId = MoveRunner.nextId
        MoveRunner.nextId += 1
    }

    public var strike: StrikeDef? { timeline.current }

    /// Releases a counter-stance strike immediately.
    public func releaseCounter() { timeline.skipToActive() }
    public var phase: StrikeTimeline.Phase { timeline.phase }
    public var isDone: Bool { timeline.isDone }
    public var isActive: Bool { timeline.phase == .active }

    /// Time (seconds, unscaled by speed) into the current strike.
    public var strikeTime: Double { timeline.time }

    /// Advances the move, applying root motion to the fighter. Returns timeline events.
    public func step(dt: Double, fighter: Fighter, target: Vec3?, lib: AnimLibrary) -> [StrikeTimeline.Event] {
        let events = timeline.advance(dt)
        for e in events {
            switch e {
            case .strikeBegan(let i):
                beginStrike(i, fighter: fighter, lib: lib)
            default: break
            }
        }
        guard let st = timeline.current else { return events }
        let S = st.startupTime, A = st.activeTime
        let t = timeline.time
        // Tracking toward the target during startup.
        if let tg = target, t < S {
            let want = dirToYaw(tg - fighter.position)
            let maxTurn = st.tracking * kDeg2Rad * Float(dt * timeline.speed) * trackingScale
            fighter.yaw = approachAngle(fighter.yaw, want, maxTurn)
        }
        // Root motion: forward / lateral over [S - pre, S + A].
        let pre = min(0.05, S * 0.25)
        let m0 = S - pre, m1 = S + A
        let u = Float(clampd((t - m0) / max(m1 - m0, 1e-3), 0, 1))
        let e = Ease.outQuad.apply(u)
        let fwd = yawToDir(fighter.yaw)
        let right = Vec3(-fwd.z, 0, fwd.x)
        let moveTarget = st.move * e
        let latTarget = st.lateral * e
        fighter.position += fwd * (moveTarget - moveApplied) + right * (latTarget - lateralApplied)
        moveApplied = moveTarget
        lateralApplied = latTarget
        // Leap arc.
        if st.leap > 0 {
            let l0 = S * 0.35, l1 = S + A * 0.5
            let lu = Float(clampd((t - l0) / max(l1 - l0, 1e-3), 0, 1))
            fighter.position.y = baseY + 4 * st.leap * lu * (1 - lu)
        }
        // Spin during the active phase.
        if st.spin != 0 {
            let su = Float(clampd((t - S) / A, 0, 1))
            let target = st.spin * kDeg2Rad * su
            fighter.yaw = wrapAngle(fighter.yaw + (target - spinApplied))
            spinApplied = target
        }
        return events
    }

    private func beginStrike(_ i: Int, fighter: Fighter, lib: AnimLibrary) {
        guard i < timeline.strikes.count else { return }
        let st = timeline.strikes[i]
        hitTargets.removeAll()
        multiHitTimer = 0
        burstDone = false
        spinApplied = 0
        moveApplied = 0
        lateralApplied = 0
        startYaw = fighter.yaw
        baseY = 0
        if st.swapWeapon >= 0 { fighter.switchWeapon(st.swapWeapon) }
        let grip = fighter.grip
        let keys = lib.strike(st.anim, grip: grip, side: st.side)
        let track = AnimTrack.strike(st, keys: keys, from: fighter.animator.pose, to: fighter.animator.stance(),
                                     recovery: timeline.recoveryDuration(i))
        fighter.animator.play(track, fade: 0.035, speed: timeline.speed)
        fighter.animator.tremble = st.delay > 0 || st.feint ? 1 : 0
    }
}

public final class Fighter {
    public let id: Int
    public let isPlayer: Bool
    public var name: String
    public var title: String = ""
    public var position: Vec3 = .zero
    public var yaw: Float = 0
    public var velocity: Vec3 = .zero
    public var radius: Float
    public let skeleton: Skeleton
    public let animator: CharacterAnimator
    public private(set) var mesh: MeshData
    public var materials: [MaterialDesc]
    public var cape: ClothSim?
    public var capeIsScarf = false
    public var weaponSlots: [WeaponVisual]
    public private(set) var weapon: WeaponInstance
    public private(set) var offhand: WeaponInstance?
    public private(set) var weaponSlot = 0
    public var health: Float
    public var maxHealth: Float
    public var posture: PostureMeter
    public var hitFlash: Float = 0
    public var flashColor = Vec3(1, 1, 1)
    public var invulnerableUntil: Double = -1
    public var bleedStacks = 0
    public var bleedUntil: Double = 0
    public var bleedTick: Double = 0
    public var dead = false
    public var visibility: Float = 1        // < 1: afterimage / invisibility
    public var move: MoveRunner?
    public var hyperArmor = false
    public var knockback = Vec3.zero
    public var glow: Float = 0              // runes / eyes intensity multiplier
    public var elementGlow: Element = .none
    public var height: Float
    public var lastHitTime: Double = -100
    public var prevPalette: [Mat4] = []
    public var prevWorld = Mat4.identity

    private static var nextId = 1

    public init(isPlayer: Bool, name: String, visual: CharacterVisual, weapons: [WeaponVisual], maxHealth: Float, maxPosture: Float,
                radius: Float, lib: AnimLibrary, quality: Float = 1) {
        id = Fighter.nextId
        Fighter.nextId += 1
        self.isPlayer = isPlayer
        self.name = name
        self.radius = radius
        let sk = Skeleton(visual.body)
        skeleton = sk
        height = visual.body.height
        let built = timed("character mesh \(name)", "load") { CharacterBuilder.build(visual, skeleton: sk, quality: quality) }
        mesh = built.mesh
        materials = built.materials
        weaponSlots = weapons.isEmpty ? [WeaponVisual()] : weapons
        weapon = WeaponInstance(visual: weaponSlots[0])
        self.maxHealth = maxHealth
        health = maxHealth
        posture = PostureMeter(max: maxPosture)
        animator = CharacterAnimator(skeleton: skeleton, library: lib, grip: weapon.type.grip, twoHandOffset: weapon.type.twoHandOffset)
        glow = visual.eyeGlow
        if let c = built.cape {
            let cols = c.isScarf ? 3 : 8
            let rows = c.isScarf ? 12 : 12
            cape = ClothSim(cols: cols, rows: rows, width: c.width, length: c.length, tattered: c.tattered, material: c.material,
                            seed: Rng.hash(name))
            capeIsScarf = c.isScarf
        }
        setupOffhand()
    }

    public var grip: GripStyle { weapon.type.grip }

    private func setupOffhand() {
        if let off = weapon.type.offhand {
            var v = WeaponVisual(type: off)
            v.metal = weapon.visual.metal; v.trim = weapon.visual.trim; v.handle = weapon.visual.handle
            v.glow = weapon.visual.glow; v.glowStrength = weapon.visual.glowStrength; v.element = weapon.visual.element
            offhand = WeaponInstance(visual: v, isLeft: true)
        } else if weapon.type.mirrorOffhand {
            offhand = WeaponInstance(visual: weapon.visual, isLeft: true)
        } else {
            offhand = nil
        }
    }

    /// Replaces the active weapon (player weapon swaps, boss weapon changes).
    public func setWeapon(_ v: WeaponVisual) {
        weapon = WeaponInstance(visual: v)
        setupOffhand()
        animator.grip = weapon.type.grip
        animator.twoHandOffset = weapon.type.twoHandOffset
    }

    public func switchWeapon(_ slot: Int) {
        guard slot >= 0, slot < weaponSlots.count, slot != weaponSlot else { return }
        weaponSlot = slot
        setWeapon(weaponSlots[slot])
    }

    public var healthFraction: Float { maxHealth > 0 ? health / maxHealth : 0 }
    public var forward: Vec3 { yawToDir(yaw) }
    public var center: Vec3 { position + Vec3(0, height * 0.55, 0) }
    public var headPosition: Vec3 { animator.boneWorld(.head) + Vec3(0, 0.08 * skeleton.scale, 0) }

    /// Advances animation + attached simulations and captures weapon frames for sweeps.
    public func updateAnimation(dt: Float, running: Bool) {
        animator.update(dt: dt, position: position, yaw: yaw, velocity: velocity, running: running)
        weapon.setFrame(animator.weaponRWorld)
        if let off = offhand {
            if grip == .shield {
                off.setFrame(animator.offhandWorld)
            } else {
                off.setFrame(animator.weaponLWorld)
            }
        }
        let reach = move?.reach ?? 1
        weapon.updateFlex(dt: dt, reachMul: reach)
        offhand?.updateFlex(dt: dt, reachMul: reach)
    }

    /// Cloth is stepped at render rate (cheaper, and visually identical).
    public func updateCloth(dt: Float) {
        guard let c = cape else { return }
        let chest = animator.boneXformWorld(.spine2)
        let neck = animator.boneXformWorld(.neck)
        let s = skeleton.scale * skeleton.proportions.bulk
        var pins: [Vec3] = []
        if capeIsScarf {
            let base = neck.pos + neck.rot.rotate(Vec3(0.05, -0.02, -0.07) * s)
            for k in 0..<c.cols { pins.append(base + chest.rot.rotate(Vec3(Float(k) * 0.05 - 0.05, 0, 0) * s)) }
        } else {
            for k in 0..<c.cols {
                let t = Float(k) / Float(max(c.cols - 1, 1)) - 0.5
                pins.append(chest.pos + chest.rot.rotate(Vec3(t * 0.42 * s, 0.2 * skeleton.scale, -0.15 * s - abs(t) * 0.02)))
            }
        }
        // Body colliders keep the cloth off the back and legs.
        c.colliders = [
            Capsule(animator.boneWorld(.pelvis), animator.boneWorld(.spine2) + Vec3(0, 0.1, 0), 0.17 * s),
            Capsule(animator.boneWorld(.thighL), animator.boneWorld(.shinL), 0.09 * s),
            Capsule(animator.boneWorld(.thighR), animator.boneWorld(.shinR), 0.09 * s),
            Capsule(animator.boneWorld(.shinL), animator.boneWorld(.footL), 0.06 * s),
            Capsule(animator.boneWorld(.shinR), animator.boneWorld(.footR), 0.06 * s),
        ]
        c.wind = -velocity * 0.9 + Vec3(0.4, 0, 0.2)
        c.step(dt: dt, pins: pins, down: Vec3(0, -1, 0))
    }

    /// Hurtboxes per body region (world space).
    public func hurtboxes() -> [(HurtRegion, Capsule)] {
        let s = skeleton.scale * max(0.8, skeleton.proportions.bulk)
        func b(_ x: Bone) -> Vec3 { animator.boneWorld(x) }
        let headTop = b(.head) + (b(.head) - b(.neck)) * 0.9
        return [
            (.head, Capsule(b(.neck), headTop, 0.11 * s)),
            (.torso, Capsule(b(.pelvis), b(.spine2) + (b(.neck) - b(.spine2)) * 0.6, 0.2 * s)),
            (.armL, Capsule(b(.upperArmL), b(.handL), 0.07 * s)),
            (.armR, Capsule(b(.upperArmR), b(.handR), 0.07 * s)),
            (.legL, Capsule(b(.thighL), b(.footL), 0.09 * s)),
            (.legR, Capsule(b(.thighR), b(.footR), 0.09 * s)),
        ]
    }

    /// Body capsule used for body-hitbox attacks (charges, bashes) and separation.
    public func bodyCapsule(inflate: Float = 0) -> Capsule {
        Capsule(position + Vec3(0, radius, 0), position + Vec3(0, max(height - radius, radius), 0), radius + inflate)
    }

    public func applyDamage(_ amount: Float) {
        health = max(0, health - amount)
    }
}
