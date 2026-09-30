// All combat feel values live here and in Data/tuning.json (hot reloaded while the
// game runs). Any key missing from the JSON falls back to the default below, so the
// JSON file can stay small and focused on what you are currently adjusting.
import Foundation

public struct TimingTuning: Codable, Equatable {
    /// Total parry (deflect) window after pressing parry, seconds.
    public var parryWindow: Double = 0.150
    /// The first part of the parry window that counts as a perfect parry.
    public var perfectParryWindow: Double = 0.060
    /// Vulnerable recovery after a parry that deflected nothing (too early).
    public var parryWhiffRecovery: Double = 0.28
    /// After a whiffed parry, further parry presses are ignored for this long (anti-spam).
    public var parrySpamCooldown: Double = 0.30
    /// Holding parry past the window turns into a block after this long.
    public var blockAfter: Double = 0.16
    /// Dodge: total duration, i-frame start/length, perfect-dodge window before impact.
    public var dodgeDuration: Double = 0.42
    public var dodgeIFrameStart: Double = 0.015
    public var dodgeIFrames: Double = 0.200
    public var perfectDodgeWindow: Double = 0.100
    /// Dodge can be cancelled into attacks/parry after this time.
    public var dodgeCancelAfter: Double = 0.30
    public var dodgeDistance: Float = 3.8
    public var backstepDistance: Float = 2.6
    /// Slow motion after a perfect dodge (real seconds) and its time scale.
    public var perfectDodgeSlowDuration: Double = 0.5
    public var perfectDodgeTimeScale: Double = 0.3
    /// Input buffer: presses this early during a locked state still execute.
    public var inputBuffer: Double = 0.150
    /// Brief invulnerability after taking a hit (prevents multi-hit juggling).
    public var hitInvulnerability: Double = 0.30
    /// Global multiplier applied to parry and dodge windows (the accessibility slider multiplies on top).
    public var windowScale: Double = 1.0
}

public struct HitstopTuning: Codable, Equatable {
    public var light: Double = 0.040
    public var medium: Double = 0.060
    public var heavy: Double = 0.090
    public var huge: Double = 0.120
    public var parry: Double = 0.060
    public var perfectParry: Double = 0.110
    public var block: Double = 0.045
    public var deathblow: Double = 0.250
    public var playerHit: Double = 0.075
    public var postureBreak: Double = 0.180

    public func value(for w: HitWeight) -> Double {
        switch w {
        case .light: return light
        case .medium: return medium
        case .heavy: return heavy
        case .huge: return huge
        }
    }
}

public struct PlayerTuning: Codable, Equatable {
    public var maxHealth: Float = 100
    public var maxPosture: Float = 100
    public var maxStamina: Float = 100
    public var staminaRegen: Float = 60
    public var staminaRegenDelay: Double = 0.45
    public var dodgeStamina: Float = 20
    public var postureRecoverDelay: Double = 1.1
    public var postureRecoverRate: Float = 24
    public var postureBreakStagger: Double = 1.35
    /// Posture damage multipliers when defending (fraction of the attack's posture value).
    public var parryPostureFactor: Float = 0.35
    public var perfectParryPostureFactor: Float = 0.0
    public var blockPostureFactor: Float = 1.0
    public var blockDamageFactor: Float = 0.12
    public var hitPostureFactor: Float = 0.45
    public var flasks: Int = 3
    public var healAmount: Float = 42
    public var healDuration: Double = 0.95
    public var healHealTime: Double = 0.55
    public var walkSpeed: Float = 2.4
    public var runSpeed: Float = 5.4
    public var lockedMoveSpeed: Float = 3.9
    public var acceleration: Float = 28
    public var turnRate: Float = 900
    public var abilityMax: Float = 100
    public var abilityGainHit: Float = 4
    public var abilityGainParry: Float = 6
    public var abilityGainPerfectParry: Float = 15
    public var abilityGainPerfectDodge: Float = 12
    public var swapDuration: Double = 0.28
    public var radius: Float = 0.38
    public var deathblowRange: Float = 3.0
    public var bleedDamagePerStack: Float = 1.2
    public var bleedDuration: Double = 5.0
    public var maxBleedStacks: Int = 10
}

public struct BossTuning: Codable, Equatable {
    public var postureRecoverDelay: Double = 1.8
    public var postureRecoverRate: Float = 9
    /// Boss posture damage from player parries: attack posture x multiplier.
    public var parryPostureMult: Float = 0.9
    public var perfectParryPostureMult: Float = 2.0
    public var goldPerfectParryPostureMult: Float = 3.4
    public var goldPunishStagger: Double = 1.1
    /// Posture-broken stagger (deathblow window).
    public var staggerDuration: Double = 3.2
    /// Deathblow damage on the final phase, as a fraction of max health.
    public var deathblowDamageFraction: Float = 0.4
    public var phaseTransitionDuration: Double = 2.6
    public var globalAggression: Float = 1.0
    public var adaptiveStrength: Float = 1.0
    public var hitFlinchThreshold: Float = 22
    public var damageMult: Float = 1.0
    public var healthMult: Float = 1.0
    public var speedMult: Float = 1.0
    /// Seconds between attacks at aggression 1.0 (randomized ±40%).
    public var attackInterval: Double = 1.1
}

public struct CameraTuning: Codable, Equatable {
    public var distance: Float = 4.6
    public var height: Float = 1.65
    public var lockOnDistance: Float = 5.2
    public var fov: Float = 58
    public var mouseSensitivity: Float = 0.0028
    public var stickSensitivity: Float = 3.2
    public var followHalfLife: Float = 0.06
    public var lockOnHalfLife: Float = 0.12
    public var shakeLight: Float = 0.18
    public var shakeHeavy: Float = 0.42
    public var shakeParry: Float = 0.3
    public var shakeSlam: Float = 0.65
}

public struct HardModeTuning: Codable, Equatable {
    public var windowMult: Double = 0.72
    public var bossSpeedMult: Float = 1.14
    public var bossDamageMult: Float = 1.3
    public var bossPostureMult: Float = 1.2
}

public struct CombatTuning: Codable, Equatable {
    public var timing = TimingTuning()
    public var hitstop = HitstopTuning()
    public var player = PlayerTuning()
    public var boss = BossTuning()
    public var camera = CameraTuning()
    public var hardMode = HardModeTuning()
    public init() {}
}

/// Loads Data/tuning.json and keeps it hot-reloaded.
public final class TuningStore {
    public private(set) var tuning = CombatTuning()
    public private(set) var reloadCount = 0
    public var onReload: ((CombatTuning) -> Void)?
    public let url: URL

    public init(url: URL = Paths.dataFile("tuning.json")) {
        self.url = url
        reload()
    }

    public func reload() {
        guard let data = try? Data(contentsOf: url) else {
            logWarn("tuning.json not found at \(url.path); using defaults", "tuning")
            return
        }
        do {
            tuning = try JSONUtil.decodeMerged(CombatTuning.self, from: data, defaults: CombatTuning())
            reloadCount += 1
            logInfo("tuning loaded (#\(reloadCount)) parry=\(Int(tuning.timing.parryWindow * 1000))ms perfect=\(Int(tuning.timing.perfectParryWindow * 1000))ms iframes=\(Int(tuning.timing.dodgeIFrames * 1000))ms", "tuning")
            onReload?(tuning)
        } catch {
            logError("tuning.json parse error (keeping previous values): \(JSONUtil.describe(error))", "tuning")
        }
    }

    /// For tests: override values directly.
    public func set(_ t: CombatTuning) { tuning = t }
}
