// Gameplay events consumed by effects, audio, camera, UI and stats.
import Foundation

public enum GameEvent {
    case hit(attacker: Int, target: Int, point: Vec3, dir: Vec3, weight: HitWeight, damage: Float, playerVictim: Bool, element: Element, sound: SoundClass)
    case blocked(target: Int, point: Vec3, playerVictim: Bool)
    case parried(point: Vec3, perfect: Bool, telegraph: Telegraph, playerParried: Bool)
    case bossDeflect(point: Vec3)
    case dodged(perfect: Bool, position: Vec3)
    case whoosh(fighter: Int, position: Vec3, sound: SoundClass, weight: Float, speed: Float)
    case telegraph(fighter: Int, kind: Telegraph, position: Vec3)
    case postureBreak(target: Int, position: Vec3, isPlayer: Bool)
    case deathblow(point: Vec3)
    case phaseStart(fighter: Int, phase: Int, line: String, lighting: String)
    case death(fighter: Int, position: Vec3, isPlayer: Bool)
    case heal(position: Vec3)
    case healEmpty
    case footstep(position: Vec3, weight: Float)
    case burst(position: Vec3, radius: Float, element: Element)
    case crack(from: Vec3, to: Vec3, element: Element)
    case ability(weapon: String, position: Vec3)
    case swap(weapon: String)
    case chainHit(position: Vec3)
    case bleed(position: Vec3)
    case afterimage(fighter: Int)
    case subtitle(speaker: String, text: String, duration: Double)
    case landing(position: Vec3, weight: Float)
    case grab(position: Vec3)
    case disarm(position: Vec3)
    case counter(position: Vec3)
    case bossIntro(name: String, title: String)
    case victory
}

/// What controllers need from the world.
public protocol CombatContext: AnyObject {
    var now: Double { get }
    var tuning: CombatTuning { get }
    var lib: AnimLibrary { get }
    var windows: DefenseWindows { get }
    var hardMode: Bool { get }
    func emit(_ e: GameEvent)
    func target(for f: Fighter) -> Fighter?
    func boss(for f: Fighter) -> BossController?
    func slowMotion(duration: Double, scale: Double)
    func shake(_ amount: Float)
    func hitstop(_ seconds: Double)
    func clampToArena(_ p: Vec3, margin: Float) -> Vec3
    func spawnHazard(_ h: Hazard)
}

/// Delayed or persistent area attacks (ground cracks, bursts) owned by a fighter.
public struct Hazard {
    public var owner: Int
    public var center: Vec3
    public var radius: Float
    public var delay: Double
    public var damage: Float
    public var posture: Float
    public var telegraph: Telegraph
    public var element: Element
    public var weight: HitWeight
    public var ownerIsPlayer: Bool
    public var bleed: Int = 0

    public init(owner: Int, center: Vec3, radius: Float, delay: Double, damage: Float, posture: Float, telegraph: Telegraph,
                element: Element, weight: HitWeight, ownerIsPlayer: Bool, bleed: Int = 0) {
        self.owner = owner; self.center = center; self.radius = radius; self.delay = delay; self.damage = damage
        self.posture = posture; self.telegraph = telegraph; self.element = element; self.weight = weight
        self.ownerIsPlayer = ownerIsPlayer; self.bleed = bleed
    }
}

/// Per-fight statistics (stats screen, achievements, score).
public struct FightStats: Codable, Equatable {
    public var hitsTaken = 0
    public var damageTaken: Float = 0
    public var damageDealt: Float = 0
    public var parries = 0
    public var perfectParries = 0
    public var blocks = 0
    public var dodges = 0
    public var perfectDodges = 0
    public var deathblows = 0
    public var heals = 0
    public var abilityUses = 0
    public var time: Double = 0
    public init() {}
}
