// Player settings (graphics, audio, accessibility, controls). Saved as JSON next to the
// save file and applied live.
import Foundation

public enum QualityPreset: String, Codable, CaseIterable { case low, medium, high, ultra }

/// Every bindable input action (gameplay, menus and debug tools).
public enum InputAction: String, CaseIterable, Codable {
    case moveForward, moveBack, moveLeft, moveRight
    case light, heavy, ability, parry, dodge, swapNext, swapPrev, heal, lockOn, pause
    case confirm, back, menuUp, menuDown, menuLeft, menuRight
    case debugOverlay, debugHitboxes, debugFrameData, debugAI, debugFreeCam, debugInvincible, debugSlowmo
    case debugBossSelect, debugReload, debugDump, debugKillBoss, screenshot

    public var playerAction: PlayerAction? {
        switch self {
        case .light: return .light
        case .heavy: return .heavy
        case .ability: return .ability
        case .parry: return .parry
        case .dodge: return .dodge
        case .swapNext: return .swapNext
        case .swapPrev: return .swapPrev
        case .heal: return .heal
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .moveForward: return "Move Forward"
        case .moveBack: return "Move Back"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .light: return "Light Attack"
        case .heavy: return "Heavy Attack (hold)"
        case .ability: return "Weapon Ability"
        case .parry: return "Parry / Block (hold)"
        case .dodge: return "Dodge"
        case .swapNext: return "Next Weapon (hold: radial)"
        case .swapPrev: return "Previous Weapon"
        case .heal: return "Heal"
        case .lockOn: return "Lock On"
        case .pause: return "Pause"
        case .confirm: return "Confirm"
        case .back: return "Back"
        case .menuUp: return "Menu Up"
        case .menuDown: return "Menu Down"
        case .menuLeft: return "Menu Left"
        case .menuRight: return "Menu Right"
        case .debugOverlay: return "Debug Overlay"
        case .debugHitboxes: return "Hitboxes"
        case .debugFrameData: return "Frame Data"
        case .debugAI: return "Boss AI Debug"
        case .debugFreeCam: return "Free Camera"
        case .debugInvincible: return "Invincibility"
        case .debugSlowmo: return "Slow Motion"
        case .debugBossSelect: return "Boss Select Cheat"
        case .debugReload: return "Reload Data"
        case .debugDump: return "Dump State to Log"
        case .debugKillBoss: return "Kill Boss"
        case .screenshot: return "Screenshot"
        }
    }

    public static let rebindable: [InputAction] = [.moveForward, .moveBack, .moveLeft, .moveRight, .light, .heavy, .ability, .parry,
                                                   .dodge, .swapNext, .swapPrev, .heal, .lockOn, .pause]
}

public struct Settings: Codable, Equatable {
    public var quality: QualityPreset = .high
    public var resolutionScale: Float = 1
    public var upscaler = "taa"            // taa, metalfx
    public var shadows = true
    public var ssao = true
    public var ssr = true
    public var volumetrics = true
    public var bloom = true
    public var motionBlur = true
    public var dof = true
    public var chromaticAberration = true
    public var filmGrain = true
    public var vignette = true
    public var contactShadows = true
    public var particles: Float = 1
    public var cloth = true
    public var fpsCap = 120
    public var showFPS = true
    public var masterVolume: Float = 0.8
    public var musicVolume: Float = 0.7
    public var sfxVolume: Float = 0.9
    public var uiVolume: Float = 0.7
    public var timingAssist: Float = 1
    public var shakeIntensity: Float = 1
    public var flashing = true
    public var colorblind = false
    public var subtitles = true
    public var mouseSensitivity: Float = 1
    public var stickSensitivity: Float = 1
    public var invertY = false
    public var hardMode = false
    public var bindings: [String: [String]] = Settings.defaultBindings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        quality = try c.v(.quality, d.quality); resolutionScale = try c.v(.resolutionScale, d.resolutionScale)
        upscaler = try c.v(.upscaler, d.upscaler); shadows = try c.v(.shadows, d.shadows); ssao = try c.v(.ssao, d.ssao)
        ssr = try c.v(.ssr, d.ssr); volumetrics = try c.v(.volumetrics, d.volumetrics); bloom = try c.v(.bloom, d.bloom)
        motionBlur = try c.v(.motionBlur, d.motionBlur); dof = try c.v(.dof, d.dof)
        chromaticAberration = try c.v(.chromaticAberration, d.chromaticAberration); filmGrain = try c.v(.filmGrain, d.filmGrain)
        vignette = try c.v(.vignette, d.vignette); contactShadows = try c.v(.contactShadows, d.contactShadows)
        particles = try c.v(.particles, d.particles); cloth = try c.v(.cloth, d.cloth); fpsCap = try c.v(.fpsCap, d.fpsCap)
        showFPS = try c.v(.showFPS, d.showFPS); masterVolume = try c.v(.masterVolume, d.masterVolume)
        musicVolume = try c.v(.musicVolume, d.musicVolume); sfxVolume = try c.v(.sfxVolume, d.sfxVolume); uiVolume = try c.v(.uiVolume, d.uiVolume)
        timingAssist = try c.v(.timingAssist, d.timingAssist); shakeIntensity = try c.v(.shakeIntensity, d.shakeIntensity)
        flashing = try c.v(.flashing, d.flashing); colorblind = try c.v(.colorblind, d.colorblind); subtitles = try c.v(.subtitles, d.subtitles)
        mouseSensitivity = try c.v(.mouseSensitivity, d.mouseSensitivity); stickSensitivity = try c.v(.stickSensitivity, d.stickSensitivity)
        invertY = try c.v(.invertY, d.invertY); hardMode = try c.v(.hardMode, d.hardMode)
        var b = try c.v(.bindings, d.bindings)
        for (k, v) in Settings.defaultBindings() where b[k] == nil { b[k] = v }
        bindings = b
    }

    /// Input ids: "key:<macOS virtual key code>", "ctrl+key:<code>", "shift+key:<code>", "mouse:<button>", "wheel:up|down", "pad:<element>".
    public static func defaultBindings() -> [String: [String]] {
        [
            "moveForward": ["key:13", "key:126"], "moveBack": ["key:1", "key:125"], "moveLeft": ["key:0", "key:123"], "moveRight": ["key:2", "key:124"],
            "light": ["mouse:0", "pad:rightShoulder"],
            "heavy": ["key:14", "mouse:4", "pad:rightTrigger"],
            "ability": ["key:3", "pad:leftTrigger"],
            "parry": ["mouse:1", "pad:leftShoulder"],
            "dodge": ["key:49", "pad:buttonB"],
            "swapNext": ["key:48", "wheel:down", "pad:buttonY"],
            "swapPrev": ["wheel:up", "shift+key:48", "pad:dpadLeft"],
            "heal": ["key:15", "pad:buttonX"],
            "lockOn": ["key:12", "mouse:2", "pad:rightThumbstickButton"],
            "pause": ["key:53", "pad:buttonMenu"],
            "confirm": ["key:36", "key:49", "pad:buttonA"],
            "back": ["key:53", "key:51", "pad:buttonB"],
            "menuUp": ["key:126", "key:13", "pad:dpadUp"], "menuDown": ["key:125", "key:1", "pad:dpadDown"],
            "menuLeft": ["key:123", "key:0", "pad:dpadLeft"], "menuRight": ["key:124", "key:2", "pad:dpadRight"],
            "debugOverlay": ["key:122", "key:50", "ctrl+key:18"],
            "debugHitboxes": ["key:120", "ctrl+key:19"],
            "debugFrameData": ["key:99", "ctrl+key:20"],
            "debugAI": ["key:118", "ctrl+key:21"],
            "debugFreeCam": ["key:96", "ctrl+key:23"],
            "debugInvincible": ["key:97", "ctrl+key:22"],
            "debugSlowmo": ["key:98", "ctrl+key:26"],
            "debugBossSelect": ["key:100", "ctrl+key:28"],
            "debugReload": ["key:101", "ctrl+key:25"],
            "debugDump": ["key:109", "ctrl+key:29"],
            "debugKillBoss": ["key:103", "ctrl+key:40"],
            "screenshot": ["key:111", "ctrl+key:1"],
        ]
    }

    public mutating func applyPreset(_ q: QualityPreset) {
        quality = q
        switch q {
        case .low:
            resolutionScale = 0.7; shadows = true; ssao = false; ssr = false; volumetrics = false; bloom = true; motionBlur = false
            dof = false; contactShadows = false; particles = 0.35; cloth = true
        case .medium:
            resolutionScale = 0.85; shadows = true; ssao = true; ssr = false; volumetrics = true; bloom = true; motionBlur = false
            dof = true; contactShadows = false; particles = 0.6; cloth = true
        case .high:
            resolutionScale = 1; shadows = true; ssao = true; ssr = true; volumetrics = true; bloom = true; motionBlur = true
            dof = true; contactShadows = true; particles = 1; cloth = true
        case .ultra:
            resolutionScale = 1; shadows = true; ssao = true; ssr = true; volumetrics = true; bloom = true; motionBlur = true
            dof = true; contactShadows = true; particles = 1; cloth = true
        }
    }

    public func renderSettings() -> RenderSettings {
        var r = RenderSettings()
        r.resolutionScale = resolutionScale
        r.shadowSize = quality == .low ? 1024 : (quality == .ultra ? 4096 : 2048)
        r.shadows = shadows
        r.ssao = ssao
        r.ssr = ssr
        r.volumetrics = volumetrics
        r.bloom = bloom
        r.motionBlur = motionBlur
        r.dof = dof
        r.chromaticAberration = chromaticAberration && flashing
        r.filmGrain = filmGrain
        r.vignette = vignette
        r.taa = true
        r.metalFX = upscaler == "metalfx"
        r.particleBudget = Int(65536 * max(0.25, particles))
        r.contactShadows = contactShadows
        r.flashing = flashing
        return r
    }

    public static func load() -> Settings {
        guard let d = try? Data(contentsOf: Paths.settingsFile) else { return Settings() }
        do { return try JSONDecoder().decode(Settings.self, from: d) } catch {
            logWarn("settings.json unreadable, using defaults: \(JSONUtil.describe(error))", "save")
            return Settings()
        }
    }

    public func save() {
        Paths.ensureDirectories()
        guard let d = try? JSONUtil.encodePretty(self) else { return }
        let tmp = Paths.settingsFile.appendingPathExtension("tmp")
        do {
            try d.write(to: tmp)
            _ = try? FileManager.default.removeItem(at: Paths.settingsFile)
            try FileManager.default.moveItem(at: tmp, to: Paths.settingsFile)
        } catch { logError("could not save settings: \(error)", "save") }
    }
}

/// Weapon skins (procedural color / material variants) and trail styles, unlocked by achievements.
public struct WeaponSkin {
    public var id: String
    public var name: String
    public var unlock: String
    public var apply: (inout WeaponVisual) -> Void
}

public struct TrailStyle {
    public var id: String
    public var name: String
    public var unlock: String
    public var head: Vec3
    public var tail: Vec3
    public var intensity: Float
}

public enum Cosmetics {
    public static let skins: [WeaponSkin] = [
        WeaponSkin(id: "default", name: "Forged", unlock: "Default") { _ in },
        WeaponSkin(id: "crimson", name: "Crimson Temper", unlock: "Clear The Crimson Monastery") { v in
            v.metal = "#b04040"; v.glow = "#ff3a3a"; v.glowStrength = 0.5 },
        WeaponSkin(id: "ember", name: "Ember Forged", unlock: "Clear The Ashen Forge") { v in
            v.metal = "#5a3a30"; v.glow = "#ff7a20"; v.glowStrength = 0.8; v.element = .fire },
        WeaponSkin(id: "frost", name: "Rimeglass", unlock: "Land 10 deathblows") { v in
            v.metal = "#b8e0f8"; v.glow = "#8ad8ff"; v.glowStrength = 0.7; v.element = .ice },
        WeaponSkin(id: "gilded", name: "Gilded Court", unlock: "Clear The Hollow Court") { v in
            v.metal = "#e0b860"; v.trim = "#fff0c0"; v.glow = "#ffd070"; v.glowStrength = 0.3 },
        WeaponSkin(id: "spectral", name: "Spectral", unlock: "Defeat any boss without taking a hit") { v in
            v.metal = "#a0fff0"; v.glow = "#60ffe0"; v.glowStrength = 1.2 },
        WeaponSkin(id: "obsidian", name: "Obsidian Eclipse", unlock: "Clear The Eclipse Sanctum") { v in
            v.metal = "#1a1620"; v.glow = "#9a5aff"; v.glowStrength = 0.9; v.element = .shadow },
        WeaponSkin(id: "storm", name: "Stormcaller", unlock: "Land 100 perfect parries") { v in
            v.metal = "#c0d0ff"; v.glow = "#8ab8ff"; v.glowStrength = 1.0; v.element = .lightning },
        WeaponSkin(id: "sovereign", name: "Sovereign", unlock: "Defeat The Blade Sovereign") { v in
            v.metal = "#2a2a32"; v.trim = "#ffd070"; v.glow = "#ffd070"; v.glowStrength = 1.0; v.element = .holy },
        WeaponSkin(id: "void", name: "Voidborn", unlock: "Defeat The Blade Sovereign on Hard Mode") { v in
            v.metal = "#0a0810"; v.glow = "#ff3aff"; v.glowStrength = 1.4; v.element = .shadow },
    ]

    public static let trails: [TrailStyle] = [
        TrailStyle(id: "default", name: "Weapon Colors", unlock: "Default", head: .zero, tail: .zero, intensity: 0),
        TrailStyle(id: "ember", name: "Ember", unlock: "Clear The Ashen Forge", head: Vec3(1, 0.8, 0.4), tail: Vec3(1, 0.2, 0.02), intensity: 4),
        TrailStyle(id: "frost", name: "Frost", unlock: "Clear The Frost Citadel", head: Vec3(0.9, 1, 1), tail: Vec3(0.2, 0.6, 1), intensity: 3.5),
        TrailStyle(id: "void", name: "Void", unlock: "Clear The Eclipse Sanctum", head: Vec3(0.9, 0.6, 1), tail: Vec3(0.3, 0.05, 0.6), intensity: 4),
        TrailStyle(id: "prism", name: "Prism", unlock: "Defeat a boss with only perfect parries (5+)", head: Vec3(1, 1, 1), tail: Vec3(1, 0.3, 0.9), intensity: 4),
        TrailStyle(id: "lightning", name: "Lightning", unlock: "Land 100 perfect parries", head: Vec3(0.9, 0.95, 1), tail: Vec3(0.4, 0.5, 1), intensity: 6),
        TrailStyle(id: "sovereign", name: "Sovereign Gold", unlock: "Defeat The Blade Sovereign", head: Vec3(1, 0.95, 0.7), tail: Vec3(1, 0.6, 0.1), intensity: 5),
    ]
}
