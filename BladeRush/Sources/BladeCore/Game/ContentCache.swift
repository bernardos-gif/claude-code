// Caches generated content (characters, weapons, arenas) so retries are instant and the
// next boss can be pre-generated in the background while the prep screen is shown.
import Foundation

public enum ContentCache {
    private static let lock = NSLock()
    private static var characters: [String: BuiltCharacter] = [:]
    private static var arenas: [String: BuiltArena] = [:]
    private static var weapons: [String: MeshData] = [:]
    private static let preloadQueue = DispatchQueue(label: "bladerush.preload", qos: .userInitiated)

    static func key<T: Encodable>(_ v: T, _ extra: String = "") -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let d = (try? enc.encode(v)) ?? Data()
        return String(Rng.hash(String(decoding: d, as: UTF8.self))) + extra
    }

    public static func character(_ v: CharacterVisual, skeleton: Skeleton, quality: Float) -> BuiltCharacter {
        let k = key(v, "q\(quality)")
        lock.lock()
        if let c = characters[k] { lock.unlock(); return c }
        lock.unlock()
        let built = CharacterBuilder.build(v, skeleton: skeleton, quality: quality)
        lock.lock(); characters[k] = built; lock.unlock()
        return built
    }

    public static func arena(_ d: ArenaDef, quality: Float) -> BuiltArena {
        let k = key(d, "q\(quality)")
        lock.lock()
        if let a = arenas[k] { lock.unlock(); return a }
        lock.unlock()
        let built = ArenaBuilder.build(d, quality: quality)
        lock.lock(); arenas[k] = built; lock.unlock()
        return built
    }

    public static func weaponMesh(_ v: WeaponVisual) -> MeshData {
        let k = key(v)
        lock.lock()
        if let m = weapons[k] { lock.unlock(); return m }
        lock.unlock()
        let m = WeaponCatalog.mesh(v)
        lock.lock(); weapons[k] = m; lock.unlock()
        return m
    }

    /// Generates everything an encounter needs on a background queue.
    public static func preload(encounter: EncounterDef, data: GameDataStore, quality: Float, playerVisual: CharacterVisual) {
        let bosses = encounter.bosses.compactMap { data.bosses[$0] }
        let arenaId = encounter.arena.isEmpty ? (bosses.first?.arena ?? "") : encounter.arena
        let arenaDef = data.arenas[arenaId]
        preloadQueue.async {
            let t0 = Date()
            if let a = arenaDef { _ = arena(a, quality: quality) }
            _ = character(playerVisual, skeleton: Skeleton(playerVisual.body), quality: quality)
            for b in bosses {
                _ = character(b.visual, skeleton: Skeleton(b.visual.body), quality: quality)
                for w in b.weapons { _ = weaponMesh(w) }
            }
            logInfo(String(format: "preloaded %@ in %.0f ms", encounter.id, Date().timeIntervalSince(t0) * 1000), "load")
        }
    }

    public static func clear() {
        lock.lock()
        characters.removeAll(); arenas.removeAll(); weapons.removeAll()
        lock.unlock()
    }
}
