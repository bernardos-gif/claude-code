// Humanoid skeleton shared by the player and every boss. Proportions vary per character
// (height, limb lengths, shoulder width...), the bone topology does not, so the whole
// animation rig and attack library work for every body type.
//
// Coordinate convention (model space): +Y up, +Z forward, +X = the character's LEFT.
// Bone rest rotations are identity; each bone's rest offset from its parent encodes its
// direction (arms and legs hang straight down in the rest pose).
import Foundation

public enum Bone: Int, CaseIterable {
    case root = 0, pelvis, spine1, spine2, neck, head
    case clavL, upperArmL, forearmL, handL
    case clavR, upperArmR, forearmR, handR
    case thighL, shinL, footL, toeL
    case thighR, shinR, footR, toeR

    public static let count = 22

    public static let parents: [Int] = [-1, 0, 1, 2, 3, 4,
                                        3, 6, 7, 8,
                                        3, 10, 11, 12,
                                        1, 14, 15, 16,
                                        1, 18, 19, 20]

    public var parent: Int { Bone.parents[rawValue] }

    public var mirrored: Bone {
        switch self {
        case .clavL: return .clavR
        case .upperArmL: return .upperArmR
        case .forearmL: return .forearmR
        case .handL: return .handR
        case .clavR: return .clavL
        case .upperArmR: return .upperArmL
        case .forearmR: return .forearmL
        case .handR: return .handL
        case .thighL: return .thighR
        case .shinL: return .shinR
        case .footL: return .footR
        case .toeL: return .toeR
        case .thighR: return .thighL
        case .shinR: return .shinL
        case .footR: return .footL
        case .toeR: return .toeL
        default: return self
        }
    }
}

/// Body proportions (all relative to a 1.8 m human, 1.0 = average).
public struct BodyProportions: Codable, Equatable {
    public var height: Float = 1.8
    public var legs: Float = 1.0
    public var arms: Float = 1.0
    public var torso: Float = 1.0
    public var shoulders: Float = 1.0
    public var hips: Float = 1.0
    public var neck: Float = 1.0
    public var head: Float = 1.0
    /// Thickness of limbs and torso (mesh only).
    public var bulk: Float = 1.0
    public var belly: Float = 0.0
    public var muscle: Float = 0.5
    /// Forward spine curvature at rest (degrees).
    public var hunch: Float = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BodyProportions()
        height = try c.v(.height, d.height); legs = try c.v(.legs, d.legs); arms = try c.v(.arms, d.arms)
        torso = try c.v(.torso, d.torso); shoulders = try c.v(.shoulders, d.shoulders); hips = try c.v(.hips, d.hips)
        neck = try c.v(.neck, d.neck); head = try c.v(.head, d.head); bulk = try c.v(.bulk, d.bulk)
        belly = try c.v(.belly, d.belly); muscle = try c.v(.muscle, d.muscle); hunch = try c.v(.hunch, d.hunch)
    }

    /// Uniform scale factor relative to the reference 1.8 m body.
    public var scale: Float { height / 1.8 }
}

/// Skeleton instance: rest offsets for one body type plus bind pose data for skinning.
public final class Skeleton {
    public let proportions: BodyProportions
    /// Rest offset of each bone from its parent (parent space, rest rotations are identity).
    public private(set) var offsets: [Vec3]
    /// Inverse bind matrices (model space), computed from the A-pose used for mesh generation.
    public private(set) var inverseBind: [Mat4] = []
    /// Bind pose global positions (A-pose) — used by the mesh builder.
    public private(set) var bindGlobals: [BoneXform] = []
    /// Bone lengths (distance to the first child), handy for IK.
    public var upperArmLength: Float { vlength(offsets[Bone.forearmL.rawValue]) }
    public var forearmLength: Float { vlength(offsets[Bone.handL.rawValue]) }
    public var thighLength: Float { vlength(offsets[Bone.shinL.rawValue]) }
    public var shinLength: Float { vlength(offsets[Bone.footL.rawValue]) }
    public var hipHeight: Float { offsets[Bone.pelvis.rawValue].y }
    public var scale: Float { proportions.scale }

    public init(_ p: BodyProportions) {
        proportions = p
        let s = p.scale
        var o = [Vec3](repeating: .zero, count: Bone.count)
        let leg = p.legs, arm = p.arms, tor = p.torso
        func set(_ b: Bone, _ v: Vec3) { o[b.rawValue] = v * s }
        set(.root, .zero)
        set(.pelvis, Vec3(0, 0.07 + 0.90 * leg, 0))
        set(.spine1, Vec3(0, 0.11 * tor, 0))
        set(.spine2, Vec3(0, 0.20 * tor, 0))
        set(.neck, Vec3(0, 0.22 * tor, -0.01))
        set(.head, Vec3(0, 0.09 * p.neck + 0.01, 0.01))
        set(.clavL, Vec3(0.03, 0.17 * tor, 0))
        set(.upperArmL, Vec3(0.15 * p.shoulders, 0, -0.01))
        set(.forearmL, Vec3(0, -0.28 * arm, 0))
        set(.handL, Vec3(0, -0.25 * arm, 0))
        set(.thighL, Vec3(0.095 * p.hips, -0.05, 0))
        set(.shinL, Vec3(0, -0.43 * leg, 0))
        set(.footL, Vec3(0, -0.41 * leg, 0))
        set(.toeL, Vec3(0, -0.06, 0.12))
        for b in [Bone.clavL, .upperArmL, .forearmL, .handL, .thighL, .shinL, .footL, .toeL] {
            let v = o[b.rawValue]
            o[b.mirrored.rawValue] = Vec3(-v.x, v.y, v.z)
        }
        // Keep ankle height consistent (pelvis = hip joint + leg chain).
        let ankleY = o[Bone.pelvis.rawValue].y + o[Bone.thighL.rawValue].y + o[Bone.shinL.rawValue].y + o[Bone.footL.rawValue].y
        o[Bone.pelvis.rawValue].y += (0.08 * s - ankleY)
        offsets = o
        computeBind()
    }

    /// A-pose used for mesh generation: arms 42° out, legs slightly apart.
    public func bindPose() -> Pose {
        var pose = Pose()
        pose.rot[Bone.upperArmL.rawValue] = Quat(axis: Vec3(0, 0, 1), angle: 42 * kDeg2Rad)
        pose.rot[Bone.upperArmR.rawValue] = Quat(axis: Vec3(0, 0, 1), angle: -42 * kDeg2Rad)
        pose.rot[Bone.forearmL.rawValue] = Quat(axis: Vec3(1, 0, 0), angle: -8 * kDeg2Rad)
        pose.rot[Bone.forearmR.rawValue] = Quat(axis: Vec3(1, 0, 0), angle: -8 * kDeg2Rad)
        pose.rot[Bone.thighL.rawValue] = Quat(axis: Vec3(0, 0, 1), angle: 4 * kDeg2Rad)
        pose.rot[Bone.thighR.rawValue] = Quat(axis: Vec3(0, 0, 1), angle: -4 * kDeg2Rad)
        pose.rot[Bone.footL.rawValue] = Quat(axis: Vec3(0, 0, 1), angle: -4 * kDeg2Rad)
        pose.rot[Bone.footR.rawValue] = Quat(axis: Vec3(0, 0, 1), angle: 4 * kDeg2Rad)
        if proportions.hunch != 0 {
            pose.rot[Bone.spine2.rawValue] = Quat(axis: Vec3(1, 0, 0), angle: proportions.hunch * kDeg2Rad)
        }
        return pose
    }

    private func computeBind() {
        bindGlobals = computeGlobals(bindPose())
        inverseBind = bindGlobals.map { $0.matrix.rigidInverse }
    }

    /// Forward kinematics: local pose -> model-space bone transforms.
    public func computeGlobals(_ pose: Pose) -> [BoneXform] {
        var g = [BoneXform](repeating: BoneXform(), count: Bone.count)
        g[0] = BoneXform(rot: pose.rootRot, pos: pose.rootOffset)
        for i in 1..<Bone.count {
            let p = g[Bone.parents[i]]
            var off = offsets[i]
            if i == Bone.pelvis.rawValue { off += pose.pelvisOffset }
            g[i] = BoneXform(rot: p.rot * pose.rot[i], pos: p.pos + p.rot.rotate(off))
        }
        return g
    }

    /// Skinning palette: global * inverseBind per bone.
    public func skinMatrices(_ globals: [BoneXform]) -> [Mat4] {
        var m = [Mat4](repeating: .identity, count: Bone.count)
        for i in 0..<Bone.count { m[i] = globals[i].matrix * inverseBind[i] }
        return m
    }
}

/// Rigid bone transform (rotation + position).
public struct BoneXform: Equatable {
    public var rot: Quat = .identity
    public var pos: Vec3 = .zero
    public init(rot: Quat = .identity, pos: Vec3 = .zero) { self.rot = rot; self.pos = pos }
    @inlinable public var matrix: Mat4 { Mat4.trs(pos, rot) }
    @inlinable public func transform(_ p: Vec3) -> Vec3 { pos + rot.rotate(p) }
}

/// Local bone rotations plus root / pelvis translation.
public struct Pose: Equatable {
    public var rot: [Quat] = [Quat](repeating: .identity, count: Bone.count)
    public var pelvisOffset: Vec3 = .zero
    public var rootRot: Quat = .identity
    public var rootOffset: Vec3 = .zero

    public init() {}

    public static func blend(_ a: Pose, _ b: Pose, _ t: Float) -> Pose {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var r = Pose()
        for i in 0..<Bone.count { r.rot[i] = Quat.nlerp(a.rot[i], b.rot[i], t) }
        r.pelvisOffset = vlerp(a.pelvisOffset, b.pelvisOffset, t)
        r.rootRot = Quat.nlerp(a.rootRot, b.rootRot, t)
        r.rootOffset = vlerp(a.rootOffset, b.rootOffset, t)
        return r
    }
}
