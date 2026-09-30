// Procedural weapon meshes and weapon type catalog (grip style, hitboxes, trail points,
// flexible chain specs). Every boss and player weapon is built from one of these types.
//
// Weapon local frame: origin at the main grip, +Z along the blade toward the tip,
// +Y toward the cutting edge, handle extends toward -Z.
// Material slots: 0 blade metal, 1 handle, 2 guard/trim, 3 glowing edge, 4 wood,
//                 5 dark metal, 6 cloth/rope, 7 special (ice/lava/crystal/shadow).
import Foundation

public enum SoundClass: String, Codable { case blade, heavyBlade, blunt, chain, pole, dagger, fan }

public struct WeaponHitbox: Equatable {
    public var a: Vec3
    public var b: Vec3
    public var radius: Float
    public init(_ a: Vec3, _ b: Vec3, _ r: Float) { self.a = a; self.b = b; radius = r }
}

public struct FlexSpec: Equatable {
    public var chainLength: Float      // fully extended reach from the grip
    public var restLength: Float       // dangling length when idle
    public var headRadius: Float
    public var links: Int
    public var head: String            // weight, anchor, ball, dart, sickle, blade, staff
}

public struct WeaponType {
    public var id: String
    public var name: String
    public var grip: GripStyle
    public var twoHandOffset: Float
    public var hitboxes: [WeaponHitbox]
    public var trailBase: Vec3
    public var trailTip: Vec3
    public var sound: SoundClass
    public var flex: FlexSpec?
    public var offhand: String?        // left-hand item type id (shield, dagger...)
    public var mirrorOffhand: Bool     // dual wield: same weapon in the left hand
    public var weight: Float           // 0 light .. 1 very heavy (sound / hitstop flavor)
    public var reach: Float { hitboxes.map { max(vlength($0.a), vlength($0.b)) + $0.radius }.max() ?? 1 }
}

/// Per-instance look of a weapon.
public struct WeaponVisual: Codable, Equatable {
    public var type = "shortsword"
    public var scale: Float = 1
    public var metal = "#9a9ca3"
    public var handle = "#3a2414"
    public var trim = "#8a6a2c"
    public var glow = "#000000"
    public var glowStrength: Float = 0
    public var element: Element = .none
    public var rust: Float = 0
    public var trail = ""              // trail color override
    public var trail2 = ""

    public init() {}
    public init(type: String) { self.type = type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WeaponVisual()
        type = try c.v(.type, d.type); scale = try c.v(.scale, d.scale); metal = try c.v(.metal, d.metal)
        handle = try c.v(.handle, d.handle); trim = try c.v(.trim, d.trim); glow = try c.v(.glow, d.glow)
        glowStrength = try c.v(.glowStrength, d.glowStrength); element = try c.v(.element, d.element)
        rust = try c.v(.rust, d.rust); trail = try c.v(.trail, d.trail); trail2 = try c.v(.trail2, d.trail2)
    }
}

public enum WeaponCatalog {
    static func t(_ id: String, _ name: String, _ grip: GripStyle, off: Float = -0.12, hit: [WeaponHitbox],
                  trail: (Float, Float), sound: SoundClass, weight: Float, flex: FlexSpec? = nil,
                  offhand: String? = nil, mirror: Bool = false) -> WeaponType {
        WeaponType(id: id, name: name, grip: grip, twoHandOffset: off, hitboxes: hit,
                   trailBase: Vec3(0, 0, trail.0), trailTip: Vec3(0, 0, trail.1), sound: sound,
                   flex: flex, offhand: offhand, mirrorOffhand: mirror, weight: weight)
    }
    static func z(_ a: Float, _ b: Float, _ r: Float) -> WeaponHitbox { WeaponHitbox(Vec3(0, 0, a), Vec3(0, 0, b), r) }

    public static let all: [String: WeaponType] = {
        var d: [String: WeaponType] = [:]
        let list: [WeaponType] = [
            // Player weapons
            t("katana", "Katana", .twoHand, off: -0.14, hit: [z(0.1, 0.8, 0.05)], trail: (0.15, 0.8), sound: .blade, weight: 0.35),
            t("greatsword", "Greatsword", .twoHand, off: -0.17, hit: [z(0.16, 1.32, 0.08)], trail: (0.2, 1.32), sound: .heavyBlade, weight: 0.85),
            t("dagger", "Twin Daggers", .dual, hit: [z(0.03, 0.32, 0.05)], trail: (0.05, 0.32), sound: .dagger, weight: 0.1, mirror: true),
            t("spear", "Spear", .polearm, off: 0.42, hit: [z(0.9, 2.05, 0.08)], trail: (1.5, 2.05), sound: .pole, weight: 0.45),
            t("kusarigama", "Kusarigama", .flexible, hit: [WeaponHitbox(Vec3(0, 0, 0.3), Vec3(0, 0.16, 0.44), 0.08)], trail: (0.3, 0.45),
              sound: .chain, weight: 0.3, flex: FlexSpec(chainLength: 4.2, restLength: 0.8, headRadius: 0.16, links: 26, head: "weight")),
            // Tier 1
            t("shortsword", "Shortsword", .oneHand, hit: [z(0.08, 0.62, 0.05)], trail: (0.12, 0.62), sound: .blade, weight: 0.3),
            t("hand_axe", "Hand Axe", .oneHand, hit: [WeaponHitbox(Vec3(0, 0.02, 0.38), Vec3(0, 0.1, 0.52), 0.1)], trail: (0.35, 0.52), sound: .blunt, weight: 0.45),
            t("club", "Spiked Club", .oneHand, hit: [z(0.3, 0.8, 0.08)], trail: (0.4, 0.8), sound: .blunt, weight: 0.5),
            t("machete", "Machete", .oneHand, hit: [z(0.08, 0.64, 0.06)], trail: (0.12, 0.64), sound: .blade, weight: 0.35),
            t("falchion", "Falchion", .oneHand, hit: [z(0.1, 0.72, 0.065)], trail: (0.14, 0.72), sound: .blade, weight: 0.4),
            // Tier 2
            t("longsword", "Longsword", .shield, hit: [z(0.1, 0.96, 0.05)], trail: (0.14, 0.96), sound: .blade, weight: 0.45, offhand: "kite_shield"),
            t("halberd", "Halberd", .polearm, off: 0.48, hit: [z(1.3, 2.35, 0.13)], trail: (1.7, 2.35), sound: .pole, weight: 0.75),
            t("mace", "Flanged Mace", .oneHand, hit: [z(0.45, 0.74, 0.11)], trail: (0.5, 0.74), sound: .blunt, weight: 0.6),
            t("war_pick", "War Pick", .twoHand, off: -0.2, hit: [WeaponHitbox(Vec3(0, 0, 0.72), Vec3(0, 0.22, 0.78), 0.1)], trail: (0.6, 0.8), sound: .blunt, weight: 0.65),
            t("arming_sword", "Arming Sword", .shield, hit: [z(0.1, 0.84, 0.05)], trail: (0.14, 0.84), sound: .blade, weight: 0.4, offhand: "buckler"),
            // Tier 3
            t("bo_staff", "Bo Staff", .polearm, off: 0.5, hit: [z(-0.85, 1.05, 0.06)], trail: (0.6, 1.05), sound: .pole, weight: 0.35),
            t("three_section_staff", "Three-Section Staff", .flexible, hit: [z(0.0, 0.55, 0.06)], trail: (0.2, 0.55), sound: .pole, weight: 0.4,
              flex: FlexSpec(chainLength: 1.9, restLength: 0.9, headRadius: 0.12, links: 10, head: "staff")),
            t("naginata", "Naginata", .polearm, off: 0.5, hit: [z(1.1, 2.2, 0.09)], trail: (1.5, 2.2), sound: .pole, weight: 0.5),
            t("tonfa", "Twin Tonfa", .dual, hit: [z(-0.15, 0.4, 0.07)], trail: (0.1, 0.4), sound: .blunt, weight: 0.3, mirror: true),
            t("meteor_hammer", "Meteor Hammer", .flexible, hit: [z(0.0, 0.15, 0.08)], trail: (0.0, 0.15), sound: .chain, weight: 0.6,
              flex: FlexSpec(chainLength: 4.0, restLength: 1.0, headRadius: 0.22, links: 24, head: "ball")),
            // Tier 4
            t("cutlass", "Cutlass", .oneHand, hit: [z(0.1, 0.74, 0.06)], trail: (0.14, 0.74), sound: .blade, weight: 0.38),
            t("boarding_axe", "Boarding Axe", .oneHand, hit: [WeaponHitbox(Vec3(0, 0.02, 0.5), Vec3(0, 0.12, 0.66), 0.11)], trail: (0.45, 0.68), sound: .blunt, weight: 0.5),
            t("anchor_chain", "Anchor on a Chain", .flexible, hit: [z(0.0, 0.2, 0.1)], trail: (0.0, 0.2), sound: .chain, weight: 0.95,
              flex: FlexSpec(chainLength: 4.6, restLength: 1.2, headRadius: 0.42, links: 22, head: "anchor")),
            t("harpoon", "Harpoon", .polearm, off: 0.45, hit: [z(1.0, 2.1, 0.08)], trail: (1.5, 2.1), sound: .pole, weight: 0.5),
            t("hook_sword", "Hook Blades", .dual, hit: [z(0.1, 0.82, 0.07)], trail: (0.14, 0.86), sound: .blade, weight: 0.4, mirror: true),
            // Tier 5
            t("warhammer", "Warhammer", .twoHand, off: -0.3, hit: [WeaponHitbox(Vec3(0, -0.1, 1.2), Vec3(0, 0.18, 1.25), 0.16)], trail: (1.0, 1.32), sound: .blunt, weight: 0.9),
            t("molten_greatblade", "Molten Greatblade", .twoHand, off: -0.2, hit: [z(0.2, 1.55, 0.11)], trail: (0.25, 1.55), sound: .heavyBlade, weight: 0.95),
            t("flail", "Flail", .flexible, hit: [z(0.0, 0.4, 0.06)], trail: (0.1, 0.4), sound: .chain, weight: 0.6,
              flex: FlexSpec(chainLength: 1.7, restLength: 0.55, headRadius: 0.17, links: 10, head: "spikeball")),
            t("maul", "Maul", .twoHand, off: -0.35, hit: [WeaponHitbox(Vec3(0, 0, 1.18), Vec3(0, 0, 1.48), 0.2)], trail: (1.1, 1.5), sound: .blunt, weight: 1.0),
            t("giant_cleaver", "Giant Cleaver", .twoHand, off: -0.2, hit: [WeaponHitbox(Vec3(0, 0.12, 0.25), Vec3(0, 0.12, 1.45), 0.16)], trail: (0.3, 1.45), sound: .heavyBlade, weight: 1.0),
            // Tier 6
            t("zweihander", "Zweihander", .twoHand, off: -0.22, hit: [z(0.2, 1.52, 0.07)], trail: (0.25, 1.52), sound: .heavyBlade, weight: 0.85),
            t("glaive", "Glaive", .polearm, off: 0.5, hit: [z(1.2, 2.3, 0.11)], trail: (1.5, 2.3), sound: .pole, weight: 0.6),
            t("frost_rapier", "Frost Rapier", .oneHand, hit: [z(0.1, 1.02, 0.045)], trail: (0.14, 1.02), sound: .blade, weight: 0.25),
            t("lance", "Lance", .polearm, off: 0.45, hit: [z(0.8, 2.75, 0.1)], trail: (1.5, 2.75), sound: .pole, weight: 0.8),
            t("bardiche", "Bardiche", .polearm, off: 0.45, hit: [WeaponHitbox(Vec3(0, 0.1, 1.2), Vec3(0, 0.12, 1.95), 0.13)], trail: (1.3, 1.95), sound: .heavyBlade, weight: 0.8),
            // Tier 7
            t("rapier", "Rapier", .oneHand, hit: [z(0.1, 1.02, 0.04)], trail: (0.14, 1.02), sound: .blade, weight: 0.2),
            t("saber", "Dual Sabers", .dual, hit: [z(0.1, 0.8, 0.055)], trail: (0.14, 0.8), sound: .blade, weight: 0.3, mirror: true),
            t("sword_cane", "Sword Cane", .oneHand, hit: [z(0.06, 0.86, 0.04)], trail: (0.1, 0.86), sound: .blade, weight: 0.2),
            t("rapier_dagger", "Rapier and Parrying Dagger", .dual, hit: [z(0.1, 1.02, 0.04)], trail: (0.14, 1.02), sound: .blade, weight: 0.22, offhand: "parrying_dagger"),
            t("estoc", "Estoc", .twoHand, off: -0.16, hit: [z(0.15, 1.3, 0.045)], trail: (0.2, 1.3), sound: .blade, weight: 0.5),
            // Tier 8
            t("war_fan", "War Fan", .oneHand, hit: [WeaponHitbox(Vec3(0, 0, 0.1), Vec3(0, 0, 0.46), 0.14)], trail: (0.2, 0.46), sound: .fan, weight: 0.2),
            t("chain_whip", "Chain Whip", .flexible, hit: [z(0.0, 0.2, 0.05)], trail: (0.0, 0.2), sound: .chain, weight: 0.3,
              flex: FlexSpec(chainLength: 3.6, restLength: 1.4, headRadius: 0.12, links: 20, head: "dart")),
            t("kama", "Twin Kama", .dual, hit: [WeaponHitbox(Vec3(0, 0, 0.3), Vec3(0, 0.2, 0.42), 0.07)], trail: (0.3, 0.45), sound: .blade, weight: 0.25, mirror: true),
            t("storm_spear", "Storm Spear", .polearm, off: 0.42, hit: [z(0.9, 2.15, 0.09)], trail: (1.5, 2.15), sound: .pole, weight: 0.5),
            t("guandao", "Guandao", .polearm, off: 0.5, hit: [z(1.2, 2.35, 0.12)], trail: (1.5, 2.35), sound: .heavyBlade, weight: 0.75),
            // Tier 9
            t("katar", "Dual Katars", .dual, hit: [z(0.05, 0.36, 0.05)], trail: (0.08, 0.36), sound: .dagger, weight: 0.15, mirror: true),
            t("reaper_scythe", "Reaper Scythe", .polearm, off: 0.5, hit: [WeaponHitbox(Vec3(0, 0.05, 1.85), Vec3(0, 0.85, 1.55), 0.1)], trail: (1.7, 1.95), sound: .heavyBlade, weight: 0.7),
            t("urumi", "Urumi", .flexible, hit: [z(0.0, 0.25, 0.05)], trail: (0.0, 0.25), sound: .chain, weight: 0.25,
              flex: FlexSpec(chainLength: 3.0, restLength: 1.6, headRadius: 0.1, links: 22, head: "blade")),
            t("shadow_blade", "Twin Shadow Blades", .dual, hit: [z(0.08, 0.74, 0.055)], trail: (0.1, 0.74), sound: .blade, weight: 0.28, mirror: true),
            // Off-hand items
            t("kite_shield", "Kite Shield", .shield, hit: [WeaponHitbox(Vec3(0, -0.2, 0.05), Vec3(0, 0.25, 0.05), 0.28)], trail: (0, 0), sound: .blunt, weight: 0.7),
            t("buckler", "Buckler", .shield, hit: [WeaponHitbox(Vec3(0, 0, 0.04), Vec3(0, 0, 0.06), 0.2)], trail: (0, 0), sound: .blunt, weight: 0.4),
            t("parrying_dagger", "Parrying Dagger", .oneHand, hit: [z(0.04, 0.36, 0.04)], trail: (0.06, 0.36), sound: .dagger, weight: 0.1),
        ]
        for w in list { d[w.id] = w }
        return d
    }()

    /// How much farther than a baseline one-handed sword (0.95 m) a weapon reaches.
    /// Used to scale the AI's attack ranges to the boss's actual weapon.
    public static func rangeScale(_ v: WeaponVisual) -> Float {
        clampf(effectiveReach(v) / 0.95, 0.55, 3.2)
    }

    /// Practical striking distance of a weapon from the hand (chains: ~85% of full length).
    public static func effectiveReach(_ v: WeaponVisual) -> Float {
        let t = get(v.type)
        return (t.flex.map { $0.chainLength * 0.85 } ?? t.reach) * v.scale
    }

    public static func get(_ id: String) -> WeaponType {
        if let w = all[id] { return w }
        logWarn("unknown weapon type '\(id)', using shortsword", "weapons")
        return all["shortsword"]!
    }

    // MARK: - Materials

    public static func materials(_ v: WeaponVisual) -> [MaterialDesc] {
        let glow = parseColor(v.glow)
        var blade = MaterialDesc.steel(parseColor(v.metal), rough: 0.22)
        blade.rust = v.rust
        blade.wear = 0.35
        if v.rust > 0.3 { blade.kind = .rustIron; blade.roughness = 0.5 }
        var edge = MaterialDesc.emissive(glow, strength: max(0.001, v.glowStrength * 6))
        if v.glowStrength <= 0 { edge = MaterialDesc.steel(parseColor(v.metal) * 1.15, rough: 0.12) }
        let handle = MaterialDesc.leather(parseColor(v.handle))
        let trim = MaterialDesc.gold(parseColor(v.trim))
        let wood = MaterialDesc.wood(parseColor(v.handle) * 1.2)
        let dark = MaterialDesc.steel(srgbHex(0x2B2C31), rough: 0.4)
        let rope = MaterialDesc.fabric(srgbHex(0x6B5A3E))
        var special: MaterialDesc
        switch v.element {
        case .ice: special = MaterialDesc(kind: .ice, color: srgbHex(0xA8E4FF), metallic: 0, roughness: 0.05, emissive: srgbHex(0x6FC8FF), emissiveStrength: 1.2, wear: 0, dirt: 0, frost: 0.4)
        case .fire: special = MaterialDesc(kind: .lava, color: srgbHex(0x2A1510), metallic: 0, roughness: 0.6, emissive: srgbHex(0xFF5A1A), emissiveStrength: 7, wear: 0, dirt: 0)
        case .shadow: special = MaterialDesc(kind: .obsidian, color: srgbHex(0x0C0A12), metallic: 0.3, roughness: 0.1, emissive: srgbHex(0x7B3BFF), emissiveStrength: 2.5, wear: 0, dirt: 0)
        case .lightning: special = MaterialDesc(kind: .crystal, color: srgbHex(0xCFE6FF), metallic: 0.2, roughness: 0.1, emissive: srgbHex(0x8FC8FF), emissiveStrength: 5, wear: 0, dirt: 0)
        default: special = MaterialDesc(kind: .crystal, color: glow, metallic: 0.1, roughness: 0.1, emissive: glow, emissiveStrength: 3, wear: 0, dirt: 0)
        }
        return [blade, handle, trim, edge, wood, dark, rope, special]
    }

    // MARK: - Mesh construction

    /// Builds the rigid part of a weapon (flexible weapons: handle only; the chain and
    /// head are separate meshes from `flexHeadMesh` / `chainLinkMesh`).
    public static func mesh(_ v: WeaponVisual) -> MeshData {
        var b = MeshBuilder()
        let glowing = v.glowStrength > 0
        switch v.type {
        case "katana":
            handle(&b, from: -0.27, to: 0.03, r: 0.017, wrap: true)
            b.material = 2; b.cylinder(from: Vec3(0, 0, 0.025), to: Vec3(0, 0, 0.04), r0: 0.042, r1: 0.042, segments: 16)
            blade(&b, z0: 0.04, length: 0.74, width: { _ in 0.017 }, thick: 0.0045, curve: -0.035, single: true, glow: glowing, tip: 0.1)
            b.material = 2; b.sphere(center: Vec3(0, 0, -0.275), radius: 0.02, segments: 8)
        case "greatsword", "zweihander":
            let L: Float = v.type == "greatsword" ? 1.26 : 1.3
            handle(&b, from: -0.36, to: 0.06, r: 0.02, wrap: true)
            b.material = 2; b.box(center: Vec3(0, 0, 0.07), half: Vec3(0.022, 0.2, 0.022), bevel: 0.008)
            if v.type == "zweihander" {
                b.material = 2; b.box(center: Vec3(0, 0, 0.3), half: Vec3(0.012, 0.06, 0.01), bevel: 0.004)
            }
            blade(&b, z0: 0.09, length: L, width: { u in 0.042 - 0.012 * u }, thick: 0.007, curve: 0, single: false, glow: glowing, tip: 0.12)
            b.material = 2; b.sphere(center: Vec3(0, 0, -0.38), radius: 0.032, segments: 10)
        case "molten_greatblade":
            handle(&b, from: -0.38, to: 0.06, r: 0.024, wrap: true)
            b.material = 5; b.box(center: Vec3(0, 0, 0.08), half: Vec3(0.03, 0.17, 0.03), bevel: 0.01)
            blade(&b, z0: 0.1, length: 1.45, width: { u in 0.085 - 0.02 * u + 0.012 * sin(u * 30) }, thick: 0.014, curve: 0, single: false, glow: true, tip: 0.15, mat: 7)
        case "giant_cleaver":
            handle(&b, from: -0.4, to: 0.06, r: 0.024, wrap: true)
            b.material = 0
            b.extrude([Vec2(-0.02, 0.1), Vec2(0.24, 0.12), Vec2(0.26, 1.46), Vec2(0.0, 1.5), Vec2(-0.03, 0.4)],
                      thickness: [0.012, 0.002, 0.002, 0.01, 0.014])
            b.material = 5; b.cylinder(from: Vec3(0, 0.05, 1.2), to: Vec3(0.02, 0.05, 1.2), r0: 0.035, r1: 0.035, segments: 10)
        case "dagger", "parrying_dagger", "katar":
            if v.type == "katar" {
                b.material = 2
                b.box(center: Vec3(0.0, 0.05, -0.05), half: Vec3(0.012, 0.012, 0.09), bevel: 0.004)
                b.box(center: Vec3(0.0, -0.05, -0.05), half: Vec3(0.012, 0.012, 0.09), bevel: 0.004)
                handle(&b, from: -0.02, to: 0.02, r: 0.015, wrap: true, axis: Vec3(0, 1, 0), span: 0.05)
                blade(&b, z0: 0.03, length: 0.33, width: { u in 0.045 * (1 - u * 0.7) }, thick: 0.008, curve: 0, single: false, glow: glowing, tip: 0.35)
            } else {
                handle(&b, from: -0.11, to: 0.0, r: 0.014, wrap: true)
                b.material = 2
                let q: Float = v.type == "parrying_dagger" ? 0.13 : 0.05
                b.box(center: Vec3(0, 0, 0.005), half: Vec3(0.012, q, 0.01), bevel: 0.004)
                if v.type == "parrying_dagger" { b.torus(center: Vec3(0.02, 0, 0.0), majorR: 0.035, minorR: 0.005, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2)) }
                blade(&b, z0: 0.015, length: v.type == "parrying_dagger" ? 0.34 : 0.3, width: { u in 0.02 * (1 - u * 0.45) }, thick: 0.005, curve: 0, single: false, glow: glowing, tip: 0.3)
            }
        case "spear", "storm_spear", "harpoon", "lance":
            if v.type == "lance" {
                b.material = 2
                b.lathe([(0.03, -0.55), (0.035, 0.0), (0.03, 0.2), (0.16, 0.3), (0.13, 0.36), (0.075, 0.55), (0.05, 1.5), (0.022, 2.4), (0.0, 2.8)], segments: 14)
                b.material = 1; b.cylinder(from: Vec3(0, 0, -0.1), to: Vec3(0, 0, 0.18), r0: 0.034, r1: 0.034, segments: 10)
            } else {
                b.material = 4; b.cylinder(from: Vec3(0, 0, -0.55), to: Vec3(0, 0, 1.82), r0: 0.019, r1: 0.017, segments: 10)
                b.material = 2; b.cylinder(from: Vec3(0, 0, 1.78), to: Vec3(0, 0, 1.86), r0: 0.024, r1: 0.022, segments: 10)
                b.cylinder(from: Vec3(0, 0, -0.58), to: Vec3(0, 0, -0.5), r0: 0.024, r1: 0.022, segments: 10)
                if v.type == "harpoon" {
                    blade(&b, z0: 1.85, length: 0.24, width: { u in 0.03 * (1 - u) + 0.005 }, thick: 0.008, curve: 0, single: false, glow: glowing, tip: 0.5)
                    b.material = 0
                    for s: Float in [-1, 1] {
                        b.extrude([Vec2(0.0, 1.9), Vec2(0.06 * s, 1.84), Vec2(0.012 * s, 1.95)], thickness: [0.006, 0.002, 0.006])
                    }
                    b.material = 6; b.torus(center: Vec3(0, 0, 1.0), majorR: 0.028, minorR: 0.008, rot: .identity)
                } else {
                    blade(&b, z0: 1.85, length: 0.3, width: { u in 0.038 * sin(Float.pi * min(1, u * 1.3 + 0.15)) + 0.003 }, thick: 0.008, curve: 0, single: false, glow: glowing, tip: 0.2)
                    if v.type == "storm_spear" {
                        b.material = 7
                        for s: Float in [-1, 1] {
                            b.extrude([Vec2(0.02 * s, 1.8), Vec2(0.13 * s, 1.72), Vec2(0.07 * s, 1.84), Vec2(0.16 * s, 1.8), Vec2(0.03 * s, 1.95)],
                                      thickness: [0.005, 0.002, 0.004, 0.002, 0.005])
                        }
                    }
                }
            }
        case "shortsword", "arming_sword", "longsword":
            let L: Float = v.type == "shortsword" ? 0.56 : (v.type == "arming_sword" ? 0.76 : 0.88)
            handle(&b, from: v.type == "longsword" ? -0.2 : -0.12, to: 0.0, r: 0.016, wrap: true)
            b.material = 2; b.box(center: Vec3(0, 0, 0.012), half: Vec3(0.014, 0.1, 0.012), bevel: 0.005)
            blade(&b, z0: 0.025, length: L, width: { u in 0.026 - 0.008 * u }, thick: 0.005, curve: 0, single: false, glow: glowing, tip: 0.12)
            b.material = 2; b.sphere(center: Vec3(0, 0, v.type == "longsword" ? -0.22 : -0.14), radius: 0.024, segments: 10)
        case "machete", "falchion", "cutlass", "saber", "shadow_blade", "hook_sword":
            handle(&b, from: -0.12, to: 0.0, r: 0.016, wrap: true)
            b.material = 2
            if v.type == "cutlass" || v.type == "saber" {
                b.torus(center: Vec3(0, -0.035, -0.05), majorR: 0.06, minorR: 0.006, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2), segments: 16, sides: 6, arc: kPi)
            }
            b.box(center: Vec3(0, 0, 0.01), half: Vec3(0.014, 0.05, 0.01), bevel: 0.004)
            let L: Float = ["machete": 0.58, "falchion": 0.66, "cutlass": 0.7, "saber": 0.76, "shadow_blade": 0.7, "hook_sword": 0.72][v.type] ?? 0.6
            let widthFn: (Float) -> Float
            switch v.type {
            case "machete": widthFn = { u in 0.034 + 0.012 * u }
            case "falchion": widthFn = { u in 0.026 + 0.03 * smoothstepf(0.3, 0.85, u) }
            case "cutlass": widthFn = { u in 0.03 + 0.008 * u }
            case "hook_sword": widthFn = { _ in 0.022 }
            default: widthFn = { _ in 0.02 }
            }
            let curve: Float = v.type == "machete" ? 0.0 : (v.type == "shadow_blade" ? -0.07 : -0.04)
            blade(&b, z0: 0.02, length: L, width: widthFn, thick: 0.005, curve: curve, single: true, glow: glowing, tip: v.type == "machete" ? 0.06 : 0.14,
                  mat: v.type == "shadow_blade" ? 7 : 0)
            if v.type == "hook_sword" {
                b.material = 0
                b.torus(center: Vec3(0, 0.07, 0.73), majorR: 0.07, minorR: 0.01, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2), segments: 12, sides: 6, arc: kPi * 1.2)
                b.box(center: Vec3(0, -0.07, 0.0), half: Vec3(0.008, 0.05, 0.03), bevel: 0.004)
            }
        case "hand_axe", "boarding_axe":
            let len: Float = v.type == "hand_axe" ? 0.5 : 0.66
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.1), to: Vec3(0, 0, len), r0: 0.018, r1: 0.02, segments: 10)
            b.material = 0
            let z0 = len - 0.16
            b.extrude([Vec2(0.0, z0), Vec2(0.07, z0 - 0.04), Vec2(0.14, z0 - 0.05), Vec2(0.15, z0 + 0.2), Vec2(0.07, z0 + 0.17), Vec2(0.0, z0 + 0.14)],
                      thickness: [0.018, 0.009, 0.002, 0.002, 0.009, 0.018])
            if v.type == "boarding_axe" {
                b.extrude([Vec2(0.0, z0 + 0.02), Vec2(-0.12, z0 + 0.07), Vec2(0.0, z0 + 0.12)], thickness: [0.012, 0.003, 0.012])
            }
            b.material = 1; b.cylinder(from: Vec3(0, 0, -0.1), to: Vec3(0, 0, 0.1), r0: 0.021, r1: 0.021, segments: 10)
        case "club":
            b.material = 4
            b.lathe([(0.0, -0.12), (0.022, -0.1), (0.02, 0.2), (0.045, 0.6), (0.05, 0.78), (0.0, 0.82)], segments: 10)
            b.material = 5
            for k in 0..<10 {
                let a = Float(k) * 2.4
                let zz: Float = 0.45 + Float(k) * 0.035
                let dir = Vec3(cos(a), sin(a), 0.2)
                b.cylinder(from: Vec3(cos(a) * 0.035, sin(a) * 0.035, zz), to: Vec3(cos(a) * 0.035, sin(a) * 0.035, zz) + dir * 0.05, r0: 0.007, r1: 0.001, segments: 5, caps: false)
            }
        case "mace":
            handle(&b, from: -0.14, to: 0.1, r: 0.018, wrap: true)
            b.material = 5; b.cylinder(from: Vec3(0, 0, 0.1), to: Vec3(0, 0, 0.55), r0: 0.017, r1: 0.017, segments: 10)
            b.material = 0; b.sphere(center: Vec3(0, 0, 0.62), radius: 0.055, segments: 12)
            for k in 0..<7 {
                let a = Float(k) / 7 * kTwoPi
                b.box(center: Vec3(cos(a) * 0.06, sin(a) * 0.06, 0.62), half: Vec3(0.035, 0.006, 0.08), rot: Quat(axis: Vec3(0, 0, 1), angle: a), bevel: 0.004)
            }
        case "war_pick":
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.35), to: Vec3(0, 0, 0.82), r0: 0.02, r1: 0.022, segments: 10)
            b.material = 1; b.cylinder(from: Vec3(0, 0, -0.35), to: Vec3(0, 0, -0.05), r0: 0.024, r1: 0.024, segments: 10)
            b.material = 0
            b.box(center: Vec3(0, 0, 0.76), half: Vec3(0.03, 0.035, 0.05), bevel: 0.008)
            b.cylinder(from: Vec3(0, 0.03, 0.76), to: Vec3(0, 0.26, 0.7), r0: 0.022, r1: 0.002, segments: 8)
            b.box(center: Vec3(0, -0.07, 0.76), half: Vec3(0.03, 0.04, 0.03), bevel: 0.008)
        case "warhammer", "maul":
            let isMaul = v.type == "maul"
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.5), to: Vec3(0, 0, isMaul ? 1.3 : 1.2), r0: 0.024, r1: 0.026, segments: 10)
            b.material = 1; b.cylinder(from: Vec3(0, 0, -0.5), to: Vec3(0, 0, -0.1), r0: 0.028, r1: 0.028, segments: 10)
            b.material = isMaul ? 5 : 0
            if isMaul {
                b.box(center: Vec3(0, 0, 1.36), half: Vec3(0.13, 0.12, 0.16), bevel: 0.03)
                b.material = 2; b.box(center: Vec3(0, 0, 1.36), half: Vec3(0.135, 0.125, 0.02), bevel: 0.01)
            } else {
                b.box(center: Vec3(0, 0.04, 1.25), half: Vec3(0.06, 0.12, 0.07), bevel: 0.015)
                b.cylinder(from: Vec3(0, -0.07, 1.25), to: Vec3(0, -0.24, 1.2), r0: 0.03, r1: 0.003, segments: 8)
                b.cylinder(from: Vec3(0, 0, 1.3), to: Vec3(0, 0, 1.45), r0: 0.025, r1: 0.002, segments: 8)
            }
        case "halberd", "bardiche", "glaive", "naginata", "guandao", "reaper_scythe":
            let top: Float = ["halberd": 1.95, "bardiche": 1.5, "glaive": 1.75, "naginata": 1.6, "guandao": 1.7, "reaper_scythe": 1.9][v.type] ?? 1.8
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.55), to: Vec3(0, 0, top + 0.05), r0: 0.021, r1: 0.02, segments: 10)
            b.material = 2; b.cylinder(from: Vec3(0, 0, top - 0.06), to: Vec3(0, 0, top + 0.04), r0: 0.027, r1: 0.025, segments: 10)
            b.material = 0
            switch v.type {
            case "halberd":
                blade(&b, z0: top + 0.04, length: 0.36, width: { u in 0.02 * (1 - u) + 0.004 }, thick: 0.009, curve: 0, single: false, glow: glowing, tip: 0.3)
                b.extrude([Vec2(0.0, top - 0.12), Vec2(0.2, top - 0.2), Vec2(0.24, top + 0.05), Vec2(0.0, top + 0.06)], thickness: [0.012, 0.002, 0.002, 0.012])
                b.extrude([Vec2(0.0, top - 0.06), Vec2(-0.16, top + 0.02), Vec2(0.0, top + 0.02)], thickness: [0.01, 0.002, 0.01])
            case "bardiche":
                b.extrude([Vec2(0.0, top - 0.35), Vec2(0.1, top - 0.3), Vec2(0.14, top + 0.1), Vec2(0.07, top + 0.45), Vec2(0.02, top + 0.2), Vec2(0.0, top + 0.05)],
                          thickness: [0.012, 0.003, 0.002, 0.002, 0.008, 0.012])
            case "glaive", "naginata", "guandao":
                let L: Float = v.type == "naginata" ? 0.55 : 0.62
                let w: Float = v.type == "guandao" ? 0.07 : (v.type == "glaive" ? 0.06 : 0.035)
                blade(&b, z0: top + 0.03, length: L, width: { u in w * (1 - 0.3 * u) + (v.type == "guandao" ? 0.03 * smoothstepf(0.4, 0.8, u) : 0) },
                      thick: 0.008, curve: v.type == "naginata" ? -0.05 : -0.08, single: true, glow: glowing, tip: 0.2)
                if v.type == "guandao" {
                    b.material = 2; b.sphere(center: Vec3(0, -0.04, top), radius: 0.035, segments: 8)
                }
            default: // reaper scythe: long curved blade perpendicular to the shaft
                var rings: [[Vec3]] = []
                let n = 14
                for k in 0...n {
                    let u = Float(k) / Float(n)
                    let ang = u * 1.25
                    let r: Float = 0.62
                    let center = Vec3(0, sin(ang) * r, top + 0.05 - (1 - cos(ang)) * r * 0.9)
                    let w = 0.07 * (1 - u) + 0.004
                    let t: Float = 0.006 * (1 - u * 0.7) + 0.001
                    rings.append([center + Vec3(t, 0, 0), center + Vec3(0, 0, -w * 0.3), center + Vec3(-t, 0, 0), center + Vec3(0, 0, w)])
                }
                b.material = 0
                b.loft(rings.map { [$0[0], $0[1], $0[2], $0[3]] })
                if glowing {
                    b.material = 3
                    b.loft(rings.map { r in [r[3] + Vec3(0.002, 0, 0), r[3] + Vec3(-0.002, 0, 0), r[3] + Vec3(0, 0, 0.004)] })
                }
            }
        case "bo_staff":
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.95), to: Vec3(0, 0, 1.05), r0: 0.02, r1: 0.02, segments: 10)
            b.material = 2
            b.cylinder(from: Vec3(0, 0, -0.97), to: Vec3(0, 0, -0.85), r0: 0.024, r1: 0.024, segments: 10)
            b.cylinder(from: Vec3(0, 0, 0.95), to: Vec3(0, 0, 1.07), r0: 0.024, r1: 0.024, segments: 10)
        case "frost_rapier", "rapier", "rapier_dagger", "estoc", "sword_cane":
            let isEstoc = v.type == "estoc"
            if v.type == "sword_cane" {
                b.material = 5; b.lathe([(0.0, -0.18), (0.028, -0.16), (0.026, -0.1), (0.018, -0.05), (0.02, 0.0), (0.02, 0.04)], segments: 12)
            } else {
                handle(&b, from: isEstoc ? -0.28 : -0.13, to: 0.0, r: 0.014, wrap: true)
                b.material = 2
                b.box(center: Vec3(0, 0, 0.01), half: Vec3(0.012, 0.11, 0.008), bevel: 0.004)
                b.torus(center: Vec3(0, 0.0, -0.05), majorR: 0.055, minorR: 0.005, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2), segments: 16, sides: 6)
                b.torus(center: Vec3(0, 0.0, 0.03), majorR: 0.035, minorR: 0.004, rot: .identity, segments: 14, sides: 6)
                b.sphere(center: Vec3(0, 0, isEstoc ? -0.3 : -0.15), radius: 0.022, segments: 10)
            }
            let L: Float = isEstoc ? 1.18 : 0.98
            if v.type == "frost_rapier" {
                blade(&b, z0: 0.02, length: L, width: { u in 0.016 * (1 - u * 0.6) }, thick: 0.007, curve: 0, single: false, glow: true, tip: 0.1, mat: 7)
                b.material = 7
                for k in 0..<6 {
                    let zz: Float = 0.15 + Float(k) * 0.14
                    let s: Float = k % 2 == 0 ? 1 : -1
                    b.extrude([Vec2(0.0, zz), Vec2(0.05 * s, zz + 0.02), Vec2(0.0, zz + 0.06)], thickness: [0.004, 0.001, 0.004])
                }
            } else {
                blade(&b, z0: 0.02, length: L, width: { u in (isEstoc ? 0.014 : 0.011) * (1 - u * 0.5) }, thick: isEstoc ? 0.009 : 0.005,
                      curve: 0, single: false, glow: glowing, tip: 0.1)
            }
        case "war_fan":
            b.material = 5
            for k in 0..<9 {
                let a = (Float(k) / 8 - 0.5) * 2.2
                let dir = Vec3(0, sin(a), cos(a))
                b.cylinder(from: Vec3(0, 0, -0.04), to: dir * 0.45, r0: 0.006, r1: 0.004, segments: 5)
            }
            b.material = 6
            var poly: [Vec2] = [Vec2(0, 0.12)]
            for k in 0...16 {
                let a = (Float(k) / 16 - 0.5) * 2.2
                poly.append(Vec2(sin(a) * 0.44, cos(a) * 0.44))
            }
            poly.append(Vec2(0, 0.12))
            b.extrude(Array(poly.dropLast()), thickness: Array(repeating: 0.003, count: poly.count - 1))
            if glowing {
                b.material = 3
                b.torus(center: Vec3(0, 0, 0), majorR: 0.445, minorR: 0.005, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2) * Quat(axis: Vec3(0, 0, 1), angle: kPi / 2 - 1.1),
                        segments: 20, sides: 5, arc: 2.2)
            }
        case "kama":
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.12), to: Vec3(0, 0, 0.36), r0: 0.017, r1: 0.017, segments: 10)
            b.material = 0
            b.extrude([Vec2(0.0, 0.3), Vec2(0.12, 0.34), Vec2(0.22, 0.4), Vec2(0.1, 0.39), Vec2(0.0, 0.37)], thickness: [0.008, 0.004, 0.001, 0.003, 0.008])
        case "tonfa":
            b.material = 4
            b.cylinder(from: Vec3(0, -0.02, -0.18), to: Vec3(0, -0.02, 0.42), r0: 0.022, r1: 0.022, segments: 10)
            b.cylinder(from: Vec3(0, -0.02, 0.0), to: Vec3(0, 0.08, 0.0), r0: 0.016, r1: 0.016, segments: 8)
            b.material = 2; b.sphere(center: Vec3(0, 0.085, 0), radius: 0.02, segments: 8)
        case "kite_shield", "buckler":
            if v.type == "buckler" {
                b.material = 0
                b.lathe([(0.0, 0.06), (0.06, 0.055), (0.07, 0.04), (0.2, 0.02), (0.21, 0.0), (0.19, -0.005), (0.0, -0.005)], segments: 20)
                b.material = 2; b.torus(center: Vec3(0, 0, 0.012), majorR: 0.2, minorR: 0.012, segments: 24, sides: 6)
            } else {
                let poly = [Vec2(0, -0.45), Vec2(0.2, -0.12), Vec2(0.26, 0.18), Vec2(0.22, 0.32), Vec2(0.0, 0.36), Vec2(-0.22, 0.32), Vec2(-0.26, 0.18), Vec2(-0.2, -0.12)]
                b.material = 5
                b.extrude(poly.map { Vec2($0.x, $0.y) }, thickness: Array(repeating: 0.02, count: poly.count), center: Vec3(0, 0, 0.0),
                          rot: Quat(axis: Vec3(0, 1, 0), angle: -kPi / 2))
                b.material = 2
                b.box(center: Vec3(0, 0, 0.025), half: Vec3(0.03, 0.3, 0.008), bevel: 0.004)
                b.box(center: Vec3(0, 0.12, 0.025), half: Vec3(0.2, 0.025, 0.008), bevel: 0.004)
                b.sphere(center: Vec3(0, 0.1, 0.03), radius: 0.04, segments: 10)
            }
        case "three_section_staff":
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.1), to: Vec3(0, 0, 0.55), r0: 0.02, r1: 0.02, segments: 10)
            b.material = 2; b.cylinder(from: Vec3(0, 0, 0.52), to: Vec3(0, 0, 0.58), r0: 0.024, r1: 0.024, segments: 10)
        case "kusarigama":
            b.material = 4; b.cylinder(from: Vec3(0, 0, -0.18), to: Vec3(0, 0, 0.42), r0: 0.017, r1: 0.017, segments: 10)
            b.material = 1; b.cylinder(from: Vec3(0, 0, -0.1), to: Vec3(0, 0, 0.2), r0: 0.019, r1: 0.019, segments: 10)
            b.material = 0
            b.extrude([Vec2(-0.01, 0.36), Vec2(0.1, 0.38), Vec2(0.2, 0.45), Vec2(0.26, 0.56), Vec2(0.15, 0.46), Vec2(0.0, 0.42)],
                      thickness: [0.008, 0.005, 0.003, 0.001, 0.002, 0.008])
            if glowing {
                b.material = 3
                b.extrude([Vec2(0.1, 0.385), Vec2(0.2, 0.455), Vec2(0.26, 0.56), Vec2(0.19, 0.47)], thickness: [0.0035, 0.0035, 0.0035, 0.0035])
            }
            b.material = 2; b.torus(center: Vec3(0, 0, -0.2), majorR: 0.02, minorR: 0.005, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2))
        case "meteor_hammer", "urumi", "chain_whip", "flail", "anchor_chain":
            // Handle only: chain and head are separate meshes.
            if v.type == "anchor_chain" {
                b.material = 5; b.torus(center: Vec3(0, 0, 0.0), majorR: 0.05, minorR: 0.014, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2))
            } else if v.type == "meteor_hammer" {
                b.material = 6; b.torus(center: Vec3(0, 0, 0.0), majorR: 0.035, minorR: 0.01, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2))
            } else {
                handle(&b, from: -0.14, to: 0.1, r: 0.017, wrap: true)
                b.material = 2; b.box(center: Vec3(0, 0, 0.11), half: Vec3(0.016, 0.03, 0.012), bevel: 0.004)
                b.sphere(center: Vec3(0, 0, -0.15), radius: 0.02, segments: 8)
            }
        default:
            handle(&b, from: -0.12, to: 0.0, r: 0.016, wrap: true)
            blade(&b, z0: 0.02, length: 0.6, width: { _ in 0.024 }, thick: 0.005, curve: 0, single: false, glow: glowing, tip: 0.12)
        }
        var m = b.build(name: "weapon_\(v.type)", creaseDeg: 35)
        if v.scale != 1 { m = m.transformed(Mat4.scale(Vec3(repeating: v.scale)), name: m.name) }
        return m
    }

    /// Mesh for the head of a flexible weapon (weight, ball, anchor, dart, blade tip, staff section).
    public static func flexHeadMesh(_ v: WeaponVisual, head: String, radius r: Float) -> MeshData {
        var b = MeshBuilder()
        switch head {
        case "ball", "spikeball":
            b.material = 5; b.sphere(center: .zero, radius: r * 0.75, segments: 14)
            if head == "spikeball" {
                b.material = 0
                for k in 0..<14 {
                    let dir = vnormalize(Vec3(cos(Float(k) * 2.4) * sin(Float(k) * 0.7 + 0.3), cos(Float(k) * 0.7 + 0.3), sin(Float(k) * 2.4) * sin(Float(k) * 0.7 + 0.3)))
                    b.cylinder(from: dir * r * 0.65, to: dir * r * 1.2, r0: r * 0.14, r1: 0.002, segments: 6)
                }
            }
        case "anchor":
            b.material = 5
            b.cylinder(from: Vec3(0, 0, 0), to: Vec3(0, 0, r * 1.6), r0: r * 0.12, r1: r * 0.12, segments: 10)
            b.torus(center: Vec3(0, 0, -r * 0.1), majorR: r * 0.2, minorR: r * 0.05, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2))
            b.box(center: Vec3(0, 0, r * 0.3), half: Vec3(r * 0.08, r * 0.55, r * 0.07), bevel: r * 0.03)
            b.torus(center: Vec3(0, 0, r * 1.1), majorR: r * 0.75, minorR: r * 0.1, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2), segments: 18, sides: 8, arc: kPi)
            b.material = 0
            for s: Float in [-1, 1] {
                b.extrude([Vec2(s * r * 0.72, r * 1.1), Vec2(s * r * 0.95, r * 0.8), Vec2(s * r * 0.6, r * 0.95)], thickness: [r * 0.06, r * 0.01, r * 0.06],
                          center: .zero, rot: Quat(axis: Vec3(0, 1, 0), angle: 0))
            }
        case "dart":
            b.material = 0
            blade(&b, z0: 0, length: r * 2.2, width: { u in r * 0.4 * (1 - u) + 0.003 }, thick: 0.01, curve: 0, single: false, glow: v.glowStrength > 0, tip: 0.5)
        case "blade":
            b.material = 0
            blade(&b, z0: 0, length: r * 3, width: { _ in 0.012 }, thick: 0.002, curve: 0, single: false, glow: v.glowStrength > 0, tip: 0.3)
        case "staff":
            b.material = 4; b.cylinder(from: Vec3(0, 0, 0), to: Vec3(0, 0, 0.6), r0: 0.02, r1: 0.02, segments: 10)
            b.material = 2; b.cylinder(from: Vec3(0, 0, 0.55), to: Vec3(0, 0, 0.62), r0: 0.024, r1: 0.024, segments: 10)
        default: // weight
            b.material = 5
            b.lathe([(0.0, -r * 0.6), (r * 0.35, -r * 0.5), (r * 0.45, 0.0), (r * 0.35, r * 0.5), (0.0, r * 0.6)], segments: 8)
        }
        return b.build(name: "flexhead_\(head)", creaseDeg: 35)
    }

    /// One chain link (instanced along flexible weapons).
    public static func chainLinkMesh(rope: Bool) -> MeshData {
        var b = MeshBuilder()
        if rope {
            b.material = 6; b.cylinder(from: Vec3(0, 0, -0.06), to: Vec3(0, 0, 0.06), r0: 0.009, r1: 0.009, segments: 6, caps: false)
        } else {
            b.material = 5
            b.torus(center: .zero, majorR: 0.02, minorR: 0.005, rot: Quat(axis: Vec3(0, 1, 0), angle: kPi / 2) , segments: 10, sides: 5)
        }
        return b.build(name: rope ? "rope_segment" : "chain_link", creaseDeg: 60)
    }

    // MARK: - Helpers

    static func handle(_ b: inout MeshBuilder, from z0: Float, to z1: Float, r: Float, wrap: Bool, axis: Vec3 = Vec3(0, 0, 1), span: Float = 0) {
        b.material = 1
        if axis.y != 0 {
            b.cylinder(from: Vec3(0, -span, 0), to: Vec3(0, span, 0), r0: r, r1: r, segments: 10)
            return
        }
        var prof: [(Float, Float)] = []
        let n = wrap ? 14 : 2
        for k in 0...n {
            let t = Float(k) / Float(n)
            let bump: Float = wrap && k % 2 == 1 ? 0.0025 : 0
            prof.append((r + bump, z0 + (z1 - z0) * t))
        }
        b.lathe(prof, segments: 10)
    }

    /// Lofted blade with a diamond or single-edge cross section.
    static func blade(_ b: inout MeshBuilder, z0: Float, length L: Float, width: (Float) -> Float, thick: Float, curve: Float,
                      single: Bool, glow: Bool, tip: Float, mat: Int = 0) {
        let n = 18
        var rings: [[Vec3]] = []
        var edgeLine: [Vec3] = []
        for k in 0...n {
            let u = Float(k) / Float(n)
            let z = z0 + u * L
            // Taper to a point over the last `tip` fraction.
            let tipT = saturatef((u - (1 - tip)) / max(tip, 1e-3))
            let taper = (1 - tipT * tipT).squareRoot()
            let w = max(0.0008, width(u) * (k == n ? 0.02 : taper))
            let t = max(0.0006, thick * (1 - 0.5 * u) * (k == n ? 0.1 : 1))
            let off = curve * u * u
            if single {
                // Edge at +Y, spine at -Y.
                rings.append([Vec3(t, -w * 0.55 + off, z), Vec3(t * 0.55, w * 0.35 + off, z), Vec3(0, w + off, z),
                              Vec3(-t * 0.55, w * 0.35 + off, z), Vec3(-t, -w * 0.55 + off, z), Vec3(-t * 0.8, -w + off, z), Vec3(t * 0.8, -w + off, z)])
                edgeLine.append(Vec3(0, w + off, z))
            } else {
                rings.append([Vec3(t, 0 + off, z), Vec3(t * 0.45, w * 0.6 + off, z), Vec3(0, w + off, z), Vec3(-t * 0.45, w * 0.6 + off, z),
                              Vec3(-t, off, z), Vec3(-t * 0.45, -w * 0.6 + off, z), Vec3(0, -w + off, z), Vec3(t * 0.45, -w * 0.6 + off, z)])
                edgeLine.append(Vec3(0, w + off, z))
            }
        }
        b.material = mat
        b.loft(rings)
        if glow {
            b.material = 3
            let saveE = b.emissive
            b.emissive = 1
            var er: [[Vec3]] = []
            for (k, p) in edgeLine.enumerated() {
                let s: Float = k == edgeLine.count - 1 ? 0.2 : 1
                er.append([p + Vec3(0.0015 * s, -0.002 * s, 0), p + Vec3(0, 0.0025 * s, 0), p + Vec3(-0.0015 * s, -0.002 * s, 0)])
            }
            b.loft(er)
            if !single {
                let er2 = er.map { r in r.map { Vec3($0.x, -$0.y, $0.z) }.reversed() as [Vec3] }
                b.loft(er2)
            }
            b.emissive = saveE
        }
    }
}
