// Procedural IK rig. Instead of hand-keying 22 bone rotations per pose, every pose is
// described by a handful of intuitive targets (where the weapon hand is, where the blade
// points, torso twist/lean, crouch, foot placement). The rig solves arm and leg IK each
// frame, which gives natural arcs for swings, two-handed grips via off-hand IK, feet that
// stay planted, and lets one attack library drive every body type.
import Foundation

/// How a character holds its weapon(s). Selects stance and attack pose sets.
public enum GripStyle: String, Codable, CaseIterable {
    case oneHand, twoHand, polearm, dual, shield, flexible

    /// Pose-set fallback chain in Data/animations.json.
    public var fallbacks: [String] {
        switch self {
        case .oneHand: return ["oneHand", "default"]
        case .twoHand: return ["twoHand", "oneHand", "default"]
        case .polearm: return ["polearm", "twoHand", "default"]
        case .dual: return ["dual", "oneHand", "default"]
        case .shield: return ["shield", "oneHand", "default"]
        case .flexible: return ["flexible", "oneHand", "default"]
        }
    }
    public var usesOffhandGrip: Bool { self == .twoHand || self == .polearm }
}

public enum LeftHandMode: String, Codable { case free, grip, guarding = "guard", shield, weapon }

/// Authoring format (Data/animations.json). Coordinates are RUF: x = character's right,
/// y = up, z = forward, in meters for a 1.8 m body. Hand targets are relative to the
/// chest (midpoint between the shoulders) and rotate with the torso; feet are relative
/// to the root on the ground. Angles are degrees: yaw + turns the torso to the right,
/// pitch + leans forward, roll + leans toward the right side. Every field is optional
/// and inherits from the grip's stance.
public struct RigKey: Codable, Equatable {
    public var hand: Vec3?
    public var blade: Vec3?
    public var handL: Vec3?
    public var bladeL: Vec3?
    public var left: LeftHandMode?
    public var yaw: Float?
    public var pitch: Float?
    public var roll: Float?
    public var crouch: Float?
    public var shift: Vec3?
    public var footL: Vec3?
    public var footR: Vec3?
    public var liftL: Float?
    public var liftR: Float?
    public var headYaw: Float?
    public var headPitch: Float?
    public var bodyPitch: Float?
    public var bodyRoll: Float?

    public init() {}

    /// Mirror left/right (for left-hand strikes of dual wielders, etc.).
    public var mirrored: RigKey {
        func mx(_ v: Vec3?) -> Vec3? { v.map { Vec3(-$0.x, $0.y, $0.z) } }
        var k = RigKey()
        k.hand = mx(handL); k.handL = mx(hand)
        k.blade = mx(bladeL); k.bladeL = mx(blade)
        k.left = left
        k.yaw = yaw.map { -$0 }; k.pitch = pitch; k.roll = roll.map { -$0 }
        k.crouch = crouch; k.shift = mx(shift)
        k.footL = mx(footR); k.footR = mx(footL)
        k.liftL = liftR; k.liftR = liftL
        k.headYaw = headYaw.map { -$0 }; k.headPitch = headPitch
        k.bodyPitch = bodyPitch; k.bodyRoll = bodyRoll.map { -$0 }
        return k
    }
}

/// Fully resolved pose targets in internal model coordinates (+X = left).
public struct RigPose: Equatable {
    public var hand = Vec3(-0.22, -0.32, 0.32)
    public var blade = vnormalize(Vec3(0, 0.6, 1))
    public var handL = Vec3(0.22, -0.4, 0.15)
    public var bladeL = vnormalize(Vec3(0, 0.3, 1))
    public var left: LeftHandMode = .free
    public var yaw: Float = 0
    public var pitch: Float = 0
    public var roll: Float = 0
    public var crouch: Float = 0.04
    public var shift: Vec3 = .zero
    public var footL = Vec3(0.13, 0, 0.1)
    public var footR = Vec3(-0.14, 0, -0.12)
    public var liftL: Float = 0
    public var liftR: Float = 0
    public var headYaw: Float = 0
    public var headPitch: Float = 0
    public var bodyPitch: Float = 0
    public var bodyRoll: Float = 0

    public init() {}

    /// Converts from RUF authoring space to internal (+X = left) and applies a key over this pose.
    public func applying(_ k: RigKey) -> RigPose {
        func cv(_ v: Vec3) -> Vec3 { Vec3(-v.x, v.y, v.z) }
        var r = self
        if let v = k.hand { r.hand = cv(v) }
        if let v = k.blade { r.blade = vnormalize(cv(v)) }
        if let v = k.handL { r.handL = cv(v) }
        if let v = k.bladeL { r.bladeL = vnormalize(cv(v)) }
        if let v = k.left { r.left = v }
        if let v = k.yaw { r.yaw = -v * kDeg2Rad }
        if let v = k.pitch { r.pitch = v * kDeg2Rad }
        if let v = k.roll { r.roll = v * kDeg2Rad }
        if let v = k.crouch { r.crouch = v }
        if let v = k.shift { r.shift = cv(v) }
        if let v = k.footL { r.footL = cv(v) }
        if let v = k.footR { r.footR = cv(v) }
        if let v = k.liftL { r.liftL = v }
        if let v = k.liftR { r.liftR = v }
        if let v = k.headYaw { r.headYaw = -v * kDeg2Rad }
        if let v = k.headPitch { r.headPitch = v * kDeg2Rad }
        if let v = k.bodyPitch { r.bodyPitch = v * kDeg2Rad }
        if let v = k.bodyRoll { r.bodyRoll = -v * kDeg2Rad }
        return r
    }

    /// Interpolates two rig poses. Hands travel on arcs around their shoulders so swings
    /// sweep around the body instead of cutting through it; blades slerp.
    public static func lerp(_ a: RigPose, _ b: RigPose, _ t: Float) -> RigPose {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var r = RigPose()
        let pivotR = Vec3(-0.17, 0, 0), pivotL = Vec3(0.17, 0, 0)
        r.hand = arcLerp(a.hand, b.hand, pivot: pivotR, t)
        r.handL = arcLerp(a.handL, b.handL, pivot: pivotL, t)
        r.blade = dirSlerp(a.blade, b.blade, t)
        r.bladeL = dirSlerp(a.bladeL, b.bladeL, t)
        r.left = t < 0.5 ? a.left : b.left
        r.yaw = lerpf(a.yaw, b.yaw, t)
        r.pitch = lerpf(a.pitch, b.pitch, t)
        r.roll = lerpf(a.roll, b.roll, t)
        r.crouch = lerpf(a.crouch, b.crouch, t)
        r.shift = vlerp(a.shift, b.shift, t)
        r.footL = vlerp(a.footL, b.footL, t)
        r.footR = vlerp(a.footR, b.footR, t)
        r.liftL = lerpf(a.liftL, b.liftL, t)
        r.liftR = lerpf(a.liftR, b.liftR, t)
        r.headYaw = lerpf(a.headYaw, b.headYaw, t)
        r.headPitch = lerpf(a.headPitch, b.headPitch, t)
        r.bodyPitch = lerpf(a.bodyPitch, b.bodyPitch, t)
        r.bodyRoll = lerpf(a.bodyRoll, b.bodyRoll, t)
        return r
    }

    static func arcLerp(_ a: Vec3, _ b: Vec3, pivot: Vec3, _ t: Float) -> Vec3 {
        let va = a - pivot, vb = b - pivot
        let la = vlength(va), lb = vlength(vb)
        if la < 1e-4 || lb < 1e-4 { return vlerp(a, b, t) }
        let da = va / la, db = vb / lb
        if vdot(da, db) < -0.96 { return vlerp(a, b, t) }
        return pivot + dirSlerp(da, db, t) * lerpf(la, lb, t)
    }

    static func dirSlerp(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 {
        let d = clampf(vdot(a, b), -1, 1)
        if d > 0.9995 { return vnormalize(vlerp(a, b, t)) }
        if d < -0.9995 {
            // Opposite: rotate around any perpendicular axis (prefer vertical plane).
            var axis = vcross(a, Vec3(0, 1, 0))
            if vlengthSq(axis) < 1e-6 { axis = vcross(a, Vec3(1, 0, 0)) }
            return Quat(axis: axis, angle: kPi * t).rotate(a)
        }
        let theta = acos(d)
        let s = sin(theta)
        return vnormalize(a * (sin((1 - t) * theta) / s) + b * (sin(t * theta) / s))
    }
}

/// Output of a rig solve.
public struct RigResult {
    public var pose: Pose
    public var globals: [BoneXform]
    /// Weapon attachment frames (origin at grip, +Z along the blade).
    public var weaponR: BoneXform
    public var weaponL: BoneXform
    /// Shield / off-hand frame attached to the left forearm.
    public var offhand: BoneXform
}

/// Extra procedural offsets layered on top of a rig pose.
public struct RigAdditive {
    public var torsoPitch: Float = 0
    public var torsoRoll: Float = 0
    public var torsoYaw: Float = 0
    public var headPitch: Float = 0
    public var breath: Float = 0
    public var lookTarget: Vec3?   // model-space point to look at
    public init() {}
}

public enum Rig {
    /// Solves a full skeleton pose from rig targets.
    /// - twoHandOffset: distance along the blade from the right grip to the left-hand grip
    ///   (negative = toward the pommel) for two-handed and polearm weapons.
    public static func solve(_ rp: RigPose, skeleton sk: Skeleton, grip: GripStyle, twoHandOffset: Float,
                             additive: RigAdditive = RigAdditive()) -> RigResult {
        let s = sk.scale
        var pose = Pose()
        let hunch = sk.proportions.hunch * kDeg2Rad

        // Whole-body rotation (knockdowns, deaths), pivoting near the pelvis.
        if rp.bodyPitch != 0 || rp.bodyRoll != 0 {
            let q = Quat(axis: Vec3(0, 0, 1), angle: rp.bodyRoll) * Quat(axis: Vec3(1, 0, 0), angle: rp.bodyPitch)
            pose.rootRot = q
            let pivot = Vec3(0, sk.hipHeight * 0.55, 0)
            pose.rootOffset = pivot - q.rotate(pivot)
        }

        // Pelvis and spine.
        let yaw = rp.yaw + additive.torsoYaw
        let pitch = rp.pitch + additive.torsoPitch + additive.breath * 0.02
        let roll = rp.roll + additive.torsoRoll
        pose.pelvisOffset = Vec3(rp.shift.x * s, -rp.crouch * s + rp.shift.y * s, rp.shift.z * s)
        pose.rot[Bone.pelvis.rawValue] = Quat.euler(pitch * 0.15, yaw * 0.3, roll * 0.2)
        pose.rot[Bone.spine1.rawValue] = Quat.euler(pitch * 0.35, yaw * 0.35, roll * 0.35)
        pose.rot[Bone.spine2.rawValue] = Quat.euler(pitch * 0.5 + hunch, yaw * 0.35, roll * 0.45)

        // Clavicle shrug toward raised / forward hands.
        func shrug(_ target: Vec3) -> (Float, Float) {
            let up = saturatef((target.y + 0.05) / 0.45)
            let fwd = saturatef(target.z / 0.55)
            return (up * 16 * kDeg2Rad, fwd * 14 * kDeg2Rad)
        }
        let (upR, fwR) = shrug(rp.hand)
        pose.rot[Bone.clavR.rawValue] = Quat.euler(0, fwR, -upR)
        let lTarget = rp.left == .grip ? rp.hand : rp.handL
        let (upL, fwL) = shrug(lTarget)
        pose.rot[Bone.clavL.rawValue] = Quat.euler(0, -fwL, upL)

        var g = sk.computeGlobals(pose)

        // Chest frame: rotation of spine2, origin between the shoulders.
        let chestRot = g[Bone.spine2.rawValue].rot
        let shoulderR = g[Bone.upperArmR.rawValue].pos
        let shoulderL = g[Bone.upperArmL.rawValue].pos
        let chest = (shoulderR + shoulderL) * 0.5
        let l1 = sk.upperArmLength, l2 = sk.forearmLength
        let gripDist = 0.085 * s

        // --- Right arm (weapon arm).
        let targetR = chest + chestRot.rotate(rp.hand * s)
        let bladeR = vnormalize(chestRot.rotate(rp.blade))
        let poleR = chestRot.rotate(vnormalize(Vec3(-0.55, -0.55, -0.45)))
        let wristR = targetR - vnormalize(targetR - shoulderR) * gripDist
        solveArm(&pose, &g, sk, upper: .upperArmR, fore: .forearmR, hand: .handR,
                 shoulder: shoulderR, wrist: wristR, pole: poleR, l1: l1, l2: l2, blade: bladeR)
        let handRg = g[Bone.handR.rawValue]
        let foreDirR = vnormalize(handRg.pos - g[Bone.forearmR.rawValue].pos)
        let weaponR = BoneXform(rot: handRg.rot, pos: handRg.pos + foreDirR * gripDist)

        // --- Left arm.
        var weaponL = weaponR
        switch rp.left {
        case .grip:
            let gp = weaponR.pos + weaponR.rot.rotate(Vec3(0, 0, twoHandOffset * s))
            let wristL = gp - vnormalize(gp - shoulderL) * gripDist
            let poleL = chestRot.rotate(vnormalize(Vec3(0.55, -0.55, -0.45)))
            solveArm(&pose, &g, sk, upper: .upperArmL, fore: .forearmL, hand: .handL,
                     shoulder: shoulderL, wrist: wristL, pole: poleL, l1: l1, l2: l2,
                     blade: weaponR.rot.rotate(Vec3(0, 0, 1)))
        default:
            let targetL = chest + chestRot.rotate(rp.handL * s)
            let bl = vnormalize(chestRot.rotate(rp.bladeL))
            let poleL = chestRot.rotate(vnormalize(Vec3(0.55, -0.55, -0.45)))
            let wristL = targetL - vnormalize(targetL - shoulderL) * gripDist
            solveArm(&pose, &g, sk, upper: .upperArmL, fore: .forearmL, hand: .handL,
                     shoulder: shoulderL, wrist: wristL, pole: poleL, l1: l1, l2: l2, blade: bl)
            let handLg = g[Bone.handL.rawValue]
            let foreDirL = vnormalize(handLg.pos - g[Bone.forearmL.rawValue].pos)
            weaponL = BoneXform(rot: handLg.rot, pos: handLg.pos + foreDirL * gripDist)
        }
        // Off-hand (shield) frame: on the outside of the left forearm, facing forward-out.
        let foreL = g[Bone.forearmL.rawValue]
        let handL = g[Bone.handL.rawValue]
        let armDir = vnormalize(handL.pos - foreL.pos)
        let chestFwd = chestRot.rotate(Vec3(0, 0, 1))
        var faceDir = vnormalize(chestFwd - armDir * vdot(chestFwd, armDir))
        faceDir = vnormalize(faceDir + chestRot.rotate(Vec3(0.25, 0, 0)))
        let offhand = BoneXform(rot: Quat.lookRotation(forward: faceDir, up: -armDir),
                                pos: vlerp(foreL.pos, handL.pos, 0.55) + faceDir * 0.06 * s)

        // --- Legs: IK toward planted foot targets.
        let ankleOff = 0.08 * s
        solveLeg(&pose, &g, sk, thigh: .thighL, shin: .shinL, foot: .footL,
                 target: rp.footL * Vec3(s, 1, s) + Vec3(0, ankleOff + rp.liftL * s, 0), lift: rp.liftL, side: 1)
        solveLeg(&pose, &g, sk, thigh: .thighR, shin: .shinR, foot: .footR,
                 target: rp.footR * Vec3(s, 1, s) + Vec3(0, ankleOff + rp.liftR * s, 0), lift: rp.liftR, side: -1)

        // --- Neck / head look.
        var hy = rp.headYaw, hp = rp.headPitch + additive.headPitch - pitch * 0.6
        if let lt = additive.lookTarget {
            let headPos = g[Bone.head.rawValue].pos
            let local = g[Bone.spine2.rawValue].rot.conjugate.rotate(lt - headPos)
            let ly = atan2(local.x, local.z)
            let lp = -atan2(local.y, (local.x * local.x + local.z * local.z).squareRoot())
            hy += clampf(ly, -1.2, 1.2)
            hp += clampf(lp, -0.6, 0.7)
        }
        pose.rot[Bone.neck.rawValue] = Quat.euler(hp * 0.4 - hunch * 0.5, hy * 0.4, 0)
        pose.rot[Bone.head.rawValue] = Quat.euler(hp * 0.6, hy * 0.6, 0)
        g = sk.computeGlobals(pose)

        return RigResult(pose: pose, globals: g, weaponR: weaponR, weaponL: weaponL, offhand: offhand)
    }

    /// Two-bone IK for an arm. Produces hinge-only elbows (no twist) and orients the hand
    /// so the held weapon points along `blade` while the fist continues the forearm.
    static func solveArm(_ pose: inout Pose, _ g: inout [BoneXform], _ sk: Skeleton,
                         upper: Bone, fore: Bone, hand: Bone,
                         shoulder: Vec3, wrist: Vec3, pole: Vec3, l1: Float, l2: Float, blade: Vec3) {
        let (elbow, wristP) = twoBoneTargets(root: shoulder, target: wrist, pole: pole, l1: l1, l2: l2)
        let d1 = vnormalize(elbow - shoulder, fallback: Vec3(0, -1, 0))
        let d2 = vnormalize(wristP - elbow, fallback: d1)
        var xAxis = vcross(d2, d1)
        if vlengthSq(xAxis) < 1e-5 { xAxis = vcross(d1, vnormalize(pole)) }
        xAxis = vnormalize(xAxis, fallback: Vec3(1, 0, 0))
        let upperG = frameFrom(yAxis: -d1, xHint: xAxis)
        let foreG = frameFrom(yAxis: -d2, xHint: xAxis)
        let parentRot = g[upper.parent].rot
        pose.rot[upper.rawValue] = (parentRot.conjugate * upperG).normalized
        pose.rot[fore.rawValue] = (upperG.conjugate * foreG).normalized
        let handG = Quat.lookRotation(forward: blade, up: -d2)
        pose.rot[hand.rawValue] = (foreG.conjugate * handG).normalized
        g = sk.computeGlobals(pose)
    }

    static func solveLeg(_ pose: inout Pose, _ g: inout [BoneXform], _ sk: Skeleton,
                         thigh: Bone, shin: Bone, foot: Bone, target: Vec3, lift: Float, side: Float) {
        let hip = g[thigh.rawValue].pos
        let rootRot = g[0].rot
        let pole = rootRot.rotate(vnormalize(Vec3(0.12 * side, 0.1, 1)))
        let (knee, ankle) = twoBoneTargets(root: hip, target: target, pole: pole, l1: sk.thighLength, l2: sk.shinLength)
        let d1 = vnormalize(knee - hip, fallback: Vec3(0, -1, 0))
        let d2 = vnormalize(ankle - knee, fallback: d1)
        var xAxis = vcross(d1, d2)
        if vlengthSq(xAxis) < 1e-5 { xAxis = vcross(vnormalize(pole), d1) }
        xAxis = vnormalize(xAxis, fallback: Vec3(1, 0, 0))
        let thighG = frameFrom(yAxis: -d1, xHint: xAxis)
        let shinG = frameFrom(yAxis: -d2, xHint: xAxis)
        pose.rot[thigh.rawValue] = (g[thigh.parent].rot.conjugate * thighG).normalized
        pose.rot[shin.rawValue] = (thighG.conjugate * shinG).normalized
        // Foot flat on the ground facing the body's forward, toes dip while lifted.
        let pelvisYaw = g[Bone.pelvis.rawValue].rot
        let fwd = vnormalize(vflat(pelvisYaw.rotate(Vec3(0, 0, 1))), fallback: Vec3(0, 0, 1))
        var footG = rootRot * Quat.lookRotation(forward: rootRot.conjugate.rotate(fwd), up: Vec3(0, 1, 0))
        footG = footG * Quat(axis: Vec3(0, 1, 0), angle: 0.12 * side) * Quat(axis: Vec3(1, 0, 0), angle: saturatef(lift * 6) * 0.35)
        pose.rot[foot.rawValue] = (shinG.conjugate * footG).normalized
        g = sk.computeGlobals(pose)
    }

    /// Classic analytic two-bone IK. Returns (middle joint, end effector) positions.
    public static func twoBoneTargets(root: Vec3, target: Vec3, pole: Vec3, l1: Float, l2: Float) -> (Vec3, Vec3) {
        let d = target - root
        let dist0 = vlength(d)
        let dir = dist0 > 1e-5 ? d / dist0 : Vec3(0, -1, 0)
        let dist = clampf(dist0, abs(l1 - l2) + 1e-3, (l1 + l2) * 0.9995)
        let a = clampf((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist), -1, 1)
        var p = pole - dir * vdot(pole, dir)
        if vlengthSq(p) < 1e-8 {
            p = vcross(dir, Vec3(1, 0, 0))
            if vlengthSq(p) < 1e-8 { p = vcross(dir, Vec3(0, 0, 1)) }
        }
        p = vnormalize(p)
        let mid = root + dir * (l1 * a) + p * (l1 * (1 - a * a).squareRoot())
        let end = root + dir * dist
        return (mid, end)
    }

    /// Rotation whose +Y axis is `yAxis` and +X is as close as possible to `xHint`.
    static func frameFrom(yAxis: Vec3, xHint: Vec3) -> Quat {
        let y = vnormalize(yAxis)
        var x = xHint - y * vdot(xHint, y)
        if vlengthSq(x) < 1e-8 { x = vcross(y, Vec3(0, 0, 1)) }
        x = vnormalize(x)
        let z = vcross(x, y)
        return Quat.fromMatrixColumns(x, y, z)
    }
}
