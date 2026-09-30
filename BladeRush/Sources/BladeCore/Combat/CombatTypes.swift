// Shared data model for attacks. Both the player's weapon movesets and every boss
// attack are built from `StrikeDef`s: one swing with startup / active / recovery
// frames, damage, posture damage, telegraph, root motion and hitbox description.
import Foundation

/// Telegraph language (consistent across all bosses).
public enum Telegraph: String, Codable, CaseIterable {
    case none      // quick attack, parryable, no flash
    case white     // white flash: parryable
    case red       // red glow: unblockable, must dodge
    case purple    // purple shimmer: delayed or feint, timing is offset
    case gold      // gold flash: combo ender, big punish on perfect parry

    public var isParryable: Bool { self != .red }
    public var isBlockable: Bool { self != .red }
}

public enum HitWeight: String, Codable, CaseIterable { case light, medium, heavy, huge }

public enum HitboxKind: String, Codable {
    case weapon        // capsule following the blade
    case body          // capsule around the attacker (charges, shield bashes with body)
    case weaponAndBody
    case aoe           // sphere burst only
    case grab          // weapon hitbox; on hit the target is grabbed (unblockable)
    case offhand       // shield / off-hand item
    case none
}

public enum Element: String, Codable, CaseIterable { case none, fire, ice, lightning, shadow, blood, holy, water }

/// Convenience decoding with defaults so data files only list what differs.
extension KeyedDecodingContainer {
    @inlinable public func v<T: Decodable>(_ key: Key, _ def: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? def
    }
}

/// One swing. Frame values are authored at 60 frames per second.
public struct StrikeDef: Codable, Equatable {
    /// Animation archetype key; resolved to windup / strike / follow poses per grip style.
    public var anim: String = "slash_h"
    /// "R", "L" or "both": which hand's weapon strikes (dual wield / shield).
    public var side: String = "R"
    public var startup: Float = 18
    public var active: Float = 6
    public var recovery: Float = 22
    public var damage: Float = 10
    public var posture: Float = 10
    public var telegraph: Telegraph = .none
    /// Extra frames held at the top of the windup (purple delayed attacks).
    public var delay: Float = 0
    /// Windup only: cancels into the next strike without an active phase.
    public var feint: Bool = false
    /// Forward root motion in meters, spread over windup end + active.
    public var move: Float = 0
    /// Sideways root motion in meters (+ = attacker's right).
    public var lateral: Float = 0
    /// Jump arc height in meters (leaping slams, vaults).
    public var leap: Float = 0
    /// Yaw rotation in degrees performed during the active phase (spin attacks).
    public var spin: Float = 0
    public var hitbox: HitboxKind = .weapon
    /// Multiplier on weapon reach (chain / whip extension).
    public var reach: Float = 1
    /// Short-range burst radius at the weapon tip (or in front of the body) on the first active frame.
    public var aoeRadius: Float = 0
    /// Forward offset of the burst from the body when there is no weapon contact point.
    public var aoeOffset: Float = 1.2
    /// Multi-hit during the active phase (whirlwinds, flurries).
    public var hits: Int = 1
    public var weight: HitWeight = .medium
    public var knockback: Float = 0
    public var launch: Bool = false
    /// Max turn speed toward the target during startup (deg/s). High = tracks well.
    public var tracking: Float = 240
    public var element: Element = .none
    /// Ground-level sweep (visual + must dodge).
    public var low: Bool = false
    /// Player only: frame after which dodge / parry may cancel (-1 = end of active).
    public var cancelFrame: Float = -1
    /// Player only: frame after which the next combo input is accepted (-1 = end of active).
    public var comboFrame: Float = -1
    /// Boss only: switch to weapon slot before this strike (weapon-swap mid-combo).
    public var swapWeapon: Int = -1
    /// Bleed stacks applied on hit.
    public var bleed: Int = 0
    public var hyperArmor: Bool = false
    public var invulnerable: Bool = false
    /// Optional sound override key.
    public var sound: String = ""
    /// Grab: seconds the target is held and the damage dealt at release.
    public var grabHold: Float = 1.2
    /// Boss counter stance (mirrors the katana Iaido): hits during startup are deflected
    /// and the strike releases immediately as a counter.
    public var counterStance: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StrikeDef.template
        anim = try c.v(.anim, d.anim)
        side = try c.v(.side, d.side)
        startup = try c.v(.startup, d.startup)
        active = try c.v(.active, d.active)
        recovery = try c.v(.recovery, d.recovery)
        damage = try c.v(.damage, d.damage)
        posture = try c.v(.posture, d.posture)
        telegraph = try c.v(.telegraph, d.telegraph)
        delay = try c.v(.delay, d.delay)
        feint = try c.v(.feint, d.feint)
        move = try c.v(.move, d.move)
        lateral = try c.v(.lateral, d.lateral)
        leap = try c.v(.leap, d.leap)
        spin = try c.v(.spin, d.spin)
        hitbox = try c.v(.hitbox, d.hitbox)
        reach = try c.v(.reach, d.reach)
        aoeRadius = try c.v(.aoeRadius, d.aoeRadius)
        aoeOffset = try c.v(.aoeOffset, d.aoeOffset)
        hits = try c.v(.hits, d.hits)
        weight = try c.v(.weight, d.weight)
        knockback = try c.v(.knockback, d.knockback)
        launch = try c.v(.launch, d.launch)
        tracking = try c.v(.tracking, d.tracking)
        element = try c.v(.element, d.element)
        low = try c.v(.low, d.low)
        cancelFrame = try c.v(.cancelFrame, d.cancelFrame)
        comboFrame = try c.v(.comboFrame, d.comboFrame)
        swapWeapon = try c.v(.swapWeapon, d.swapWeapon)
        bleed = try c.v(.bleed, d.bleed)
        hyperArmor = try c.v(.hyperArmor, d.hyperArmor)
        invulnerable = try c.v(.invulnerable, d.invulnerable)
        sound = try c.v(.sound, d.sound)
        grabHold = try c.v(.grabHold, d.grabHold)
        counterStance = try c.v(.counterStance, d.counterStance)
    }

    public static let template = StrikeDef()

    // Seconds helpers (frames are authored at 60 fps).
    @inlinable public var startupTime: Double { Double(startup + delay) / 60 }
    @inlinable public var activeTime: Double { Double(max(active, 1)) / 60 }
    @inlinable public var recoveryTime: Double { Double(recovery) / 60 }
    @inlinable public var totalTime: Double { feint ? startupTime : startupTime + activeTime + recoveryTime }

    public var isUnblockable: Bool { telegraph == .red || hitbox == .grab }
}

/// Runtime playback of a sequence of strikes (a boss attack or a single player move).
public struct StrikeTimeline {
    public enum Phase: Equatable { case startup, active, recovery, done }

    public private(set) var strikes: [StrikeDef]
    public private(set) var index: Int = 0
    /// Time within the current strike (seconds, already speed-scaled).
    public private(set) var time: Double = 0
    private var announcedIndex: Int = -1
    public var speed: Double = 1
    /// Fraction of each non-final strike's recovery that is skipped when chaining.
    public var chainRecoveryFraction: Double = 0.35

    public init(strikes: [StrikeDef], speed: Double = 1) {
        self.strikes = strikes
        self.speed = speed
    }

    public var current: StrikeDef? { index < strikes.count ? strikes[index] : nil }
    public var isDone: Bool { index >= strikes.count }
    public var isLastStrike: Bool { index == strikes.count - 1 }

    /// Effective recovery for the current strike (chained strikes skip part of recovery).
    public func recoveryDuration(_ i: Int) -> Double {
        let s = strikes[i]
        if i < strikes.count - 1 { return s.recoveryTime * chainRecoveryFraction }
        return s.recoveryTime
    }

    public func duration(_ i: Int) -> Double {
        let s = strikes[i]
        if s.feint { return s.startupTime }
        return s.startupTime + s.activeTime + recoveryDuration(i)
    }

    public var phase: Phase {
        guard let s = current else { return .done }
        if time < s.startupTime { return .startup }
        if s.feint { return .recovery }
        if time < s.startupTime + s.activeTime { return .active }
        return .recovery
    }

    /// Progress 0..1 within the active phase.
    public var activeProgress: Double {
        guard let s = current else { return 1 }
        return clampd((time - s.startupTime) / s.activeTime, 0, 1)
    }

    /// Time remaining until the current strike's active phase starts (<= 0 once active).
    public var timeToActive: Double {
        guard let s = current else { return 0 }
        return s.startupTime - time
    }

    public enum Event: Equatable { case strikeBegan(Int), activeBegan(Int), activeEnded(Int), strikeEnded(Int), finished }

    /// Advances time; returns the events crossed during this step (in order).
    public mutating func advance(_ dt: Double) -> [Event] {
        var events: [Event] = []
        guard !isDone else { return events }
        if announcedIndex != index { events.append(.strikeBegan(index)); announcedIndex = index }
        var remaining = dt * speed
        while remaining > 0, let s = current {
            let t0 = time
            let dur = duration(index)
            let step = min(remaining, max(dur - t0, 0))
            time += step
            remaining -= step
            if !s.feint {
                if t0 < s.startupTime && time >= s.startupTime { events.append(.activeBegan(index)) }
                let ae = s.startupTime + s.activeTime
                if t0 < ae && time >= ae { events.append(.activeEnded(index)) }
            }
            if time >= dur - 1e-9 {
                events.append(.strikeEnded(index))
                index += 1
                time = 0
                if isDone { events.append(.finished); break }
                events.append(.strikeBegan(index))
                announcedIndex = index
                if remaining <= 0 { break }
            } else {
                break
            }
        }
        return events
    }

    /// Jumps directly to the recovery of the current strike (used when interrupted/parried).
    public mutating func skipToEnd() { index = strikes.count; time = 0 }

    /// Jumps to just before the active phase of the current strike (counter-stance release).
    public mutating func skipToActive() {
        guard let s = current else { return }
        time = max(time, s.startupTime - 0.001)
    }
}

/// Result of a hit reaching a defender.
public enum DefenseOutcome: Equatable {
    case hit
    case blocked
    case parried(perfect: Bool)
    case dodged(perfect: Bool)
    case counter        // katana iaido stance auto-counter
    case ignored        // invulnerable, already resolved etc.
}
