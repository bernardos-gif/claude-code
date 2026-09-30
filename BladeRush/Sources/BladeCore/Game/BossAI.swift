// Boss decision making: weighted attack selection (distance, phase, cooldowns, recent
// history), adaptive counters to player habits, and spacing behavior between attacks.
import Foundation

public enum SpacingMode: String { case approach, circleLeft, circleRight, retreat, wait, flank }

/// Tracks the player's recent habits with exponential decay (half-life ~8 s).
public struct HabitTracker {
    public var parry: Float = 0
    public var dodge: Float = 0
    public var block: Float = 0
    public var aggression: Float = 0
    public var heal: Float = 0
    private let halfLife: Float = 8

    public init() {}

    public mutating func decay(_ dt: Float) {
        let k = exp(-dt * 0.693 / halfLife)
        parry *= k; dodge *= k; block *= k; aggression *= k; heal *= k
    }

    public mutating func observe(_ a: PlayerAction) {
        switch a {
        case .parry: parry += 1
        case .dodge: dodge += 1
        case .light, .heavy: aggression += 1
        case .heal: heal += 1
        default: break
        }
    }

    /// Normalized 0..1 "spam" levels.
    public var parrySpam: Float { saturatef((parry - 3) / 6) }
    public var dodgeSpam: Float { saturatef((dodge - 3) / 6) }
    public var blockHeavy: Float { saturatef(block / 5) }
}

public struct AttackChoice {
    public var attack: ResolvedAttack
    public var weight: Float
}

public final class BossAI {
    public var habits = HabitTracker()
    public private(set) var history: [String] = []
    public private(set) var cooldowns: [String: Double] = [:]
    public private(set) var lastWeights: [(String, Float)] = []
    public private(set) var lastChoice = ""
    public var mode: SpacingMode = .wait
    public var modeUntil: Double = 0
    public var nextAttackTime: Double = 1.5
    public var rng: Rng
    /// Gauntlet: only attack when the director grants the token.
    public var mayAttack: () -> Bool = { true }
    public var flankAngle: Float = 0

    public init(seed: UInt64) { rng = Rng(seed: seed) }

    public func noteUsed(_ a: ResolvedAttack, now: Double) {
        history.append(a.id)
        if history.count > 6 { history.removeFirst() }
        if a.cooldown > 0 { cooldowns[a.id] = now + Double(a.cooldown) }
        lastChoice = a.name
    }

    /// Chooses an attack for the current distance, or nil if none fits.
    public func chooseAttack(_ attacks: [ResolvedAttack], distance: Float, phase: Int, hardMode: Bool, now: Double,
                             adaptStrength: Float, preferFast: Bool = false) -> ResolvedAttack? {
        var choices: [AttackChoice] = []
        var dbg: [(String, Float)] = []
        let last = history.last
        let last2 = history.count >= 2 ? history[history.count - 2] : nil
        for a in attacks {
            if phase < a.minPhase || phase > a.maxPhase { continue }
            if a.hardOnly && !hardMode { continue }
            if let cd = cooldowns[a.id], cd > now { continue }
            // No repeating the same attack three times in a row.
            if a.id == last && a.id == last2 { continue }
            let lo = a.minRange - 0.4, hi = a.maxRange + 0.35
            guard distance >= lo && distance <= hi else { continue }
            var w = a.weight
            // Prefer attacks whose sweet spot matches the distance.
            let mid = (a.minRange + a.maxRange) * 0.5
            let span = max(0.5, (a.maxRange - a.minRange) * 0.5)
            w *= 0.6 + 0.4 * saturatef(1 - abs(distance - mid) / (span * 1.5))
            if a.id == last { w *= 0.35 }
            // Adaptive counters to player habits.
            let tel = a.telegraph
            if tel == .red { w *= 1 + habits.parrySpam * 2.2 * adaptStrength }
            if tel == .purple { w *= 1 + habits.dodgeSpam * 2.2 * adaptStrength }
            if a.category == "grab" || a.category == "bash" { w *= 1 + habits.blockHeavy * 1.5 * adaptStrength }
            if a.signature { w *= phase >= 2 ? 1.3 : 0.6 }
            if preferFast {
                let s = a.strikes.first?.startup ?? 20
                w *= s < 16 ? 2.5 : 0.5
            }
            if w > 0 { choices.append(AttackChoice(attack: a, weight: w)); dbg.append((a.name, w)) }
        }
        lastWeights = dbg.sorted { $0.1 > $1.1 }
        guard let idx = rng.weightedIndex(choices.map { $0.weight }) else { return nil }
        return choices[idx].attack
    }

    /// Picks the next spacing behavior based on distance to the preferred range.
    public func chooseSpacing(distance: Float, preferred: Float, now: Double, aggression: Float) {
        var w: [SpacingMode: Float] = [.wait: 0.6, .circleLeft: 1, .circleRight: 1]
        if distance > preferred + 1.2 { w[.approach] = 3 * aggression; w[.wait] = 0.2 }
        else if distance < max(1.2, preferred - 1.2) { w[.retreat] = 1.5; w[.approach] = 0 }
        else { w[.approach] = 0.8 * aggression }
        let modes = Array(w.keys)
        let idx = rng.weightedIndex(modes.map { w[$0] ?? 0 }) ?? 0
        mode = modes[idx]
        modeUntil = now + Double(rng.range(0.5, 1.4))
    }
}

/// Coordinates two bosses in gauntlet fights: one attack token, the other flanks, with
/// occasional tag-team follow-ups that give the player a readable rhythm.
public final class GauntletDirector {
    public private(set) var holder: Int?
    private var releaseTime: Double = 0
    public private(set) var tagTeamUntil: Double = 0

    public init() {}

    public func request(_ bossId: Int, now: Double) -> Bool {
        if let h = holder, h != bossId {
            // Tag-team: the partner may follow up shortly after the holder's attack starts.
            return now < tagTeamUntil
        }
        return now >= releaseTime || holder == bossId
    }

    public func began(_ bossId: Int, now: Double, rng: inout Rng) {
        holder = bossId
        tagTeamUntil = rng.chance(0.25) ? now + 0.9 : 0
    }

    public func finished(_ bossId: Int, now: Double) {
        if holder == bossId { holder = nil; releaseTime = now + 0.5 }
    }
}
