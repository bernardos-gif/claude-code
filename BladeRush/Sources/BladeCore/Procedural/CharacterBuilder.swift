// Builds skinned character meshes from a high-level visual description (Data/bosses.json
// "visual" blocks). Bodies, clothing, armor, helmets, hair and accessories are composed
// as smooth SDF primitives around the skeleton's bind pose, then polygonized with Surface
// Nets. Skin weights come from primitive ownership, so organic blends deform smoothly.
//
// Material slots: 0 skin, 1 cloth, 2 leather, 3 armor, 4 trim, 5 hair, 6 cloth-2, 7 emissive.
import Foundation

public struct CharacterPalette: Codable, Equatable {
    public var primary = "#3a3f4a"
    public var secondary = "#8c1c1c"
    public var leather = "#3b2616"
    public var metal = "#8a8d93"
    public var trim = "#b08a3c"
    public var hair = "#1d1612"
    public var glow = "#ff6a2a"

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterPalette()
        primary = try c.v(.primary, d.primary); secondary = try c.v(.secondary, d.secondary)
        leather = try c.v(.leather, d.leather); metal = try c.v(.metal, d.metal)
        trim = try c.v(.trim, d.trim); hair = try c.v(.hair, d.hair); glow = try c.v(.glow, d.glow)
    }
}

public struct CharacterVisual: Codable, Equatable {
    public var body = BodyProportions()
    public var skin = "#b98b6e"
    public var outfit = "tunic"        // tunic, robe, gi, coat, rags, bare, armor, dress
    public var chest = "none"          // none, plate, leather, chain, scale, bone, cuirass, brigandine
    public var pauldrons = "none"      // none, round, layered, spiked, large, fur, bone, wings
    public var helmet = "none"         // none, hood, great, kabuto, horned, crown, mask, strawhat, tricorn, bandana, skull, crested, sallet, veil, circlet, cowl
    public var hair = "short"          // none, short, long, ponytail, topknot, wild, braid, mohawk
    public var beard = "none"          // none, stubble, full, long, braided
    public var arms = "sleeves"        // bare, sleeves, short, bracers, gauntlets, wraps, bell
    public var legs = "pants"          // pants, greaves, boots, bare, wraps, hakama
    public var skirt = "none"          // none, robe, tassets, kilt, loincloth, coat, long, tattered
    public var cape = "none"           // none, short, long, tattered, scarf
    public var extras: [String] = []   // belt, sash, fur_collar, spikes, chains, horns, tusks, eyepatch, bandolier, pouches, skulls, beads, lantern, halo, gorget, wings
    public var colors = CharacterPalette()
    public var armorMaterial = "metal" // metal, rustIron, gold, bronze, obsidian, ice, bone, lacquer, dark
    public var eyeGlow: Float = 0
    public var runes: Float = 0
    public var wear: Float = 0.4
    public var rust: Float = 0
    public var frost: Float = 0
    public var muscleDefinition: Float = 0.5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterVisual()
        body = try c.v(.body, d.body); skin = try c.v(.skin, d.skin); outfit = try c.v(.outfit, d.outfit)
        chest = try c.v(.chest, d.chest); pauldrons = try c.v(.pauldrons, d.pauldrons); helmet = try c.v(.helmet, d.helmet)
        hair = try c.v(.hair, d.hair); beard = try c.v(.beard, d.beard); arms = try c.v(.arms, d.arms)
        legs = try c.v(.legs, d.legs); skirt = try c.v(.skirt, d.skirt); cape = try c.v(.cape, d.cape)
        extras = try c.v(.extras, d.extras); colors = try c.v(.colors, d.colors)
        armorMaterial = try c.v(.armorMaterial, d.armorMaterial); eyeGlow = try c.v(.eyeGlow, d.eyeGlow)
        runes = try c.v(.runes, d.runes); wear = try c.v(.wear, d.wear); rust = try c.v(.rust, d.rust)
        frost = try c.v(.frost, d.frost); muscleDefinition = try c.v(.muscleDefinition, d.muscleDefinition)
    }

    public func has(_ extra: String) -> Bool { extras.contains(extra) }
}

/// Cloth attachment description for the cape simulation.
public struct CapeSpec: Equatable {
    public var length: Float
    public var width: Float
    public var tattered: Bool
    public var isScarf: Bool
    public var material: MaterialDesc
}

public struct BuiltCharacter {
    public var mesh: MeshData
    public var materials: [MaterialDesc]
    public var cape: CapeSpec?
    public var ponytail: Bool
    public var height: Float
}

public enum CharacterBuilder {
    public static func materials(for v: CharacterVisual) -> [MaterialDesc] {
        let c = v.colors
        var armor: MaterialDesc
        let metal = parseColor(c.metal)
        switch v.armorMaterial {
        case "rustIron": armor = MaterialDesc(kind: .rustIron, color: metal, metallic: 0.9, roughness: 0.55, wear: v.wear, dirt: 0.5, rust: max(0.5, v.rust))
        case "gold": armor = .gold(parseColor(c.trim))
        case "bronze": armor = MaterialDesc(kind: .gold, color: srgbHex(0x9C6B3A), metallic: 1, roughness: 0.38, wear: v.wear, dirt: 0.4)
        case "obsidian": armor = MaterialDesc(kind: .obsidian, color: srgbHex(0x16141C), metallic: 0.2, roughness: 0.12, wear: 0.1, dirt: 0.1)
        case "ice": armor = MaterialDesc(kind: .ice, color: srgbHex(0x9FD4F2), metallic: 0.1, roughness: 0.08, wear: 0.2, dirt: 0.0, frost: 0.6)
        case "bone": armor = MaterialDesc(kind: .bone, color: srgbHex(0xD8CDB0), metallic: 0, roughness: 0.6, wear: 0.2, dirt: 0.5)
        case "lacquer": armor = MaterialDesc(kind: .plain, color: parseColor(c.primary), metallic: 0.1, roughness: 0.2, wear: 0.3, dirt: 0.2)
        case "dark": armor = .steel(srgbHex(0x2A2B31), rough: 0.35)
        default: armor = .steel(metal, rough: 0.3)
        }
        armor.wear = max(armor.wear, v.wear * 0.8)
        armor.rust = max(armor.rust, v.rust)
        armor.frost = v.frost
        let glow = parseColor(c.glow)
        if v.runes > 0 { armor.runes = v.runes; armor.emissive = glow; armor.emissiveStrength = 4 * v.runes }
        var trim = MaterialDesc.gold(parseColor(c.trim))
        trim.frost = v.frost
        var cloth = MaterialDesc.fabric(parseColor(c.primary))
        cloth.frost = v.frost * 0.7
        var cloth2 = MaterialDesc.fabric(parseColor(c.secondary))
        cloth2.frost = v.frost * 0.7
        var leather = MaterialDesc.leather(parseColor(c.leather))
        leather.frost = v.frost * 0.5
        let hair = MaterialDesc(kind: .hair, color: parseColor(c.hair), metallic: 0, roughness: 0.45, wear: 0, dirt: 0.1, sheen: 0.5)
        return [.skin(parseColor(v.skin)), cloth, leather, armor, trim, hair, cloth2,
                .emissive(glow, strength: max(3, v.eyeGlow * 12))]
    }

    public static func build(_ v: CharacterVisual, skeleton sk: Skeleton, quality: Float = 1) -> BuiltCharacter {
        let model = SDFModel()
        let s = sk.scale
        let bulk = v.body.bulk
        let mus = v.body.muscle
        let hs = v.body.head
        func J(_ b: Bone) -> Vec3 { sk.bindGlobals[b.rawValue].pos }
        let bindHeadRot = sk.bindGlobals[Bone.head.rawValue].rot
        func H(_ p: Vec3) -> Vec3 { J(.head) + bindHeadRot.rotate(p * s * hs) }
        let blendBody: Float = 0.035 * s
        let skinTint = Vec3(1, 1, 1)
        let headC = H(Vec3(0, 0.085, 0.012))
        let headR = Vec3(0.078, 0.1, 0.092) * s * hs

        // ------------------------------------------------------------------ Body
        model.add(SDFPrim.ellipsoid(J(.pelvis) + Vec3(0, 0.02, -0.005) * s, Vec3(0.165 * v.body.hips * bulk, 0.11, 0.115 * bulk) * s)
            .bone(.pelvis).mat(0).blend(0))
        let abdA = J(.pelvis) + Vec3(0, 0.06, 0) * s
        model.add(SDFPrim.roundCone(abdA, J(.spine2), 0.13 * bulk * s, 0.14 * bulk * s)
            .bone(.spine1, .spine2).mat(0).blend(blendBody))
        if v.body.belly > 0 {
            model.add(SDFPrim.sphere(J(.spine1) + Vec3(0, -0.02, 0.05 + 0.05 * v.body.belly) * s, (0.1 + 0.09 * v.body.belly) * s)
                .bone(.spine1).mat(0).blend(0.06 * s))
        }
        let chestC = J(.spine2) + Vec3(0, 0.1, 0.005) * s
        let chestR = Vec3(0.17 * v.body.shoulders * bulk + 0.02 * mus, 0.14, 0.115 * bulk + 0.015 * mus) * s
        model.add(SDFPrim.ellipsoid(chestC, chestR).bone(.spine2).mat(0).blend(blendBody))
        let shL = J(.upperArmL), shR = J(.upperArmR)
        model.add(SDFPrim.capsule(shL + Vec3(-0.04, 0.02, 0) * s, shR + Vec3(0.04, 0.02, 0) * s, 0.06 * bulk * s)
            .bone(.spine2).mat(0).blend(0.04 * s))
        // Neck and head.
        model.add(SDFPrim.capsule(J(.neck), J(.head) + Vec3(0, 0.03, 0) * s, 0.05 * s * bulk.squareRoot())
            .bone(.neck, .head).mat(0).blend(0.03 * s))
        model.add(SDFPrim.ellipsoid(headC, headR).bone(.head).mat(0).blend(0.02 * s))
        model.add(SDFPrim.ellipsoid(H(Vec3(0, 0.035, 0.035)), Vec3(0.062, 0.05, 0.06) * s * hs).bone(.head).mat(0).blend(0.03 * s))
        model.add(SDFPrim.capsule(H(Vec3(0, 0.092, 0.088)), H(Vec3(0, 0.066, 0.101)), 0.012 * s * hs).bone(.head).mat(0).blend(0.012 * s))
        model.add(SDFPrim.capsule(H(Vec3(-0.036, 0.108, 0.082)), H(Vec3(0.036, 0.108, 0.082)), 0.014 * s * hs).bone(.head).mat(0).blend(0.015 * s))
        for side: Float in [-1, 1] {
            model.add(SDFPrim.sphere(H(Vec3(0.031 * side, 0.09, 0.09)), 0.017 * s * hs).bone(.head).subtract(0.008 * s))
            model.add(SDFPrim.ellipsoid(H(Vec3(0.079 * side, 0.08, 0.0)), Vec3(0.012, 0.025, 0.018) * s * hs).bone(.head).mat(0).blend(0.01 * s))
        }
        let eyeGlowing = v.eyeGlow > 0.05
        for side: Float in [-1, 1] {
            var eye = SDFPrim.sphere(H(Vec3(0.031 * side, 0.09, 0.082)), 0.011 * s * hs).bone(.head).blend(0.002)
            if eyeGlowing { eye = eye.mat(7).glow(1) } else { eye = eye.mat(0).tint(Vec3(0.12, 0.1, 0.1)) }
            model.add(eye)
        }
        // Arms.
        for side: Float in [-1, 1] {
            let L = side > 0
            let ua: Bone = L ? .upperArmL : .upperArmR, fa: Bone = L ? .forearmL : .forearmR, hb: Bone = L ? .handL : .handR
            model.add(SDFPrim.sphere(J(ua) + Vec3(0.01 * side, -0.015, 0) * s, (0.056 * bulk + 0.012 * mus) * s).bone(ua).mat(0).blend(0.035 * s))
            model.add(SDFPrim.roundCone(J(ua), J(fa), (0.05 * bulk + 0.01 * mus) * s, 0.04 * bulk * s).bone(ua, fa).mat(0).blend(0.03 * s))
            model.add(SDFPrim.roundCone(J(fa), J(hb), (0.043 * bulk + 0.006 * mus) * s, 0.031 * bulk * s).bone(fa).mat(0).blend(0.025 * s))
            let armDir = vnormalize(J(hb) - J(fa))
            model.add(SDFPrim.ellipsoid(J(hb) + armDir * 0.055 * s, Vec3(0.04, 0.055, 0.048) * s * max(1, bulk * 0.9),
                                        rot: Quat.fromTo(Vec3(0, 1, 0), armDir)).bone(hb).mat(0).blend(0.012 * s))
        }
        // Legs.
        for side: Float in [-1, 1] {
            let L = side > 0
            let th: Bone = L ? .thighL : .thighR, sh: Bone = L ? .shinL : .shinR, ft: Bone = L ? .footL : .footR, toe: Bone = L ? .toeL : .toeR
            model.add(SDFPrim.sphere(J(th) + Vec3(0.0, 0.03, -0.05) * s, 0.085 * bulk * s).bone(.pelvis, th).mat(0).blend(0.05 * s))
            model.add(SDFPrim.roundCone(J(th), J(sh), (0.085 * bulk + 0.012 * mus) * s, 0.055 * bulk * s).bone(th, sh).mat(0).blend(0.04 * s))
            model.add(SDFPrim.roundCone(J(sh), J(ft), (0.056 * bulk + 0.008 * mus) * s, 0.038 * bulk * s).bone(sh).mat(0).blend(0.03 * s))
            model.add(SDFPrim.ellipsoid(J(sh) + Vec3(0, -0.12, -0.02) * s, Vec3(0.048, 0.1, 0.05) * s * bulk).bone(sh).mat(0).blend(0.03 * s))
            let footC = Vec3(J(ft).x, 0.045 * s, (J(ft).z + J(toe).z) * 0.5 + 0.03 * s)
            model.add(SDFPrim.box(footC, Vec3(0.046, 0.04, 0.12) * s, rounding: 0.03 * s).bone(ft).mat(0).blend(0.03 * s))
        }

        // ------------------------------------------------------------------ Clothing
        let clothSlot = 1
        let dressed = v.outfit != "bare"
        if dressed {
            let inflate: Float = 0.016 * s
            let mat = v.outfit == "armor" ? 2 : clothSlot
            model.add(SDFPrim.roundCone(abdA, J(.spine2), 0.13 * bulk * s + inflate, 0.14 * bulk * s + inflate)
                .bone(.spine1, .spine2).mat(mat).blend(0.03 * s).noise(v.outfit == "rags" ? 0.004 * s : 0, 40))
            model.add(SDFPrim.ellipsoid(chestC, chestR + Vec3(repeating: inflate)).bone(.spine2).mat(mat).blend(0.03 * s))
            model.add(SDFPrim.ellipsoid(J(.pelvis) + Vec3(0, 0.03, -0.005) * s,
                                        Vec3(0.165 * v.body.hips * bulk, 0.11, 0.115 * bulk) * s + Vec3(repeating: inflate))
                .bone(.pelvis).mat(v.legs == "bare" ? 2 : mat).blend(0.03 * s))
            model.add(SDFPrim.capsule(shL + Vec3(-0.04, 0.02, 0) * s, shR + Vec3(0.04, 0.02, 0) * s, 0.06 * bulk * s + inflate * 0.8)
                .bone(.spine2).mat(mat).blend(0.03 * s))
            if v.outfit == "gi" || v.outfit == "robe" {
                // V-neck opening showing skin.
                model.add(SDFPrim.box(J(.spine2) + Vec3(0, 0.16, 0.12) * s, Vec3(0.04, 0.09, 0.05) * s,
                                      rot: Quat(axis: Vec3(1, 0, 0), angle: -0.4), rounding: 0.01 * s).bone(.spine2).subtract(0.01 * s))
                model.add(SDFPrim.box(J(.spine2) + Vec3(0, 0.1, 0.09) * s, Vec3(0.035, 0.08, 0.04) * s, rounding: 0.01 * s)
                    .bone(.spine2).mat(0).blend(0.01 * s))
            }
        }
        // Sleeves.
        for side: Float in [-1, 1] {
            let L = side > 0
            let ua: Bone = L ? .upperArmL : .upperArmR, fa: Bone = L ? .forearmL : .forearmR, hb: Bone = L ? .handL : .handR
            let up = J(ua), el = J(fa), wr = J(hb)
            switch v.arms {
            case "sleeves", "bell":
                if dressed {
                    model.add(SDFPrim.roundCone(up, el, (0.05 * bulk + 0.01 * mus) * s + 0.014 * s, 0.04 * bulk * s + 0.013 * s)
                        .bone(ua, fa).mat(clothSlot).blend(0.02 * s))
                    let r2: Float = v.arms == "bell" ? 0.085 : 0.038
                    model.add(SDFPrim.roundCone(el, wr - vnormalize(wr - el) * 0.02 * s, (0.043 * bulk) * s + 0.013 * s, r2 * bulk * s)
                        .bone(fa).mat(clothSlot).blend(0.02 * s))
                }
            case "short":
                if dressed {
                    model.add(SDFPrim.roundCone(up, vlerp(up, el, 0.55), (0.05 * bulk + 0.01 * mus) * s + 0.015 * s, 0.047 * bulk * s + 0.012 * s)
                        .bone(ua).mat(clothSlot).blend(0.015 * s))
                }
            case "bracers", "gauntlets", "wraps":
                if dressed {
                    model.add(SDFPrim.roundCone(up, vlerp(up, el, 0.5), (0.05 * bulk + 0.01 * mus) * s + 0.014 * s, 0.047 * bulk * s + 0.012 * s)
                        .bone(ua).mat(clothSlot).blend(0.015 * s))
                }
                let mat = v.arms == "gauntlets" ? 3 : (v.arms == "wraps" ? 6 : 2)
                model.add(SDFPrim.roundCone(vlerp(el, wr, 0.15), vlerp(el, wr, 0.95), 0.047 * bulk * s + 0.01 * s, 0.037 * bulk * s + 0.012 * s)
                    .bone(fa).mat(mat).blend(0.006 * s).noise(v.arms == "wraps" ? 0.002 * s : 0, 90))
                if v.arms == "gauntlets" {
                    let armDir = vnormalize(wr - el)
                    model.add(SDFPrim.ellipsoid(wr + armDir * 0.05 * s, Vec3(0.047, 0.06, 0.054) * s * max(1, bulk * 0.9),
                                                rot: Quat.fromTo(Vec3(0, 1, 0), armDir)).bone(hb).mat(3).blend(0.006 * s))
                    model.add(SDFPrim.torus(vlerp(el, wr, 0.2), major: 0.05 * bulk * s, minor: 0.012 * s,
                                            rot: Quat.fromTo(Vec3(0, 1, 0), armDir)).bone(fa).mat(4).blend(0.004 * s))
                }
            default: break
            }
        }
        // Legs clothing.
        for side: Float in [-1, 1] {
            let L = side > 0
            let th: Bone = L ? .thighL : .thighR, sh: Bone = L ? .shinL : .shinR, ft: Bone = L ? .footL : .footR, toe: Bone = L ? .toeL : .toeR
            let hip = J(th), knee = J(sh), ank = J(ft)
            let footC = Vec3(J(ft).x, 0.047 * s, (J(ft).z + J(toe).z) * 0.5 + 0.03 * s)
            if v.legs != "bare" {
                let pantsMat = v.legs == "hakama" ? 6 : (v.outfit == "armor" ? 2 : 6)
                let extra: Float = v.legs == "hakama" ? 0.04 : 0.014
                model.add(SDFPrim.roundCone(hip, knee, (0.085 * bulk + 0.012 * mus) * s + extra * s, 0.055 * bulk * s + extra * s)
                    .bone(th, sh).mat(pantsMat).blend(0.02 * s))
                model.add(SDFPrim.roundCone(knee, vlerp(knee, ank, 0.55), 0.056 * bulk * s + extra * s * 0.9, 0.05 * bulk * s + extra * s * 0.8)
                    .bone(sh).mat(pantsMat).blend(0.02 * s))
            }
            // Boots or greaves.
            let bootMat = v.legs == "greaves" ? 3 : (v.legs == "wraps" ? 6 : 2)
            if v.legs != "bare" {
                model.add(SDFPrim.roundCone(vlerp(knee, ank, 0.4), ank, 0.055 * bulk * s + 0.016 * s, 0.042 * bulk * s + 0.016 * s)
                    .bone(sh).mat(bootMat).blend(0.008 * s))
                model.add(SDFPrim.box(footC, Vec3(0.054, 0.048, 0.128) * s, rounding: 0.034 * s).bone(ft).mat(bootMat).blend(0.012 * s))
            }
            if v.legs == "greaves" {
                model.add(SDFPrim.ellipsoid(knee + Vec3(0, 0, 0.045) * s, Vec3(0.055, 0.06, 0.04) * s).bone(sh).mat(3).blend(0.006 * s))
                model.add(SDFPrim.roundCone(hip + Vec3(0, -0.05, 0.02) * s, vlerp(hip, knee, 0.8) + Vec3(0, 0, 0.02) * s, 0.1 * bulk * s, 0.07 * bulk * s)
                    .bone(th).mat(3).blend(0.006 * s).clip(hip, Vec3(0, 0, -1)))
            }
        }

        // ------------------------------------------------------------------ Skirts / robes
        let waistY = J(.pelvis).y + 0.06 * s
        let torsoRadius = 0.15 * bulk * v.body.hips * s
        switch v.skirt {
        case "robe", "long":
            let bottom = Vec3(0, 0.12 * s, -0.01 * s)
            model.add(SDFPrim.roundCone(Vec3(0, waistY, 0), bottom, torsoRadius + 0.02 * s, (0.3 + 0.05 * bulk) * s)
                .bone(.pelvis).mat(v.skirt == "long" ? 6 : clothSlot).blend(0.04 * s).asSkirt()
                .hollow(0.012 * s).clip(Vec3(0, 0.1 * s, 0), Vec3(0, -1, 0)))
        case "coat":
            let bottom = Vec3(0, 0.45 * s, -0.03 * s)
            model.add(SDFPrim.roundCone(Vec3(0, waistY, 0), bottom, torsoRadius + 0.02 * s, (0.27 + 0.03 * bulk) * s)
                .bone(.pelvis).mat(clothSlot).blend(0.04 * s).asSkirt().hollow(0.012 * s)
                .clip(Vec3(0, 0.46 * s, 0), Vec3(0, -1, 0)))
            model.add(SDFPrim.box(Vec3(0, 0.55 * s, 0.3 * s), Vec3(0.06, 0.25, 0.2) * s, rounding: 0.01 * s).subtract(0.01 * s))
        case "tassets":
            let bottom = Vec3(0, J(.shinL).y + 0.2 * s, 0)
            model.add(SDFPrim.roundCone(Vec3(0, waistY, 0), bottom, torsoRadius + 0.03 * s, (0.24 + 0.03 * bulk) * s)
                .bone(.pelvis).mat(3).blend(0.01 * s).asSkirt().hollow(0.01 * s)
                .clip(bottom + Vec3(0, 0.01 * s, 0), Vec3(0, -1, 0)))
            // Split between the legs.
            model.add(SDFPrim.box(Vec3(0, bottom.y + 0.1 * s, 0), Vec3(0.018, 0.13, 0.4) * s, rounding: 0.004 * s).subtract(0.004 * s))
        case "kilt", "tattered", "loincloth":
            let len: Float = v.skirt == "loincloth" ? 0.3 : 0.42
            let bottom = Vec3(0, waistY - len * s, 0)
            model.add(SDFPrim.roundCone(Vec3(0, waistY, 0), bottom, torsoRadius + 0.02 * s, (0.2 + 0.04 * bulk) * s)
                .bone(.pelvis).mat(v.skirt == "kilt" ? 6 : clothSlot).blend(0.03 * s).asSkirt()
                .hollow(0.01 * s).noise(v.skirt == "tattered" ? 0.012 * s : 0.0, 18)
                .clip(bottom + Vec3(0, 0.02 * s, 0), Vec3(0, -1, 0)))
            if v.skirt == "loincloth" {
                model.add(SDFPrim.box(Vec3(0, 0.25 * s, 0), Vec3(0.2, 0.2, 0.05) * s).subtract(0.01 * s))
            }
        default: break
        }

        // ------------------------------------------------------------------ Chest armor
        let armorMat = 3
        switch v.chest {
        case "plate", "cuirass", "brigandine", "scale", "chain":
            let infl: Float = v.chest == "chain" ? 0.022 : 0.036
            let n: Float = v.chest == "scale" ? 0.003 : (v.chest == "chain" ? 0.0015 : 0)
            var plate = SDFPrim.ellipsoid(chestC + Vec3(0, -0.01, 0.005) * s, chestR + Vec3(infl, infl * 0.8, infl) * s)
                .bone(.spine2).mat(v.chest == "brigandine" ? 2 : armorMat).blend(0.012 * s).noise(n * s, v.chest == "scale" ? 140 : 260)
            if v.chest == "cuirass" { plate = plate.clip(chestC, Vec3(0, 0, -1)) }
            model.add(plate)
            model.add(SDFPrim.roundCone(abdA + Vec3(0, 0.02, 0) * s, J(.spine2), 0.135 * bulk * s + infl * s * 0.8, 0.145 * bulk * s + infl * s)
                .bone(.spine1, .spine2).mat(v.chest == "brigandine" ? 2 : armorMat).blend(0.012 * s).noise(n * s, 200))
            if v.chest == "plate" || v.chest == "cuirass" {
                // Center ridge and neck rim.
                model.add(SDFPrim.box(chestC + Vec3(0, -0.02, chestR.z + infl * s - 0.006 * s), Vec3(0.008, 0.12, 0.012) * s, rounding: 0.006 * s)
                    .bone(.spine2).mat(armorMat).blend(0.01 * s))
                model.add(SDFPrim.torus(J(.neck) + Vec3(0, -0.01, 0.0) * s, major: 0.075 * s * bulk, minor: 0.014 * s).bone(.spine2).mat(4).blend(0.006 * s))
            }
            if v.chest == "brigandine" {
                for i in 0..<5 {
                    for j in -2...2 {
                        let p = chestC + Vec3(Float(j) * 0.05, -0.08 + Float(i) * 0.05, chestR.z + 0.03) * s
                        model.add(SDFPrim.sphere(p, 0.008 * s).bone(.spine2).mat(4).blend(0.002))
                    }
                }
            }
        case "leather":
            model.add(SDFPrim.ellipsoid(chestC, chestR + Vec3(0.026, 0.02, 0.026) * s).bone(.spine2).mat(2).blend(0.012 * s))
            model.add(SDFPrim.roundCone(abdA, J(.spine2), 0.135 * bulk * s + 0.022 * s, 0.145 * bulk * s + 0.024 * s)
                .bone(.spine1, .spine2).mat(2).blend(0.012 * s))
            for side: Float in [-1, 1] {
                model.add(SDFPrim.capsule(J(.upperArmL) * Vec3(side, 1, 1) + Vec3(0, 0.04, 0.09) * s, J(.pelvis) + Vec3(-0.12 * side, 0.1, 0.13) * s, 0.012 * s)
                    .bone(.spine2, .spine1).mat(2).blend(0.004 * s))
            }
        case "bone":
            for i in 0..<5 {
                let y = chestC.y - 0.13 * s + Float(i) * 0.055 * s
                model.add(SDFPrim.torus(Vec3(0, y, 0.01 * s), major: (0.15 + 0.01 * Float(i)) * bulk * s, minor: 0.013 * s,
                                        rot: Quat(axis: Vec3(1, 0, 0), angle: 0.15)).bone(.spine2).mat(2).tint(Vec3(1.6, 1.5, 1.3)).blend(0.004 * s)
                    .clip(Vec3(0, y, -0.02 * s), Vec3(0, 0, -1)))
            }
            model.add(SDFPrim.box(chestC + Vec3(0, -0.03, chestR.z + 0.02 * s) , Vec3(0.02, 0.15, 0.015) * s, rounding: 0.01 * s)
                .bone(.spine2).mat(2).tint(Vec3(1.6, 1.5, 1.3)).blend(0.005 * s))
        default: break
        }

        // ------------------------------------------------------------------ Pauldrons
        for side: Float in [-1, 1] {
            let L = side > 0
            let ua: Bone = L ? .upperArmL : .upperArmR
            let sp = J(ua)
            let out = vnormalize(Vec3(side, 0.7, 0))
            switch v.pauldrons {
            case "round", "spiked":
                model.add(SDFPrim.ellipsoid(sp + Vec3(0.015 * side, 0.03, 0) * s, Vec3(0.105, 0.075, 0.1) * s * bulk.squareRoot(),
                                            rot: Quat(axis: Vec3(0, 0, 1), angle: -0.5 * side)).bone(ua).mat(armorMat).blend(0.008 * s))
                model.add(SDFPrim.torus(sp + Vec3(0.02 * side, -0.02, 0) * s, major: 0.09 * s * bulk.squareRoot(), minor: 0.01 * s,
                                        rot: Quat.fromTo(Vec3(0, 1, 0), out)).bone(ua).mat(4).blend(0.004 * s))
                if v.pauldrons == "spiked" {
                    for k in 0..<3 {
                        let a = (Float(k) - 1) * 0.5
                        let dir = vnormalize(Vec3(side * 0.6, 1, a))
                        model.add(SDFPrim.cone(sp + Vec3(0.02 * side, 0.06, a * 0.06) * s + dir * 0.06 * s, halfHeight: 0.06 * s, r1: 0.025 * s, r2: 0.002 * s,
                                               rot: Quat.fromTo(Vec3(0, 1, 0), dir)).bone(ua).mat(4).blend(0.004 * s))
                    }
                }
            case "layered":
                for k in 0..<3 {
                    let kf = Float(k)
                    model.add(SDFPrim.ellipsoid(sp + Vec3((0.02 + 0.012 * kf) * side, 0.035 - 0.05 * kf, 0) * s,
                                                Vec3(0.1 - 0.008 * kf, 0.05, 0.095 - 0.006 * kf) * s * bulk.squareRoot(),
                                                rot: Quat(axis: Vec3(0, 0, 1), angle: -0.6 * side)).bone(ua).mat(armorMat).blend(0.004 * s))
                }
            case "large", "wings":
                model.add(SDFPrim.ellipsoid(sp + Vec3(0.04 * side, 0.05, 0) * s, Vec3(0.16, 0.09, 0.14) * s * bulk.squareRoot(),
                                            rot: Quat(axis: Vec3(0, 0, 1), angle: -0.45 * side)).bone(ua).mat(armorMat).blend(0.006 * s))
                model.add(SDFPrim.torus(sp + Vec3(0.05 * side, 0.0, 0) * s, major: 0.14 * s, minor: 0.014 * s,
                                        rot: Quat.fromTo(Vec3(0, 1, 0), out)).bone(ua).mat(4).blend(0.004 * s))
                if v.pauldrons == "wings" {
                    model.add(SDFPrim.box(sp + Vec3(0.1 * side, 0.14, -0.03) * s, Vec3(0.012, 0.1, 0.07) * s,
                                          rot: Quat(axis: Vec3(0, 0, 1), angle: -0.5 * side), rounding: 0.01 * s).bone(ua).mat(4).blend(0.004 * s))
                }
            case "fur":
                model.add(SDFPrim.ellipsoid(sp + Vec3(0.0, 0.04, -0.01) * s, Vec3(0.12, 0.08, 0.12) * s * bulk.squareRoot())
                    .bone(ua, .spine2).mat(5).blend(0.03 * s).noise(0.012 * s, 30))
            case "bone":
                model.add(SDFPrim.ellipsoid(sp + Vec3(0.02 * side, 0.04, 0) * s, Vec3(0.09, 0.07, 0.085) * s)
                    .bone(ua).mat(2).tint(Vec3(1.7, 1.6, 1.4)).blend(0.006 * s))
                model.add(SDFPrim.cone(sp + Vec3(0.07 * side, 0.1, 0) * s, halfHeight: 0.06 * s, r1: 0.02 * s, r2: 0.003 * s,
                                       rot: Quat.fromTo(Vec3(0, 1, 0), vnormalize(Vec3(side, 1, 0)))).bone(ua).mat(2).tint(Vec3(1.7, 1.6, 1.4)).blend(0.004 * s))
            default: break
            }
        }

        // ------------------------------------------------------------------ Head gear and hair
        let headTop = H(Vec3(0, 0.19, 0.01))
        var hairAllowed = true
        let cap = headR + Vec3(repeating: 0.012 * s)
        switch v.helmet {
        case "hood", "cowl":
            hairAllowed = false
            model.add(SDFPrim.ellipsoid(headC + Vec3(0, 0.012, -0.008) * s, headR + Vec3(0.03, 0.028, 0.03) * s).bone(.head).mat(v.helmet == "cowl" ? 6 : clothSlot)
                .blend(0.01 * s).hollow(0.008 * s))
            model.add(SDFPrim.ellipsoid(H(Vec3(0, 0.07, 0.12)), Vec3(0.075, 0.1, 0.1) * s * hs).bone(.head).subtract(0.02 * s))
            model.add(SDFPrim.roundCone(H(Vec3(0, 0.05, -0.06)), J(.spine2) + Vec3(0, 0.12, -0.08) * s, 0.09 * s, 0.14 * s)
                .bone(.head, .spine2).mat(v.helmet == "cowl" ? 6 : clothSlot).blend(0.03 * s))
        case "great", "sallet", "crested":
            hairAllowed = false
            let hb = v.helmet == "sallet" ? Vec3(0.098, 0.12, 0.11) : Vec3(0.1, 0.135, 0.105)
            model.add(SDFPrim.box(headC + Vec3(0, 0.005, 0) * s, hb * s * hs, rounding: (v.helmet == "sallet" ? 0.08 : 0.05) * s).bone(.head).mat(armorMat).blend(0.004 * s))
            model.add(SDFPrim.box(H(Vec3(0, 0.095, 0.11)), Vec3(0.07, 0.008, 0.05) * s * hs, rounding: 0.003 * s).bone(.head).subtract(0.003 * s))
            model.add(SDFPrim.box(H(Vec3(0, 0.05, 0.105)), Vec3(0.005, 0.04, 0.02) * s * hs, rounding: 0.002 * s).bone(.head).mat(4).blend(0.002))
            if v.helmet == "sallet" {
                model.add(SDFPrim.box(H(Vec3(0, 0.07, -0.09)), Vec3(0.09, 0.02, 0.07) * s, rot: Quat(axis: Vec3(1, 0, 0), angle: 0.4), rounding: 0.015 * s)
                    .bone(.head).mat(armorMat).blend(0.01 * s))
            }
            if v.helmet == "crested" {
                model.add(SDFPrim.box(H(Vec3(0, 0.24, -0.02)), Vec3(0.012, 0.06, 0.13) * s, rounding: 0.02 * s).bone(.head).mat(5)
                    .tint(Vec3(1.5, 0.6, 0.5)).blend(0.01 * s).noise(0.004 * s, 60))
            }
        case "kabuto":
            hairAllowed = false
            model.add(SDFPrim.ellipsoid(headC + Vec3(0, 0.03, 0) * s, headR + Vec3(0.022, 0.02, 0.022) * s).bone(.head).mat(armorMat)
                .blend(0.004 * s).clip(H(Vec3(0, 0.07, 0)), Vec3(0, -1, 0)))
            model.add(SDFPrim.cone(H(Vec3(0, 0.04, -0.02)), halfHeight: 0.045 * s, r1: 0.19 * s, r2: 0.1 * s)
                .bone(.head).mat(armorMat).blend(0.006 * s).hollow(0.006 * s).clip(H(Vec3(0, 0.0, 0.07)), Vec3(0, 0, 1)))
            model.add(SDFPrim.torus(H(Vec3(0, 0.26, 0.09)), major: 0.07 * s, minor: 0.008 * s, rot: Quat(axis: Vec3(1, 0, 0), angle: 1.3))
                .bone(.head).mat(4).blend(0.003 * s).clip(H(Vec3(0, 0.24, 0)), Vec3(0, -1, 0)))
            model.add(SDFPrim.ellipsoid(H(Vec3(0, 0.05, 0.095)), Vec3(0.07, 0.055, 0.03) * s).bone(.head).mat(armorMat).tint(Vec3(0.6, 0.3, 0.3)).blend(0.01 * s))
        case "horned":
            hairAllowed = false
            model.add(SDFPrim.ellipsoid(headC + Vec3(0, 0.02, 0) * s, headR + Vec3(0.02, 0.015, 0.02) * s).bone(.head).mat(armorMat)
                .blend(0.004 * s).clip(H(Vec3(0, 0.06, 0)), Vec3(0, -1, 0)))
        case "crown", "circlet":
            model.add(SDFPrim.torus(H(Vec3(0, 0.15, 0.01)), major: 0.085 * s * hs, minor: 0.012 * s).bone(.head).mat(4).blend(0.004 * s))
            if v.helmet == "crown" {
                for k in 0..<7 {
                    let a = Float(k) / 7 * kTwoPi
                    let p = H(Vec3(cos(a) * 0.085, 0.19, sin(a) * 0.085 + 0.01))
                    model.add(SDFPrim.cone(p, halfHeight: 0.035 * s, r1: 0.016 * s, r2: 0.002 * s).bone(.head).mat(4).blend(0.004 * s))
                }
            }
        case "mask":
            model.add(SDFPrim.ellipsoid(H(Vec3(0, 0.07, 0.07)), Vec3(0.085, 0.1, 0.05) * s * hs).bone(.head).mat(armorMat)
                .blend(0.004 * s).clip(H(Vec3(0, 0.07, 0.07)), Vec3(0, 0, -1)))
            for side: Float in [-1, 1] {
                model.add(SDFPrim.ellipsoid(H(Vec3(0.032 * side, 0.09, 0.115)), Vec3(0.02, 0.009, 0.03) * s).bone(.head).subtract(0.003 * s))
            }
        case "strawhat":
            model.add(SDFPrim.cone(H(Vec3(0, 0.2, 0.0)), halfHeight: 0.05 * s, r1: 0.3 * s, r2: 0.02 * s).bone(.head).mat(6)
                .tint(Vec3(1, 1, 1)).blend(0.004 * s))
        case "tricorn":
            model.add(SDFPrim.cylinder(H(Vec3(0, 0.17, 0.0)), radius: 0.19 * s, halfHeight: 0.012 * s).bone(.head).mat(6).blend(0.004 * s))
            model.add(SDFPrim.ellipsoid(H(Vec3(0, 0.2, 0.0)), Vec3(0.1, 0.07, 0.1) * s).bone(.head).mat(6).blend(0.02 * s))
            for k in 0..<3 {
                let a = Float(k) / 3 * kTwoPi + kPi / 2
                model.add(SDFPrim.sphere(H(Vec3(cos(a) * 0.2, 0.12, sin(a) * 0.2)), 0.1 * s).bone(.head).subtract(0.02 * s))
            }
        case "bandana":
            model.add(SDFPrim.ellipsoid(headC + Vec3(0, 0.02, -0.005) * s, cap + Vec3(0.004, 0.004, 0.004) * s).bone(.head).mat(6)
                .blend(0.004 * s).clip(H(Vec3(0, 0.12, 0.04)), vnormalize(Vec3(0, -1, 0.25))))
            model.add(SDFPrim.sphere(H(Vec3(0, 0.1, -0.1)), 0.025 * s).bone(.head).mat(6).blend(0.01 * s))
        case "skull":
            hairAllowed = false
            model.add(SDFPrim.ellipsoid(headC + Vec3(0, 0.02, 0.01) * s, headR + Vec3(0.018, 0.02, 0.02) * s).bone(.head).mat(2)
                .tint(Vec3(1.8, 1.7, 1.5)).blend(0.004 * s))
            for side: Float in [-1, 1] {
                model.add(SDFPrim.sphere(H(Vec3(0.036 * side, 0.1, 0.1)), 0.025 * s).bone(.head).subtract(0.006 * s))
            }
            model.add(SDFPrim.box(H(Vec3(0, 0.02, 0.1)), Vec3(0.05, 0.012, 0.03) * s, rounding: 0.004 * s).bone(.head).subtract(0.004 * s))
        case "veil":
            model.add(SDFPrim.ellipsoid(headC + Vec3(0, 0.0, 0.0) * s, headR + Vec3(0.02, 0.03, 0.02) * s).bone(.head).mat(6)
                .blend(0.01 * s).hollow(0.006 * s).clip(H(Vec3(0, 0.06, 0.0)), Vec3(0, -1, 0)))
            model.add(SDFPrim.roundCone(H(Vec3(0, 0.08, 0.05)), H(Vec3(0, -0.12, 0.07)), 0.1 * s, 0.16 * s).bone(.head, .neck).mat(6)
                .blend(0.02 * s).hollow(0.006 * s).clip(H(Vec3(0, 0.1, 0)), Vec3(0, 1, 0)))
        default: break
        }
        if hairAllowed && v.hair != "none" {
            let hairCap = SDFPrim.ellipsoid(headC + Vec3(0, 0.012, -0.012) * s, cap).bone(.head).mat(5).blend(0.006 * s)
                .clip(H(Vec3(0, 0.11, 0.06)), vnormalize(Vec3(0, -0.6, 1)))
            model.add(hairCap.noise(v.hair == "wild" ? 0.012 * s : 0.002 * s, v.hair == "wild" ? 22 : 70))
            switch v.hair {
            case "long":
                model.add(SDFPrim.roundCone(H(Vec3(0, 0.12, -0.06)), J(.spine2) + Vec3(0, 0.1, -0.1) * s, 0.085 * s, 0.1 * s)
                    .bone(.head, .spine2).mat(5).blend(0.03 * s).noise(0.004 * s, 40))
            case "topknot":
                model.add(SDFPrim.sphere(H(Vec3(0, 0.2, -0.03)), 0.035 * s).bone(.head).mat(5).blend(0.015 * s))
            case "wild":
                model.add(SDFPrim.ellipsoid(headC + Vec3(0, 0.03, -0.03) * s, cap + Vec3(0.03, 0.03, 0.04) * s).bone(.head).mat(5)
                    .blend(0.02 * s).noise(0.018 * s, 16).clip(H(Vec3(0, 0.11, 0.07)), vnormalize(Vec3(0, -0.5, 1))))
            case "mohawk":
                model.add(SDFPrim.box(H(Vec3(0, 0.2, -0.01)), Vec3(0.012, 0.05, 0.11) * s, rounding: 0.01 * s).bone(.head).mat(5).blend(0.01 * s))
            case "braid":
                for k in 0..<5 {
                    model.add(SDFPrim.sphere(H(Vec3(0, 0.06 - Float(k) * 0.07, -0.11 - Float(k) * 0.01)), (0.03 - Float(k) * 0.003) * s)
                        .bone(k < 2 ? .head : .spine2).mat(5).blend(0.01 * s))
                }
            default: break
            }
        }
        if v.helmet == "horned" || v.has("horns") {
            for side: Float in [-1, 1] {
                var p = H(Vec3(0.075 * side, 0.15, 0.02))
                var dir = vnormalize(Vec3(side * 1.0, 0.35, 0.2))
                var r: Float = 0.03 * s
                for _ in 0..<8 {
                    let q = p + dir * 0.04 * s
                    model.add(SDFPrim.capsule(p, q, r).bone(.head).mat(2).tint(Vec3(1.7, 1.55, 1.3)).blend(0.01 * s))
                    p = q
                    dir = vnormalize(dir + Vec3(0, 0.35, -0.12))
                    r *= 0.84
                }
            }
        }
        // Beards.
        switch v.beard {
        case "stubble":
            model.add(SDFPrim.ellipsoid(H(Vec3(0, 0.03, 0.04)), Vec3(0.064, 0.052, 0.062) * s).bone(.head).mat(5).blend(0.004 * s)
                .clip(H(Vec3(0, 0.055, 0.0)), Vec3(0, 1, 0)))
        case "full", "braided":
            model.add(SDFPrim.ellipsoid(H(Vec3(0, 0.02, 0.06)), Vec3(0.07, 0.07, 0.06) * s).bone(.head).mat(5).blend(0.01 * s)
                .noise(0.004 * s, 50).clip(H(Vec3(0, 0.06, 0.0)), Vec3(0, 1, 0)))
            if v.beard == "braided" {
                model.add(SDFPrim.capsule(H(Vec3(0, -0.04, 0.09)), H(Vec3(0, -0.14, 0.1)), 0.02 * s).bone(.head).mat(5).blend(0.01 * s))
            }
        case "long":
            model.add(SDFPrim.roundCone(H(Vec3(0, 0.03, 0.07)), H(Vec3(0, -0.2, 0.1)), 0.065 * s, 0.03 * s).bone(.head).mat(5)
                .blend(0.02 * s).noise(0.004 * s, 40).clip(H(Vec3(0, 0.06, 0.0)), Vec3(0, 1, 0)))
        default: break
        }

        // ------------------------------------------------------------------ Extras
        if v.has("belt") || v.chest == "plate" || v.outfit == "armor" {
            model.add(SDFPrim.torus(Vec3(0, waistY, 0.0), major: torsoRadius + 0.02 * s, minor: 0.022 * s).bone(.pelvis).mat(2).blend(0.004 * s))
            model.add(SDFPrim.box(Vec3(0, waistY, torsoRadius + 0.04 * s), Vec3(0.03, 0.025, 0.012) * s, rounding: 0.006 * s).bone(.pelvis).mat(4).blend(0.003 * s))
        }
        if v.has("sash") {
            model.add(SDFPrim.torus(Vec3(0, waistY + 0.02 * s, 0.0), major: torsoRadius + 0.018 * s, minor: 0.03 * s,
                                    rot: Quat(axis: Vec3(0, 0, 1), angle: 0.12)).bone(.pelvis).mat(6).blend(0.008 * s))
            model.add(SDFPrim.box(Vec3(0.1 * s, waistY - 0.12 * s, torsoRadius * 0.8), Vec3(0.03, 0.12, 0.01) * s, rounding: 0.008 * s)
                .bone(.pelvis).mat(6).blend(0.01 * s).asSkirt())
        }
        if v.has("fur_collar") {
            model.add(SDFPrim.torus(J(.neck) + Vec3(0, -0.02, -0.01) * s, major: 0.13 * s * bulk, minor: 0.05 * s)
                .bone(.spine2).mat(5).blend(0.02 * s).noise(0.012 * s, 28))
        }
        if v.has("gorget") {
            model.add(SDFPrim.cone(J(.neck) + Vec3(0, 0.0, 0) * s, halfHeight: 0.04 * s, r1: 0.12 * s * bulk, r2: 0.07 * s)
                .bone(.spine2).mat(armorMat).blend(0.006 * s).hollow(0.008 * s))
        }
        if v.has("spikes") {
            for k in 0..<4 {
                let p = J(.spine2) + Vec3(0, 0.02 + Float(k) * 0.07, -0.13 * bulk) * s
                let dir = vnormalize(Vec3(0, 0.4, -1))
                model.add(SDFPrim.cone(p + dir * 0.04 * s, halfHeight: 0.05 * s, r1: 0.022 * s, r2: 0.002 * s,
                                       rot: Quat.fromTo(Vec3(0, 1, 0), dir)).bone(.spine2).mat(4).blend(0.004 * s))
            }
        }
        if v.has("chains") {
            for k in 0..<7 {
                let t = Float(k) / 6
                let p = vlerp(shL + Vec3(0, 0.02, 0.1) * s, J(.pelvis) + Vec3(-0.12, 0.12, 0.14) * s, t)
                model.add(SDFPrim.torus(p, major: 0.018 * s, minor: 0.005 * s, rot: Quat(axis: Vec3(1, 0, 0), angle: Float(k % 2) * 1.57))
                    .bone(t < 0.5 ? .spine2 : .spine1).mat(3).blend(0.002))
            }
        }
        if v.has("bandolier") {
            model.add(SDFPrim.torus(J(.spine2) + Vec3(0, 0.05, 0) * s, major: 0.2 * s * bulk, minor: 0.016 * s,
                                    rot: Quat(axis: Vec3(0, 0, 1), angle: 0.7) * Quat(axis: Vec3(1, 0, 0), angle: 1.57))
                .bone(.spine2).mat(2).blend(0.004 * s).clip(J(.spine2) + Vec3(0, -0.2, 0) * s, Vec3(0, -1, 0)))
        }
        if v.has("pouches") {
            for side: Float in [-1, 1] {
                model.add(SDFPrim.box(Vec3(side * (torsoRadius + 0.02 * s), waistY - 0.05 * s, 0.03 * s), Vec3(0.02, 0.035, 0.04) * s, rounding: 0.01 * s)
                    .bone(.pelvis).mat(2).blend(0.006 * s))
            }
        }
        if v.has("skulls") {
            for side: Float in [-1, 1] {
                model.add(SDFPrim.sphere(Vec3(side * (torsoRadius + 0.03 * s), waistY - 0.07 * s, 0.05 * s), 0.035 * s)
                    .bone(.pelvis).mat(2).tint(Vec3(1.8, 1.7, 1.5)).blend(0.006 * s))
            }
        }
        if v.has("beads") {
            for k in 0..<14 {
                let a = Float(k) / 14 * kTwoPi
                let p = J(.neck) + Vec3(cos(a) * 0.1 * bulk, -0.04 - 0.07 * max(0, sin(a)), sin(a) * 0.09 * bulk) * s
                model.add(SDFPrim.sphere(p, 0.016 * s).bone(.spine2).mat(4).tint(Vec3(0.6, 0.4, 0.3)).blend(0.003 * s))
            }
        }
        if v.has("tusks") {
            for side: Float in [-1, 1] {
                model.add(SDFPrim.cone(H(Vec3(0.03 * side, 0.03, 0.09)), halfHeight: 0.025 * s, r1: 0.01 * s, r2: 0.002 * s)
                    .bone(.head).mat(2).tint(Vec3(1.9, 1.8, 1.6)).blend(0.003 * s))
            }
        }
        if v.has("eyepatch") {
            model.add(SDFPrim.ellipsoid(H(Vec3(0.031, 0.09, 0.09)), Vec3(0.022, 0.018, 0.012) * s).bone(.head).mat(2).blend(0.003 * s))
            model.add(SDFPrim.torus(H(Vec3(0, 0.1, 0.0)), major: 0.09 * s, minor: 0.004 * s, rot: Quat(axis: Vec3(0, 0, 1), angle: 0.3))
                .bone(.head).mat(2).blend(0.002))
        }
        if v.has("halo") {
            model.add(SDFPrim.torus(H(Vec3(0, 0.12, -0.14)), major: 0.16 * s, minor: 0.008 * s, rot: Quat(axis: Vec3(1, 0, 0), angle: 1.4))
                .bone(.head).mat(7).glow(1).blend(0.002))
        }
        if v.has("lantern") {
            let p = Vec3(-(torsoRadius + 0.05 * s), waistY - 0.14 * s, 0.02 * s)
            model.add(SDFPrim.box(p, Vec3(0.035, 0.05, 0.035) * s, rounding: 0.005 * s).bone(.pelvis).mat(4).blend(0.002))
            model.add(SDFPrim.sphere(p, 0.03 * s).bone(.pelvis).mat(7).glow(1).blend(0.002))
        }
        if v.has("wings") {
            for side: Float in [-1, 1] {
                for k in 0..<4 {
                    let kf = Float(k)
                    let base = J(.spine2) + Vec3(0.08 * side, 0.12, -0.14) * s
                    let tip = base + Vec3(side * (0.3 + 0.12 * kf), 0.35 - 0.18 * kf, -0.15) * s
                    model.add(SDFPrim.roundCone(base, tip, 0.03 * s, 0.008 * s).bone(.spine2).mat(4).blend(0.01 * s))
                }
            }
        }

        // ------------------------------------------------------------------ Polygonize
        var opts = SurfaceNetsOptions()
        opts.voxelSize = 0.0115 * s / max(0.5, quality)
        opts.featureScale = s
        opts.skinned = true
        model.weightFalloff = 0.022 * s
        let mesh = SurfaceNets.polygonize(model, name: "character", options: opts)

        var cape: CapeSpec?
        let mats = materials(for: v)
        switch v.cape {
        case "short": cape = CapeSpec(length: 0.7 * s, width: 0.5 * s * bulk, tattered: false, isScarf: false, material: mats[6])
        case "long": cape = CapeSpec(length: 1.25 * s, width: 0.6 * s * bulk, tattered: false, isScarf: false, material: mats[6])
        case "tattered": cape = CapeSpec(length: 1.1 * s, width: 0.6 * s * bulk, tattered: true, isScarf: false, material: mats[6])
        case "scarf": cape = CapeSpec(length: 0.95 * s, width: 0.14 * s, tattered: false, isScarf: true, material: mats[6])
        default: break
        }
        return BuiltCharacter(mesh: mesh, materials: mats, cape: cape, ponytail: v.hair == "ponytail" && hairAllowed, height: v.body.height)
    }
}
