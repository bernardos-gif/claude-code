// The player character's look: a hooded wandering swordsman with a crimson scarf.
import Foundation

public enum PlayerLook {
    public static func visual(skin: String = "#c8a080") -> CharacterVisual {
        var v = CharacterVisual()
        v.body.height = 1.8
        v.body.bulk = 1.0
        v.body.muscle = 0.6
        v.skin = skin
        v.outfit = "tunic"
        v.chest = "leather"
        v.pauldrons = "layered"
        v.helmet = "hood"
        v.hair = "short"
        v.arms = "bracers"
        v.legs = "boots"
        v.skirt = "coat"
        v.cape = "scarf"
        v.extras = ["belt", "pouches"]
        v.colors.primary = "#23262e"
        v.colors.secondary = "#8e1414"
        v.colors.leather = "#3a2616"
        v.colors.metal = "#8a8e98"
        v.colors.trim = "#9a7a3a"
        v.colors.hair = "#1a1410"
        v.armorMaterial = "dark"
        v.wear = 0.45
        return v
    }
}
