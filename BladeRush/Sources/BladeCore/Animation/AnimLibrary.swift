// Animation library: stances, strike key poses and special poses, all loaded from
// Data/animations.json (hot reloadable). Strikes are authored once and reused by every
// weapon and boss; grips override only what differs.
import Foundation

/// Key poses for one strike archetype: windup, impact (mid-swing), strike end, follow-through.
public struct StrikeKeys: Codable, Equatable {
    public var w: RigKey?
    public var i: RigKey?
    public var s: RigKey?
    public var f: RigKey?
}

public struct AnimLibraryFile: Codable {
    public var stances: [String: RigKey] = [:]
    public var strikes: [String: [String: StrikeKeys]] = [:]
    public var poses: [String: [String: RigKey]] = [:]
}

/// Resolved strike key poses.
public struct ResolvedStrike {
    public var windup: RigPose
    public var impact: RigPose
    public var end: RigPose
    public var follow: RigPose
}

public final class AnimLibrary {
    public private(set) var file = AnimLibraryFile()
    public private(set) var version = 0
    private var stanceCache: [GripStyle: RigPose] = [:]

    public init() {}

    public func load(url: URL = Paths.dataFile("animations.json")) {
        guard let data = try? Data(contentsOf: url) else {
            logWarn("animations.json missing; using built-in fallbacks", "anim")
            return
        }
        do {
            file = try JSONUtil.decode(AnimLibraryFile.self, from: data)
            stanceCache.removeAll()
            version += 1
            logInfo("animations loaded: \(file.stances.count) stances, \(file.strikes.count) strikes, \(file.poses.count) poses", "anim")
        } catch {
            logError("animations.json error: \(JSONUtil.describe(error))", "anim")
        }
    }

    public func stance(_ grip: GripStyle) -> RigPose {
        if let c = stanceCache[grip] { return c }
        var p = RigPose()
        if let d = file.stances["default"] { p = p.applying(d) }
        for key in grip.fallbacks.reversed() where key != "default" {
            if let k = file.stances[key] { p = p.applying(k) }
        }
        stanceCache[grip] = p
        return p
    }

    func findKey<T>(_ table: [String: T]?, _ grip: GripStyle) -> T? {
        guard let t = table else { return nil }
        for key in grip.fallbacks { if let v = t[key] { return v } }
        return nil
    }

    /// Resolves a strike archetype for a grip and striking side ("R", "L", "both").
    public func strike(_ anim: String, grip: GripStyle, side: String) -> ResolvedStrike {
        let base = stance(grip)
        let keys = findKey(file.strikes[anim], grip) ?? findKey(file.strikes["slash_h"], grip) ?? StrikeKeys()
        func resolve(_ k: RigKey?, _ fallback: RigPose) -> RigPose {
            guard var key = k else { return fallback }
            switch side {
            case "L":
                key = key.mirrored
            case "both":
                let m = key.mirrored
                key.handL = m.handL; key.bladeL = m.bladeL
                key.left = .weapon
                key.yaw = 0; key.roll = 0
            default: break
            }
            return base.applying(key)
        }
        let w = resolve(keys.w, base)
        let s = resolve(keys.s, w)
        let i = keys.i != nil ? resolve(keys.i, s) : RigPose.lerp(w, s, 0.5)
        let f = resolve(keys.f, s)
        return ResolvedStrike(windup: w, impact: i, end: s, follow: f)
    }

    /// Special pose (parry, block, dodge, stagger, heal, roar, kneel, dead, ...).
    public func pose(_ name: String, grip: GripStyle, mirrored: Bool = false) -> RigPose {
        let base = stance(grip)
        guard var k = findKey(file.poses[name], grip) else { return base }
        if mirrored { k = k.mirrored }
        return base.applying(k)
    }

    public func hasPose(_ name: String) -> Bool { file.poses[name] != nil }
}

/// Keyframed rig-pose track.
public struct AnimTrack {
    public struct Key {
        public var t: Double
        public var pose: RigPose
        public var ease: Ease
        public init(_ t: Double, _ pose: RigPose, _ ease: Ease = .inOutQuad) { self.t = t; self.pose = pose; self.ease = ease }
    }

    public var keys: [Key]
    public var duration: Double { keys.last?.t ?? 0 }
    /// Feet follow the body rigidly (no procedural stepping) — dodges, leaps, knockdowns.
    public var lockFeet: Bool = false

    public init(keys: [Key], lockFeet: Bool = false) {
        self.keys = keys.sorted { $0.t < $1.t }
        self.lockFeet = lockFeet
    }

    public func sample(_ t: Double) -> RigPose {
        guard let first = keys.first else { return RigPose() }
        if t <= first.t { return first.pose }
        for i in 1..<keys.count {
            let k1 = keys[i]
            if t <= k1.t {
                let k0 = keys[i - 1]
                let span = k1.t - k0.t
                let u = span > 1e-9 ? Float((t - k0.t) / span) : 1
                return RigPose.lerp(k0.pose, k1.pose, k1.ease.apply(u))
            }
        }
        return keys[keys.count - 1].pose
    }

    /// Builds the animation for one strike, synchronized with its frame data:
    /// anticipation into the windup during startup, a fast accelerating swing through the
    /// impact pose during the active frames, then follow-through and recovery to `endPose`.
    public static func strike(_ st: StrikeDef, keys: ResolvedStrike, from start: RigPose, to endPose: RigPose,
                              recovery: Double) -> AnimTrack {
        let S = st.startupTime
        let D = Double(st.delay) / 60
        let A = st.activeTime
        let baseStartup = max(0.03, S - D)
        let windupReach = baseStartup * 0.8
        let pre = min(0.05, baseStartup * 0.2)
        var k: [Key] = [Key(0, start, .linear)]
        // Windup (anticipation).
        k.append(Key(windupReach, keys.windup, .outCubic))
        // Delayed attacks hold the windup (purple telegraph).
        let holdEnd = max(windupReach + 0.001, S - pre)
        k.append(Key(holdEnd, keys.windup, .linear))
        if st.feint {
            return AnimTrack(keys: k)
        }
        // Fast swing: accelerate into impact, decelerate to the end pose.
        k.append(Key(S + A * 0.45, keys.impact, .inQuad))
        k.append(Key(S + A, keys.end, .outQuad))
        // Follow-through and recovery.
        let R = max(0.05, recovery)
        k.append(Key(S + A + R * 0.4, keys.follow, .outCubic))
        k.append(Key(S + A + R, endPose, .inOutQuad))
        return AnimTrack(keys: k, lockFeet: st.leap > 0)
    }

    /// Simple timed transition into a held pose and back (parry, heal, stagger...).
    public static func pose(from start: RigPose, to p: RigPose, inTime: Double, hold: Double, outTime: Double,
                            end: RigPose, ease: Ease = .outCubic, lockFeet: Bool = false) -> AnimTrack {
        AnimTrack(keys: [Key(0, start, .linear),
                         Key(inTime, p, ease),
                         Key(inTime + hold, p, .linear),
                         Key(inTime + hold + outTime, end, .inOutQuad)], lockFeet: lockFeet)
    }
}
