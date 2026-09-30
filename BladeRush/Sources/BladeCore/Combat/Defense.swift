// Pure combat timing logic: parry / dodge / block resolution, posture and stamina math,
// and the input buffer. Kept free of game objects so it can be unit-tested exactly.
import Foundation

/// Effective defensive windows after tuning, accessibility timing assist and hard mode.
public struct DefenseWindows: Equatable {
    public var parry: Double
    public var perfectParry: Double
    public var iframeStart: Double
    public var iframes: Double
    public var perfectDodge: Double
    public var blockAfter: Double

    public init(parry: Double, perfectParry: Double, iframeStart: Double, iframes: Double, perfectDodge: Double, blockAfter: Double) {
        self.parry = parry; self.perfectParry = perfectParry; self.iframeStart = iframeStart
        self.iframes = iframes; self.perfectDodge = perfectDodge; self.blockAfter = blockAfter
    }

    /// `assist` is the accessibility timing-assist multiplier (1 = default, 2 = double windows).
    /// `hardMode` multiplies windows by the hard-mode factor (< 1 tightens them).
    public static func from(_ t: TimingTuning, assist: Double, hardModeMult: Double) -> DefenseWindows {
        let k = max(0.2, t.windowScale * assist * hardModeMult)
        // Perfect windows scale too, but never exceed the full parry window.
        let parry = t.parryWindow * k
        return DefenseWindows(parry: parry,
                              perfectParry: min(t.perfectParryWindow * k, parry),
                              iframeStart: t.dodgeIFrameStart,
                              iframes: t.dodgeIFrames * k,
                              perfectDodge: t.perfectDodgeWindow * k,
                              blockAfter: t.blockAfter)
    }
}

/// Snapshot of a defender's defensive state at the instant a hit arrives.
public struct DefenseState: Equatable {
    /// Game time the current parry window opened (nil if not parrying).
    public var parryPressTime: Double?
    /// Whether the parry button is held (for blocking after the window).
    public var parryHeld: Bool = false
    /// Game time the current dodge started (nil if not dodging).
    public var dodgeStartTime: Double?
    public var invulnerableUntil: Double = -1
    /// Katana ability stance: any incoming hit triggers the auto-counter.
    public var counterStance: Bool = false
    /// Grabs cannot be blocked or parried even by counter stances.
    public init() {}
}

public enum DefenseResolver {
    /// Decides what happens when an attack's hitbox reaches the defender at time `now`.
    public static func resolve(now: Double, telegraph: Telegraph, isGrab: Bool,
                               state: DefenseState, windows: DefenseWindows) -> DefenseOutcome {
        if now < state.invulnerableUntil { return .ignored }

        // 1. Dodge invincibility frames.
        if let ds = state.dodgeStartTime {
            let e = now - ds
            if e >= windows.iframeStart - 1e-9 && e <= windows.iframeStart + windows.iframes + 1e-9 {
                return .dodged(perfect: e <= windows.perfectDodge + 1e-9)
            }
        }

        // 2. Counter stance (katana Iaido) counters anything except grabs.
        if state.counterStance && !isGrab { return .counter }

        let unblockable = telegraph == .red || isGrab

        // 3. Parry window.
        if let tp = state.parryPressTime, !unblockable {
            let e = now - tp
            if e >= -1e-9 && e <= windows.parry + 1e-9 {
                return .parried(perfect: e <= windows.perfectParry + 1e-9)
            }
        }

        // 4. Holding guard after the window: block.
        if !unblockable, state.parryHeld, let tp = state.parryPressTime, now - tp >= windows.blockAfter - 1e-9 {
            return .blocked
        }
        if !unblockable, state.parryHeld, state.parryPressTime == nil {
            return .blocked
        }
        return .hit
    }

    /// Classifies a parry press that lands `lead` seconds before the hit (negative = after).
    /// Used by tests and the frame-data overlay.
    public static func classifyParry(lead: Double, windows: DefenseWindows) -> String {
        if lead < 0 { return "late" }
        if lead <= windows.perfectParry { return "perfect" }
        if lead <= windows.parry { return "parry" }
        return "early"
    }
}

/// Posture meter shared by player and bosses.
public struct PostureMeter: Equatable {
    public var value: Float = 0
    public var max: Float
    public var lastDamageTime: Double = -100

    public init(max: Float) { self.max = max }

    public var fraction: Float { max > 0 ? value / max : 0 }
    public var isBroken: Bool { value >= max }

    /// Adds posture damage. Returns true if this caused a break.
    @discardableResult
    public mutating func add(_ amount: Float, now: Double) -> Bool {
        guard amount > 0 else { return false }
        let wasBroken = isBroken
        value = min(max, value + amount)
        lastDamageTime = now
        return !wasBroken && isBroken
    }

    /// Recovers posture after `delay` seconds without damage. Recovery slows at low health
    /// (Sekiro-style), so wounded fighters stay vulnerable longer.
    public mutating func recover(dt: Double, now: Double, delay: Double, rate: Float, healthFraction: Float, boost: Float = 1) {
        guard now - lastDamageTime >= delay, value > 0 else { return }
        let scale = (0.35 + 0.65 * saturatef(healthFraction)) * boost
        value = Swift.max(0, value - rate * scale * Float(dt))
    }

    public mutating func reset() { value = 0 }
}

public struct StaminaMeter: Equatable {
    public var value: Float
    public var max: Float
    public var lastUseTime: Double = -100

    public init(max: Float) { self.max = max; value = max }

    public var fraction: Float { max > 0 ? value / max : 0 }

    /// Actions are allowed while any stamina remains (Souls-style: never makes the game
    /// feel sluggish, but emptying the bar delays regeneration).
    public var canAct: Bool { value > 0.5 }

    public mutating func spend(_ cost: Float, now: Double) {
        value = Swift.max(0, value - cost)
        lastUseTime = now
    }

    public mutating func regen(dt: Double, now: Double, rate: Float, delay: Double) {
        // Emptying the bar adds a longer pause before regeneration.
        let d = value <= 0.5 ? delay * 1.8 : delay
        guard now - lastUseTime >= d else { return }
        value = Swift.min(max, value + rate * Float(dt))
    }
}

/// Posture / damage formulas in one place (unit-tested).
public enum CombatMath {
    /// Posture damage the *player* takes when defending against an attack.
    public static func playerPostureDamage(outcome: DefenseOutcome, attackPosture: Float, t: PlayerTuning) -> Float {
        switch outcome {
        case .parried(let perfect): return attackPosture * (perfect ? t.perfectParryPostureFactor : t.parryPostureFactor)
        case .blocked: return attackPosture * t.blockPostureFactor
        case .hit: return attackPosture * t.hitPostureFactor
        default: return 0
        }
    }

    /// Health damage the player takes.
    public static func playerHealthDamage(outcome: DefenseOutcome, attackDamage: Float, t: PlayerTuning) -> Float {
        switch outcome {
        case .hit: return attackDamage
        case .blocked: return attackDamage * t.blockDamageFactor
        default: return 0
        }
    }

    /// Posture damage dealt *to the boss* by the player's parry.
    public static func bossPostureFromParry(perfect: Bool, telegraph: Telegraph, attackPosture: Float,
                                            weaponParryMult: Float, t: BossTuning) -> Float {
        let mult: Float
        if perfect { mult = telegraph == .gold ? t.goldPerfectParryPostureMult : t.perfectParryPostureMult } else { mult = t.parryPostureMult }
        return attackPosture * mult * weaponParryMult
    }
}

/// Buffered player actions. Pressing a button slightly before the current action can be
/// cancelled still executes it at the first legal moment.
public enum PlayerAction: String, CaseIterable, Codable {
    case light, heavy, ability, parry, dodge, swapNext, swapPrev, heal
}

public struct InputBuffer: Equatable {
    public var window: Double
    public private(set) var pending: PlayerAction?
    public private(set) var pendingTime: Double = 0

    public init(window: Double) { self.window = window }

    public mutating func push(_ a: PlayerAction, at t: Double) {
        pending = a
        pendingTime = t
    }

    /// Returns the buffered action if it is still fresh and `allowed` accepts it.
    /// Expired entries are dropped. The entry is consumed when returned.
    public mutating func take(now: Double, allowed: (PlayerAction) -> Bool) -> PlayerAction? {
        guard let p = pending else { return nil }
        if now - pendingTime > window + 1e-9 { pending = nil; return nil }
        guard allowed(p) else { return nil }
        pending = nil
        return p
    }

    public func peek(now: Double) -> PlayerAction? {
        guard let p = pending, now - pendingTime <= window + 1e-9 else { return nil }
        return p
    }

    public mutating func clear() { pending = nil }
}
