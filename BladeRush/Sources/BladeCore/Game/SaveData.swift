// Persistent progress: unlocked tiers, defeated bosses, best times, stats, unlocks.
// Saved as JSON in ~/Library/Application Support/BladeRush/save.json after every boss.
import Foundation

public struct LifetimeStats: Codable, Equatable {
    public var bossesDefeated = 0
    public var deaths = 0
    public var parries = 0
    public var perfectParries = 0
    public var perfectDodges = 0
    public var dodges = 0
    public var deathblows = 0
    public var hitsTaken = 0
    public var damageDealt: Float = 0
    public var playTime: Double = 0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LifetimeStats()
        bossesDefeated = try c.v(.bossesDefeated, d.bossesDefeated); deaths = try c.v(.deaths, d.deaths); parries = try c.v(.parries, d.parries)
        perfectParries = try c.v(.perfectParries, d.perfectParries); perfectDodges = try c.v(.perfectDodges, d.perfectDodges)
        dodges = try c.v(.dodges, d.dodges); deathblows = try c.v(.deathblows, d.deathblows); hitsTaken = try c.v(.hitsTaken, d.hitsTaken)
        damageDealt = try c.v(.damageDealt, d.damageDealt); playTime = try c.v(.playTime, d.playTime)
    }
}

public struct SaveData: Codable, Equatable {
    public var version = 1
    public var unlockedTier = 1
    public var defeated: [String] = []
    public var hardDefeated: [String] = []
    public var bestTimes: [String: Double] = [:]
    public var deaths: [String: Int] = [:]
    public var attempts: [String: Int] = [:]
    public var stats = LifetimeStats()
    public var endlessBest = 0
    public var endlessBestBosses = 0
    public var hardModeUnlocked = false
    public var unlockedSkins: [String] = ["default"]
    public var unlockedTrails: [String] = ["default"]
    public var achievements: [String] = []
    public var equippedSkin: [String: String] = [:]
    public var equippedTrail: [String: String] = [:]
    public var lastWeapon = "katana"

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SaveData()
        version = try c.v(.version, d.version); unlockedTier = try c.v(.unlockedTier, d.unlockedTier); defeated = try c.v(.defeated, d.defeated)
        hardDefeated = try c.v(.hardDefeated, d.hardDefeated); bestTimes = try c.v(.bestTimes, d.bestTimes); deaths = try c.v(.deaths, d.deaths)
        attempts = try c.v(.attempts, d.attempts); stats = try c.v(.stats, d.stats); endlessBest = try c.v(.endlessBest, d.endlessBest)
        endlessBestBosses = try c.v(.endlessBestBosses, d.endlessBestBosses); hardModeUnlocked = try c.v(.hardModeUnlocked, d.hardModeUnlocked)
        unlockedSkins = try c.v(.unlockedSkins, d.unlockedSkins); unlockedTrails = try c.v(.unlockedTrails, d.unlockedTrails)
        achievements = try c.v(.achievements, d.achievements); equippedSkin = try c.v(.equippedSkin, d.equippedSkin)
        equippedTrail = try c.v(.equippedTrail, d.equippedTrail); lastWeapon = try c.v(.lastWeapon, d.lastWeapon)
    }

    public func isDefeated(_ id: String) -> Bool { defeated.contains(id) }

    public mutating func unlock(skin: String) -> Bool {
        guard !unlockedSkins.contains(skin) else { return false }
        unlockedSkins.append(skin); return true
    }
    public mutating func unlock(trail: String) -> Bool {
        guard !unlockedTrails.contains(trail) else { return false }
        unlockedTrails.append(trail); return true
    }
    public mutating func achieve(_ a: String) -> Bool {
        guard !achievements.contains(a) else { return false }
        achievements.append(a); return true
    }

    public static func load() -> SaveData {
        guard let d = try? Data(contentsOf: Paths.saveFile) else { return SaveData() }
        do { return try JSONDecoder().decode(SaveData.self, from: d) } catch {
            logError("save.json unreadable (\(JSONUtil.describe(error))); backing it up and starting fresh", "save")
            let bak = Paths.saveFile.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: Paths.saveFile, to: bak)
            return SaveData()
        }
    }

    public func save() {
        Paths.ensureDirectories()
        guard let d = try? JSONUtil.encodePretty(self) else { return }
        let tmp = Paths.saveFile.appendingPathExtension("tmp")
        do {
            try d.write(to: tmp)
            _ = try? FileManager.default.removeItem(at: Paths.saveFile)
            try FileManager.default.moveItem(at: tmp, to: Paths.saveFile)
            logInfo("progress saved", "save")
        } catch { logError("could not save progress: \(error)", "save") }
    }
}
