// Data definitions loaded from Data/*.json: player weapons (movesets, stats, abilities),
// the shared boss attack library, boss definitions and arenas. Everything tunable lives
// in JSON and is hot-reloaded between fights (tuning.json reloads instantly).
import Foundation

// MARK: - Player weapons

public struct WeaponStats: Codable, Equatable {
    public var damage: Float = 1
    public var posture: Float = 1
    public var speed: Float = 1
    public var reach: Float = 1
    public var staminaLight: Float = 7
    public var staminaHeavy: Float = 18
    public var abilityCost: Float = 50
    /// Multiplier on posture damage dealt to bosses by this weapon's parries.
    public var parryPostureMult: Float = 1
    public var chargeLevels: Int = 1
    public var chargeTime: Float = 0.45

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WeaponStats()
        damage = try c.v(.damage, d.damage); posture = try c.v(.posture, d.posture); speed = try c.v(.speed, d.speed)
        reach = try c.v(.reach, d.reach); staminaLight = try c.v(.staminaLight, d.staminaLight)
        staminaHeavy = try c.v(.staminaHeavy, d.staminaHeavy); abilityCost = try c.v(.abilityCost, d.abilityCost)
        parryPostureMult = try c.v(.parryPostureMult, d.parryPostureMult)
        chargeLevels = try c.v(.chargeLevels, d.chargeLevels); chargeTime = try c.v(.chargeTime, d.chargeTime)
    }
}

public struct AbilityDef: Codable, Equatable {
    public var kind = "none"             // iaido, earthsplitter, bloodDance, vault, chainPull
    public var name = ""
    public var strikes: [StrikeDef] = []
    public var duration: Float = 1.2     // stance duration / chain reach time
    public var range: Float = 8          // chain pull range, crack line length...
    public var damage: Float = 20
    public var posture: Float = 20
    public var extra: Float = 0          // kind-specific (bleed stacks, extension hits...)

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AbilityDef()
        kind = try c.v(.kind, d.kind); name = try c.v(.name, d.name); strikes = try c.v(.strikes, d.strikes)
        duration = try c.v(.duration, d.duration); range = try c.v(.range, d.range); damage = try c.v(.damage, d.damage)
        posture = try c.v(.posture, d.posture); extra = try c.v(.extra, d.extra)
    }
}

public struct PlayerWeaponDef: Codable, Equatable {
    public var id = "katana"
    public var name = "Katana"
    public var description = ""
    public var visual = WeaponVisual(type: "katana")
    public var stats = WeaponStats()
    public var trail = ["#ffffff", "#7ab8ff"]
    public var light: [StrikeDef] = []
    public var heavy: [StrikeDef] = []       // one per charge level (index 0 = uncharged)
    public var ability = AbilityDef()
    public var counter: [StrikeDef] = []     // perfect-dodge / perfect-parry bonus strikes
    public var riposte: [StrikeDef] = []
    public var swapStrike: [StrikeDef] = []
    public var deathblow: [StrikeDef] = []
    public var perfectParryBonus = ""
    public var perfectDodgeBonus = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlayerWeaponDef()
        id = try c.v(.id, d.id); name = try c.v(.name, d.name); description = try c.v(.description, d.description)
        visual = try c.v(.visual, d.visual); stats = try c.v(.stats, d.stats); trail = try c.v(.trail, d.trail)
        light = try c.v(.light, d.light); heavy = try c.v(.heavy, d.heavy); ability = try c.v(.ability, d.ability)
        counter = try c.v(.counter, d.counter); riposte = try c.v(.riposte, d.riposte)
        swapStrike = try c.v(.swapStrike, d.swapStrike); deathblow = try c.v(.deathblow, d.deathblow)
        perfectParryBonus = try c.v(.perfectParryBonus, d.perfectParryBonus)
        perfectDodgeBonus = try c.v(.perfectDodgeBonus, d.perfectDodgeBonus)
    }

    public var type: WeaponType { WeaponCatalog.get(visual.type) }
}

public struct WeaponsFile: Codable {
    public var weapons: [PlayerWeaponDef] = []
}

// MARK: - Boss attack library

/// Reusable attack building block (Data/attacks.json). Boss attacks reference these by id
/// and override numbers (damage multipliers, telegraphs, extra strikes...).
public struct AttackTemplate: Codable, Equatable {
    public var id = ""
    public var name = ""
    public var category = "slash"        // horizontal, overhead, diagonal, thrust, lunge, spin, leap, sweep, delayed, feint, combo, grab, bash, charge, whirlwind, swap, burst
    public var strikes: [StrikeDef] = []
    public var minRange: Float = 0
    public var maxRange: Float = 3.2
    public var weight: Float = 1
    public var cooldown: Float = 0
    /// Extra recovery after the attack: a deliberate opening for the player.
    public var opening: Float = 0

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AttackTemplate()
        id = try c.v(.id, d.id); name = try c.v(.name, d.name); category = try c.v(.category, d.category)
        strikes = try c.v(.strikes, d.strikes); minRange = try c.v(.minRange, d.minRange)
        maxRange = try c.v(.maxRange, d.maxRange); weight = try c.v(.weight, d.weight)
        cooldown = try c.v(.cooldown, d.cooldown); opening = try c.v(.opening, d.opening)
    }
}

public struct AttackLibraryFile: Codable {
    public var attacks: [AttackTemplate] = []
}

/// A boss's use of a library attack.
public struct BossAttackRef: Codable, Equatable {
    public var use = ""                  // template id
    public var name = ""                 // display name override (debug)
    public var damage: Float = 1         // multiplier
    public var posture: Float = 1        // multiplier
    public var speed: Float = 1          // multiplier on playback speed
    public var telegraph: Telegraph?     // override telegraph of the final strike
    public var telegraphs: [Telegraph]?  // per-strike override
    public var element: Element?
    public var weight: Float = 1
    public var cooldown: Float?
    public var minPhase: Int = 1
    public var maxPhase: Int = 9
    public var hardOnly = false
    public var signature = false
    public var reach: Float = 1          // hit reach multiplier (chain weapons, big bosses)
    public var moveScale: Float = 1
    public var aoe: Float = 0            // add a short-range burst to the final strike (m)
    public var side: String?             // force striking hand
    public var extraStrikes: [StrikeDef] = []
    public var opening: Float?
    /// Switch to this weapon slot at the start of the attack.
    public var swapTo: Int?

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BossAttackRef()
        use = try c.v(.use, d.use); name = try c.v(.name, d.name); damage = try c.v(.damage, d.damage)
        posture = try c.v(.posture, d.posture); speed = try c.v(.speed, d.speed)
        telegraph = try c.decodeIfPresent(Telegraph.self, forKey: .telegraph)
        telegraphs = try c.decodeIfPresent([Telegraph].self, forKey: .telegraphs)
        element = try c.decodeIfPresent(Element.self, forKey: .element)
        weight = try c.v(.weight, d.weight); cooldown = try c.decodeIfPresent(Float.self, forKey: .cooldown)
        minPhase = try c.v(.minPhase, d.minPhase); maxPhase = try c.v(.maxPhase, d.maxPhase)
        hardOnly = try c.v(.hardOnly, d.hardOnly); signature = try c.v(.signature, d.signature)
        reach = try c.v(.reach, d.reach); moveScale = try c.v(.moveScale, d.moveScale); aoe = try c.v(.aoe, d.aoe)
        side = try c.decodeIfPresent(String.self, forKey: .side)
        extraStrikes = try c.v(.extraStrikes, d.extraStrikes)
        opening = try c.decodeIfPresent(Float.self, forKey: .opening)
        swapTo = try c.decodeIfPresent(Int.self, forKey: .swapTo)
    }
}

/// A fully resolved boss attack ready for the AI.
public struct ResolvedAttack: Equatable {
    public var id: String
    public var name: String
    public var category: String
    public var strikes: [StrikeDef]
    public var minRange: Float
    public var maxRange: Float
    public var weight: Float
    public var cooldown: Float
    public var opening: Float
    public var speed: Float
    public var minPhase: Int
    public var maxPhase: Int
    public var hardOnly: Bool
    public var signature: Bool

    /// Dominant telegraph (the most dangerous one in the string).
    public var telegraph: Telegraph {
        if strikes.contains(where: { $0.telegraph == .red || $0.hitbox == .grab }) { return .red }
        if strikes.contains(where: { $0.telegraph == .purple }) { return .purple }
        if strikes.contains(where: { $0.telegraph == .gold }) { return .gold }
        if strikes.contains(where: { $0.telegraph == .white }) { return .white }
        return .none
    }
}

// MARK: - Bosses

public struct BossStats: Codable, Equatable {
    public var health: Float = 400
    public var posture: Float = 100
    public var damage: Float = 1
    public var speed: Float = 1
    public var moveSpeed: Float = 3.2
    public var aggression: Float = 1
    public var postureRegen: Float = 1
    public var poise: Float = 30         // damage absorbed before flinching
    public var deflect: Float = 0.1      // chance to deflect player hits while idle
    public var radius: Float = 0.45

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BossStats()
        health = try c.v(.health, d.health); posture = try c.v(.posture, d.posture); damage = try c.v(.damage, d.damage)
        speed = try c.v(.speed, d.speed); moveSpeed = try c.v(.moveSpeed, d.moveSpeed); aggression = try c.v(.aggression, d.aggression)
        postureRegen = try c.v(.postureRegen, d.postureRegen); poise = try c.v(.poise, d.poise); deflect = try c.v(.deflect, d.deflect)
        radius = try c.v(.radius, d.radius)
    }
}

public struct PhaseDef: Codable, Equatable {
    public var threshold: Float = 1      // phase starts when health fraction <= threshold
    public var name = ""
    public var speed: Float = 1
    public var damage: Float = 1
    public var aggression: Float = 1
    public var element: Element?
    public var weapon: Int?              // switch to weapon slot
    public var glow: Float = 0           // weapon / rune glow intensity
    public var line = ""                 // subtitle spoken at the transition
    public var lighting = ""             // arena lighting shift key (e.g. "red", "dark", "storm")

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PhaseDef()
        threshold = try c.v(.threshold, d.threshold); name = try c.v(.name, d.name); speed = try c.v(.speed, d.speed)
        damage = try c.v(.damage, d.damage); aggression = try c.v(.aggression, d.aggression)
        element = try c.decodeIfPresent(Element.self, forKey: .element); weapon = try c.decodeIfPresent(Int.self, forKey: .weapon)
        glow = try c.v(.glow, d.glow); line = try c.v(.line, d.line); lighting = try c.v(.lighting, d.lighting)
    }
}

public struct BossDef: Codable, Equatable {
    public var id = ""
    public var name = ""
    public var title = ""
    public var tier = 1
    public var lore = ""
    public var description = ""          // visual description (text)
    public var visual = CharacterVisual()
    public var weapons: [WeaponVisual] = [WeaponVisual()]
    public var stats = BossStats()
    public var attacks: [BossAttackRef] = []
    public var phases: [PhaseDef] = [PhaseDef()]
    public var signature = ""
    public var weaknesses: [String] = []
    public var weakTo: [String: Float] = [:]   // "bleed", "posture", "parry", "heavy", "chain"...
    public var intro = ""
    public var death = ""
    public var arena = ""
    public var music = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BossDef()
        id = try c.v(.id, d.id); name = try c.v(.name, d.name); title = try c.v(.title, d.title); tier = try c.v(.tier, d.tier)
        lore = try c.v(.lore, d.lore); description = try c.v(.description, d.description); visual = try c.v(.visual, d.visual)
        weapons = try c.v(.weapons, d.weapons); stats = try c.v(.stats, d.stats); attacks = try c.v(.attacks, d.attacks)
        phases = try c.v(.phases, d.phases); signature = try c.v(.signature, d.signature); weaknesses = try c.v(.weaknesses, d.weaknesses)
        weakTo = try c.v(.weakTo, d.weakTo); intro = try c.v(.intro, d.intro); death = try c.v(.death, d.death)
        arena = try c.v(.arena, d.arena); music = try c.v(.music, d.music)
    }
}

public struct EncounterDef: Codable, Equatable {
    public var id = ""
    public var name = ""
    public var title = ""
    public var kind = "boss"             // boss, gauntlet, final
    public var bosses: [String] = []
    public var arena = ""
    public var tier = 1

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EncounterDef()
        id = try c.v(.id, d.id); name = try c.v(.name, d.name); title = try c.v(.title, d.title)
        kind = try c.v(.kind, d.kind); bosses = try c.v(.bosses, d.bosses); arena = try c.v(.arena, d.arena); tier = try c.v(.tier, d.tier)
    }
}

public struct TierDef: Codable, Equatable {
    public var index = 1
    public var name = ""
    public var subtitle = ""
    public var arena = ""
    public var encounters: [String] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TierDef()
        index = try c.v(.index, d.index); name = try c.v(.name, d.name); subtitle = try c.v(.subtitle, d.subtitle)
        arena = try c.v(.arena, d.arena); encounters = try c.v(.encounters, d.encounters)
    }
}

public struct BossesFile: Codable {
    public var bosses: [BossDef] = []
    public var encounters: [EncounterDef] = []
    public var tiers: [TierDef] = []
}

// MARK: - Store

/// Loads and validates every data file. Reloadable at runtime.
public final class GameDataStore {
    public private(set) var weapons: [PlayerWeaponDef] = []
    public private(set) var attacks: [String: AttackTemplate] = [:]
    public private(set) var bosses: [String: BossDef] = [:]
    public private(set) var bossOrder: [String] = []
    public private(set) var encounters: [String: EncounterDef] = [:]
    public private(set) var encounterOrder: [String] = []
    public private(set) var tiers: [TierDef] = []
    public private(set) var arenas: [String: ArenaDef] = [:]
    public let anims = AnimLibrary()
    public let tuning: TuningStore
    public private(set) var problems: [String] = []
    public private(set) var version = 0

    public init(directory: URL = Paths.dataDirectory) {
        tuning = TuningStore(url: directory.appendingPathComponent("tuning.json"))
        reloadAll(directory: directory)
    }

    public func reloadAll(directory: URL = Paths.dataDirectory) {
        problems.removeAll()
        anims.load(url: directory.appendingPathComponent("animations.json"))
        loadWeapons(directory.appendingPathComponent("weapons.json"))
        loadAttacks(directory.appendingPathComponent("attacks.json"))
        loadBosses(directory.appendingPathComponent("bosses.json"))
        loadArenas(directory.appendingPathComponent("arenas.json"))
        validate()
        version += 1
        for p in problems { logWarn(p, "data") }
        logInfo("data loaded: \(weapons.count) weapons, \(attacks.count) attack templates, \(bosses.count) bosses, \(encounters.count) encounters, \(arenas.count) arenas, \(problems.count) problems", "data")
    }

    private func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { problems.append("missing \(url.lastPathComponent)"); return nil }
        do { return try JSONUtil.decode(T.self, from: data) } catch {
            problems.append("\(url.lastPathComponent): \(JSONUtil.describe(error))")
            logError("\(url.lastPathComponent): \(JSONUtil.describe(error))", "data")
            return nil
        }
    }

    private func loadWeapons(_ url: URL) {
        if let f = load(WeaponsFile.self, url) { weapons = f.weapons }
    }

    private func loadAttacks(_ url: URL) {
        guard let f = load(AttackLibraryFile.self, url) else { return }
        attacks = Dictionary(f.attacks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func loadBosses(_ url: URL) {
        guard let f = load(BossesFile.self, url) else { return }
        bosses = Dictionary(f.bosses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        bossOrder = f.bosses.map { $0.id }
        encounters = Dictionary(f.encounters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        encounterOrder = f.encounters.map { $0.id }
        tiers = f.tiers.sorted { $0.index < $1.index }
    }

    private func loadArenas(_ url: URL) {
        guard let f = load(ArenasFile.self, url) else { return }
        arenas = Dictionary(f.arenas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func weapon(_ id: String) -> PlayerWeaponDef? { weapons.first { $0.id == id } }

    /// Expands a boss's attack references against the shared library.
    public func resolveAttacks(_ boss: BossDef) -> [ResolvedAttack] {
        var out: [ResolvedAttack] = []
        for (i, ref) in boss.attacks.enumerated() {
            guard let tpl = attacks[ref.use] else { continue }
            var strikes = tpl.strikes + ref.extraStrikes
            for k in strikes.indices {
                strikes[k].damage *= ref.damage * boss.stats.damage
                strikes[k].posture *= ref.posture
                strikes[k].move *= ref.moveScale
                if let e = ref.element, strikes[k].element == .none { strikes[k].element = e }
                if let s = ref.side { strikes[k].side = s }
                if let ts = ref.telegraphs, k < ts.count { strikes[k].telegraph = ts[k] }
            }
            if let t = ref.telegraph, !strikes.isEmpty {
                strikes[strikes.count - 1].telegraph = t
            }
            if let sw = ref.swapTo, !strikes.isEmpty, strikes[0].swapWeapon < 0 { strikes[0].swapWeapon = sw }
            if ref.aoe > 0, !strikes.isEmpty {
                strikes[strikes.count - 1].aoeRadius = max(strikes[strikes.count - 1].aoeRadius, min(ref.aoe, 3.2))
            }
            // Dual wielders alternate hands on string attacks for readability.
            let wt = WeaponCatalog.get(boss.weapons.first?.type ?? "shortsword")
            if wt.grip == .dual && ref.side == nil && strikes.count > 1 {
                for k in strikes.indices where k % 2 == 1 && strikes[k].side == "R" { strikes[k].side = "L" }
            }
            // Ranges in the library assume a baseline weapon for the template family
            // (sword 0.95 m, polearm 2.1 m, chain 4.0 m); shift them by this boss's real reach.
            let wv = boss.weapons.first ?? WeaponVisual()
            let baseline: Float = tpl.id.hasPrefix("chain_") ? 4.0 : (tpl.id.hasPrefix("pole_") ? 2.1 : 0.95)
            var reachDelta = WeaponCatalog.effectiveReach(wv) - baseline
            if ["leap", "lunge", "charge"].contains(tpl.category) { reachDelta = min(reachDelta, 1.0) }
            out.append(ResolvedAttack(id: "\(ref.use)#\(i)", name: ref.name.isEmpty ? tpl.name : ref.name, category: tpl.category,
                                      strikes: strikes, minRange: tpl.minRange, maxRange: max(0.6, tpl.maxRange + reachDelta) * max(0.5, ref.reach),
                                      weight: tpl.weight * ref.weight, cooldown: ref.cooldown ?? tpl.cooldown,
                                      opening: ref.opening ?? tpl.opening, speed: ref.speed,
                                      minPhase: ref.minPhase, maxPhase: ref.maxPhase, hardOnly: ref.hardOnly, signature: ref.signature))
        }
        return out
    }

    /// Checks cross references and the strict boss weapon rules (no ranged attacks).
    public func validate() {
        for w in weapons {
            if w.light.isEmpty { problems.append("weapon \(w.id): no light attacks") }
            if w.heavy.isEmpty { problems.append("weapon \(w.id): no heavy attack") }
            if WeaponCatalog.all[w.visual.type] == nil { problems.append("weapon \(w.id): unknown type \(w.visual.type)") }
        }
        for (_, b) in bosses {
            for ref in b.attacks where attacks[ref.use] == nil {
                problems.append("boss \(b.id): unknown attack '\(ref.use)'")
            }
            for w in b.weapons where WeaponCatalog.all[w.type] == nil {
                problems.append("boss \(b.id): unknown weapon type '\(w.type)'")
            }
            let resolved = resolveAttacks(b)
            for a in resolved {
                // Rule: every attack is close or mid range. Chain weapons reach at most ~6 m.
                if a.maxRange > 9.5 && a.category != "charge" {
                    problems.append("boss \(b.id): attack \(a.name) range \(a.maxRange) exceeds mid range")
                }
                for s in a.strikes where s.aoeRadius > 3.5 {
                    problems.append("boss \(b.id): attack \(a.name) burst radius \(s.aoeRadius) too large")
                }
            }
            if !b.arena.isEmpty && arenas[b.arena] == nil { problems.append("boss \(b.id): unknown arena \(b.arena)") }
        }
        for (_, e) in encounters {
            for bid in e.bosses where bosses[bid] == nil { problems.append("encounter \(e.id): unknown boss \(bid)") }
        }
    }
}
