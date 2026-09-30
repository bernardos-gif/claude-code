// Third-person camera: free follow, lock-on framing of player + boss, collision
// avoidance, critically damped smoothing, trauma-based shake and cinematic shots.
import Foundation

public enum CameraMode: Equatable { case follow, lockOn, cinematic, free }

public final class GameCamera {
    public var mode: CameraMode = .follow
    public var yaw: Float = kPi          // direction the camera looks (from camera to player)
    public var pitch: Float = 0.25       // positive looks down
    public var position = Vec3(0, 2, -5)
    public var lookAt = Vec3(0, 1.5, 0)
    public var fov: Float = 58
    public var fovKick: Float = 0
    public var trauma: Float = 0
    public var shakeScale: Float = 1
    public var near: Float = 0.08
    public var far: Float = 600
    private var posSpring = SpringVec3(Vec3(0, 2, -5))
    private var lookSpring = SpringVec3(Vec3(0, 1.5, 0))
    private var distSpring = SpringFloat(4.6)
    private var time: Float = 0
    private var shakeOffset = Vec3.zero
    private var shakeRoll: Float = 0
    public private(set) var roll: Float = 0
    // Cinematic shot.
    public var cineFocus = Vec3.zero
    public var cineYaw: Float = 0
    public var cineDistance: Float = 3
    public var cineHeight: Float = 1.4
    public var cineUntil: Double = 0
    // Free camera.
    public var freePos = Vec3(0, 3, -8)

    public init() {}

    public func addTrauma(_ t: Float) { trauma = min(1, trauma + t) }

    public func snap(player: Fighter, target: Fighter?) {
        yaw = player.yaw
        if let t = target { yaw = dirToYaw(t.position - player.position) }
        let pivot = player.position + Vec3(0, 1.6, 0)
        position = pivot - yawToDir(yaw) * 4.6 + Vec3(0, 1, 0)
        posSpring = SpringVec3(position)
        lookSpring = SpringVec3(pivot)
        lookAt = pivot
    }

    public func startCinematic(focus: Vec3, yaw: Float, distance: Float, height: Float, until: Double) {
        cineFocus = focus; cineYaw = yaw; cineDistance = distance; cineHeight = height; cineUntil = until
        mode = .cinematic
    }

    /// `look` is the per-frame camera input in radians (x yaw, y pitch).
    public func update(dt: Float, now: Double, player: Fighter, lockTarget: Fighter?, look: Vec2, tuning: CameraTuning,
                       colliders: [CylinderCollider], arenaRadius: Float, freeMove: Vec3 = .zero) {
        time += dt
        fov = tuning.fov
        if mode == .cinematic && now >= cineUntil { mode = lockTarget != nil ? .lockOn : .follow }
        if mode != .cinematic && mode != .free { mode = lockTarget != nil ? .lockOn : .follow }

        var desiredPos: Vec3
        var desiredLook: Vec3
        var half = tuning.followHalfLife
        let pivot = player.position + Vec3(0, tuning.height * max(0.85, player.height / 1.8), 0)
        switch mode {
        case .free:
            yaw = wrapAngle(yaw - look.x)
            pitch = clampf(pitch + look.y, -1.4, 1.4)
            let fwd = Vec3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
            let right = Vec3(-cos(yaw), 0, sin(yaw))
            freePos += (fwd * freeMove.z + right * freeMove.x + Vec3(0, freeMove.y, 0)) * dt * 8
            position = freePos
            lookAt = freePos + fwd
            posSpring = SpringVec3(position)
            lookSpring = SpringVec3(lookAt)
            return
        case .follow:
            yaw = wrapAngle(yaw - look.x)
            pitch = clampf(pitch + look.y, -0.55, 1.05)
            distSpring.update(target: tuning.distance, halfLife: 0.25, dt: dt)
            let dir = Vec3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
            desiredLook = pivot
            desiredPos = pivot - dir * distSpring.value
        case .lockOn:
            guard let t = lockTarget else { desiredLook = pivot; desiredPos = position; break }
            let tc = t.position + Vec3(0, t.height * 0.55, 0)
            let toT = vflat(t.position - player.position)
            let d = vlength(toT)
            let wantYaw = dirToYaw(toT)
            yaw = dampAngle(yaw, wantYaw, 1 / max(tuning.lockOnHalfLife, 0.01) * 0.7, dt)
            // Frame both fighters: pull back and raise as they separate / as the boss grows.
            let bigBoss = max(0, t.height - 2)
            let wantDist = tuning.lockOnDistance + max(0, d - 3.5) * 0.28 + bigBoss * 0.9
            distSpring.update(target: wantDist, halfLife: 0.3, dt: dt)
            let wantPitch: Float = 0.18 + bigBoss * 0.05 + (d < 2.5 ? 0.12 : 0)
            pitch = dampf(pitch, wantPitch, 3, dt)
            let dir = Vec3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
            desiredLook = vlerp(pivot, tc, 0.42)
            desiredPos = pivot - dir * distSpring.value + Vec3(0, 0.25, 0)
            half = tuning.lockOnHalfLife
        case .cinematic:
            let dir = yawToDir(cineYaw)
            desiredLook = cineFocus
            desiredPos = cineFocus - dir * cineDistance + Vec3(0, cineHeight, 0)
            half = 0.18
        }

        // Collision: pull the camera in front of pillars and keep it inside the backdrop.
        let from = desiredLook
        var to = desiredPos
        let rayDir = to - from
        let rayLen = vlength(rayDir)
        if rayLen > 0.01 {
            let dn = rayDir / rayLen
            var best = rayLen
            for c in colliders {
                if let hit = Geometry.rayVerticalCylinder(origin: from, dir: dn, center: c.center, radius: c.radius + 0.35, y0: -1, y1: c.height + 0.5) {
                    best = min(best, max(0.8, hit - 0.1))
                }
            }
            to = from + dn * best
        }
        let maxR = arenaRadius + 9
        let flat = vflat(to)
        if vlength(flat) > maxR { to = Vec3(flat.x, 0, flat.z) * (maxR / vlength(flat)) + Vec3(0, to.y, 0) }
        to.y = max(to.y, 0.35)

        posSpring.update(target: to, halfLife: half, dt: dt)
        lookSpring.update(target: desiredLook, halfLife: half * 0.7, dt: dt)
        position = posSpring.value
        lookAt = lookSpring.value

        // Shake (trauma^2 scaled Perlin noise).
        trauma = max(0, trauma - dt * 1.6)
        let s = trauma * trauma * shakeScale
        shakeOffset = Vec3(Noise.simplex2(time * 25, 1.3), Noise.simplex2(time * 25, 7.1), Noise.simplex2(time * 25, 13.7)) * 0.16 * s
        shakeRoll = Noise.simplex2(time * 20, 21.3) * 0.05 * s
        roll = shakeRoll
        fovKick = dampf(fovKick, 0, 5, dt)
    }

    public var eye: Vec3 { position + shakeOffset }

    public var viewMatrix: Mat4 {
        let fwd = vnormalize(lookAt + shakeOffset * 0.5 - eye)
        let up = Quat(axis: fwd, angle: roll).rotate(Vec3(0, 1, 0))
        return Mat4.lookAt(eye: eye, target: eye + fwd, up: up)
    }

    public func projection(aspect: Float) -> Mat4 {
        Mat4.perspective(fovyRadians: (fov + fovKick) * kDeg2Rad, aspect: aspect, near: near, far: far)
    }

    public var forwardFlat: Vec3 { vnormalize(vflat(lookAt - position), fallback: Vec3(0, 0, 1)) }
}
