// Runtime animation for one character: stance + procedural locomotion (feet step to keep
// up with the body in any direction), action tracks (attacks, dodges, parries...) with
// crossfades, and procedural additive layers (breathing, hit reactions, look-at).
import Foundation

public final class CharacterAnimator {
    public let skeleton: Skeleton
    public let library: AnimLibrary
    public var grip: GripStyle
    public var twoHandOffset: Float

    // Body placement (world).
    public private(set) var position: Vec3 = .zero
    public private(set) var yaw: Float = 0

    // Action track state.
    public private(set) var track: AnimTrack?
    public private(set) var trackTime: Double = 0
    public var trackSpeed: Double = 1
    private var fadeFrom: RigPose?
    private var fadeTime: Float = 0
    private var fadeDuration: Float = 0.1
    public private(set) var currentRig = RigPose()

    // Locomotion.
    private struct Foot {
        var planted: Vec3 = .zero
        var from: Vec3 = .zero
        var to: Vec3 = .zero
        var t: Float = 0
        var duration: Float = 0.3
        var stepping = false
        var lift: Float = 0
    }
    private var feet = [Foot(), Foot()]
    private var initialized = false
    private var moveSpeedSmoothed: Float = 0
    private var localVelSmoothed: Vec3 = .zero
    private var gaitPhase: Float = 0

    // Additive layers.
    private var hitPitch = SpringFloat(0)
    private var hitRoll = SpringFloat(0)
    private var hitPitchTarget: Float = 0
    private var hitRollTarget: Float = 0
    private var breathPhase: Float = 0
    public var lookTarget: Vec3?
    public var breathing: Float = 1
    /// Extra tremble while holding a delayed windup (purple telegraphs).
    public var tremble: Float = 0
    private var trembleT: Float = 0

    /// Increments whenever a foot lands (footstep sounds / dust).
    public private(set) var footstepCount = 0
    public private(set) var lastFootstep = Vec3.zero

    // Outputs.
    public private(set) var result: RigResult
    public private(set) var worldMatrix: Mat4 = .identity
    /// Previous weapon frames (world) for swept hit detection and trails.
    public private(set) var weaponRWorld = BoneXform()
    public private(set) var weaponLWorld = BoneXform()
    public private(set) var offhandWorld = BoneXform()

    public init(skeleton: Skeleton, library: AnimLibrary, grip: GripStyle, twoHandOffset: Float) {
        self.skeleton = skeleton
        self.library = library
        self.grip = grip
        self.twoHandOffset = twoHandOffset
        currentRig = library.stance(grip)
        result = Rig.solve(currentRig, skeleton: skeleton, grip: grip, twoHandOffset: twoHandOffset)
    }

    // MARK: - Actions

    /// Starts an action track, crossfading from the current pose.
    public func play(_ t: AnimTrack, fade: Float = 0.06, speed: Double = 1) {
        fadeFrom = currentRig
        fadeTime = 0
        fadeDuration = fade
        track = t
        trackTime = 0
        trackSpeed = speed
    }

    /// Stops the current action and blends back to locomotion.
    public func stop(fade: Float = 0.12) {
        guard track != nil else { return }
        fadeFrom = currentRig
        fadeTime = 0
        fadeDuration = fade
        track = nil
    }

    public var isPlaying: Bool { track != nil }

    public func stance() -> RigPose { library.stance(grip) }

    /// Snapshot of the currently displayed rig pose (used as the start of the next action).
    public var pose: RigPose { currentRig }

    // MARK: - Reactions

    /// Directional flinch. `dirLocal` is the hit direction in the character's local frame.
    public func hitReact(dirLocal: Vec3, strength: Float) {
        hitPitchTarget = clampf(dirLocal.z * 0.35 * strength, -0.5, 0.5)
        hitRollTarget = clampf(-dirLocal.x * 0.3 * strength, -0.45, 0.45)
        hitPitch.velocity += dirLocal.z * 6 * strength
        hitRoll.velocity += -dirLocal.x * 5 * strength
    }

    public func teleport(position p: Vec3, yaw y: Float) {
        position = p; yaw = y
        initialized = false
    }

    // MARK: - Update

    /// Advances animation. `velocity` is the world-space body velocity (for locomotion).
    public func update(dt: Float, position p: Vec3, yaw y: Float, velocity: Vec3, running: Bool) {
        position = p
        yaw = y
        let rotY = Quat.yaw(y)
        if !initialized {
            let st = library.stance(grip)
            feet[0].planted = p + rotY.rotate(st.footL * skeleton.scale)
            feet[1].planted = p + rotY.rotate(st.footR * skeleton.scale)
            feet[0].stepping = false; feet[1].stepping = false
            initialized = true
        }

        // 1. Target rig pose from action or stance.
        var rp: RigPose
        var lockFeet = false
        if let tr = track {
            trackTime += Double(dt) * trackSpeed
            rp = tr.sample(trackTime)
            lockFeet = tr.lockFeet
            if trackTime >= tr.duration {
                fadeFrom = rp
                fadeTime = 0
                fadeDuration = 0.1
                track = nil
            }
        } else {
            rp = library.stance(grip)
        }

        // 2. Locomotion modifiers.
        let speed = vlength(vflat(velocity))
        moveSpeedSmoothed = dampf(moveSpeedSmoothed, speed, 10, dt)
        let localVel = rotY.conjugate.rotate(velocity)
        localVelSmoothed = vdamp(localVelSmoothed, localVel, 8, dt)
        let speedN = saturatef(moveSpeedSmoothed / 5.5)
        if track == nil {
            gaitPhase += dt * (2.2 + moveSpeedSmoothed * 1.2)
            // Lean into movement, swing the free hand.
            rp.pitch += localVelSmoothed.z / 5.5 * (running ? 0.26 : 0.12)
            rp.roll += -localVelSmoothed.x / 5.5 * 0.12
            if rp.left == .free {
                rp.handL.z += sin(gaitPhase * 1.0) * 0.18 * speedN
                rp.handL.y += abs(cos(gaitPhase)) * 0.04 * speedN
            }
            rp.hand.y += sin(gaitPhase * 2) * 0.02 * speedN
            rp.crouch += 0.03 * speedN
        }

        // 3. Crossfade.
        if let from = fadeFrom {
            fadeTime += dt
            let t = fadeDuration > 0 ? saturatef(fadeTime / fadeDuration) : 1
            rp = RigPose.lerp(from, rp, Ease.outQuad.apply(t))
            if t >= 1 { fadeFrom = nil }
        }

        // 4. Feet.
        let s = skeleton.scale
        let idealL = p + rotY.rotate(rp.footL * Vec3(s, 1, s))
        let idealR = p + rotY.rotate(rp.footR * Vec3(s, 1, s))
        if lockFeet {
            feet[0].planted = idealL; feet[1].planted = idealR
            feet[0].stepping = false; feet[1].stepping = false
            feet[0].lift = 0; feet[1].lift = 0
        } else {
            stepFeet(dt: dt, ideal: [idealL, idealR], velocity: vflat(velocity), speed: moveSpeedSmoothed)
            let inv = rotY.conjugate
            let fl = inv.rotate(feet[0].planted - p), fr = inv.rotate(feet[1].planted - p)
            rp.footL = Vec3(fl.x / s, 0, fl.z / s)
            rp.footR = Vec3(fr.x / s, 0, fr.z / s)
            rp.liftL = max(rp.liftL, feet[0].lift)
            rp.liftR = max(rp.liftR, feet[1].lift)
            // Pelvis dips mid-step.
            let dip = (feet[0].stepping ? sin(kPi * feet[0].t / feet[0].duration) : 0)
                + (feet[1].stepping ? sin(kPi * feet[1].t / feet[1].duration) : 0)
            rp.crouch += dip * 0.02 * speedN
        }

        // 5. Additive layers.
        hitPitch.update(target: hitPitchTarget, halfLife: 0.06, dt: dt)
        hitRoll.update(target: hitRollTarget, halfLife: 0.06, dt: dt)
        hitPitchTarget = dampf(hitPitchTarget, 0, 9, dt)
        hitRollTarget = dampf(hitRollTarget, 0, 9, dt)
        breathPhase += dt * (1.6 + speedN * 2)
        var add = RigAdditive()
        add.torsoPitch = -hitPitch.value
        add.torsoRoll = hitRoll.value
        add.breath = sin(breathPhase) * breathing
        if tremble > 0 {
            trembleT += dt
            add.torsoYaw = sin(trembleT * 55) * 0.012 * tremble
            add.torsoPitch += sin(trembleT * 43) * 0.01 * tremble
        }
        if let lt = lookTarget {
            // Look target to model space.
            let local = rotY.conjugate.rotate(lt - p)
            add.lookTarget = local
        }
        currentRig = rp

        // 6. Solve.
        result = Rig.solve(rp, skeleton: skeleton, grip: grip, twoHandOffset: twoHandOffset, additive: add)
        worldMatrix = Mat4.trs(p, rotY)
        weaponRWorld = BoneXform(rot: rotY * result.weaponR.rot, pos: p + rotY.rotate(result.weaponR.pos))
        weaponLWorld = BoneXform(rot: rotY * result.weaponL.rot, pos: p + rotY.rotate(result.weaponL.pos))
        offhandWorld = BoneXform(rot: rotY * result.offhand.rot, pos: p + rotY.rotate(result.offhand.pos))
    }

    private func stepFeet(dt: Float, ideal: [Vec3], velocity: Vec3, speed: Float) {
        let duration = clampf(0.34 - speed * 0.028, 0.15, 0.34)
        let lift: Float = 0.06 + min(speed, 6) * 0.018
        let lead = velocity * duration * 0.55
        // Advance active steps.
        for i in 0..<2 where feet[i].stepping {
            feet[i].t += dt
            // Retarget toward the moving ideal so fast strafes stay under the body.
            feet[i].to = vdamp(feet[i].to, ideal[i] + lead, 10, dt)
            let u = saturatef(feet[i].t / feet[i].duration)
            let e = Ease.inOutQuad.apply(u)
            feet[i].planted = vlerp(feet[i].from, feet[i].to, e)
            feet[i].lift = sin(kPi * u) * lift
            if u >= 1 {
                feet[i].stepping = false; feet[i].lift = 0; feet[i].planted = feet[i].to
                footstepCount += 1
                lastFootstep = feet[i].planted
            }
        }
        // Start new steps.
        let moving = speed > 0.25
        let threshold: Float = moving ? max(0.08, 0.05 + speed * 0.045) : 0.14
        var errs: [Float] = [0, 0]
        for i in 0..<2 { errs[i] = vlength(vflat(feet[i].planted - ideal[i])) }
        // Teleport recovery.
        for i in 0..<2 where errs[i] > 1.6 {
            feet[i].planted = ideal[i]; feet[i].stepping = false; feet[i].lift = 0
        }
        let order = errs[0] >= errs[1] ? [0, 1] : [1, 0]
        for i in order where !feet[i].stepping {
            let other = feet[1 - i]
            let otherBusy = other.stepping && other.t < other.duration * (moving ? 0.5 : 0.95)
            if errs[i] > threshold && !otherBusy {
                feet[i].stepping = true
                feet[i].t = 0
                feet[i].duration = moving ? duration : 0.2
                feet[i].from = feet[i].planted
                feet[i].to = ideal[i] + lead
                break
            }
        }
    }

    // MARK: - Outputs

    public func skinPalette() -> [Mat4] { skeleton.skinMatrices(result.globals) }

    /// World-space position of a bone.
    public func boneWorld(_ b: Bone) -> Vec3 { position + Quat.yaw(yaw).rotate(result.globals[b.rawValue].pos) }

    public func boneXformWorld(_ b: Bone) -> BoneXform {
        let q = Quat.yaw(yaw)
        let g = result.globals[b.rawValue]
        return BoneXform(rot: q * g.rot, pos: position + q.rotate(g.pos))
    }
}
