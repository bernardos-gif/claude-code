// Menu item model and per-screen item lists. The same lists drive input handling (in
// GameApp) and layout (in UIBuilder), so mouse hit-testing always matches what is drawn.
import Foundation

public struct MenuItem {
    public enum Kind {
        case action(() -> Void)
        case toggle(() -> Bool, (Bool) -> Void)
        case slider(() -> Float, (Float) -> Void, Float, Float, Float)   // get, set, step, min, max
        case choice([String], () -> Int, (Int) -> Void)
        case info
    }
    public var label: String
    public var value: String
    public var enabled: Bool
    public var kind: Kind
    public var detail: String

    public init(_ label: String, value: String = "", enabled: Bool = true, detail: String = "", _ kind: Kind) {
        self.label = label; self.value = value; self.enabled = enabled; self.kind = kind; self.detail = detail
    }

    /// Current value text for toggles / sliders / choices.
    public var valueText: String {
        switch kind {
        case .toggle(let g, _): return g() ? "On" : "Off"
        case .slider(let g, _, let step, _, _): return step < 0.1 ? String(format: "%.0f%%", g() * 100) : String(format: "%.2f", g())
        case .choice(let opts, let g, _): return opts[max(0, min(opts.count - 1, g()))]
        default: return value
        }
    }
}

public enum MenuBuilder {
    static let roman = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"]

    public static func items(for app: GameApp) -> (String, [MenuItem]) {
        switch app.screen {
        case .main: return ("main", main(app))
        case .campaign: return ("campaign", campaign(app))
        case .bossSelect: return ("bossSelect", bossSelect(app))
        case .prep: return ("prep", prep(app))
        case .settings: return ("settings\(app.settingsTab)", settings(app))
        case .armory: return ("armory", armory(app))
        case .stats: return ("stats", [MenuItem("Back", .action { app.back() })])
        case .victory: return ("victory", victory(app))
        case .death: return ("death", death(app))
        case .endlessOver: return ("endless", [MenuItem("Run Again", .action { app.startEndless() }), MenuItem("Main Menu", .action { app.go(.main) })])
        case .credits: return ("credits", [MenuItem("Return to Main Menu", .action { app.go(.main) })])
        case .fight where app.paused: return ("pause", pause(app))
        default: return ("none", [])
        }
    }

    static func main(_ app: GameApp) -> [MenuItem] {
        var items = [
            MenuItem("Campaign Rush", detail: "Fight the tiers in order. Clearing a tier unlocks the next.", .action { app.go(.campaign) }),
            MenuItem("Boss Select", detail: "Replay any defeated boss.", .action { app.go(.bossSelect) }),
            MenuItem("Endless Gauntlet", detail: "Random bosses back to back. Best: \(app.save.endlessBest)", .action { app.startEndless() }),
        ]
        if app.save.hardModeUnlocked {
            items.append(MenuItem("Hard Mode", detail: "Tighter windows, faster bosses, new attacks.",
                                  .toggle({ app.settings.hardMode }, { app.settings.hardMode = $0 })))
        }
        items += [
            MenuItem("Armory", detail: "Weapon skins and trails earned through achievements.", .action { app.go(.armory) }),
            MenuItem("Statistics", detail: "Deaths per boss, perfect parries, best times.", .action { app.go(.stats) }),
            MenuItem("Settings", detail: "Graphics, audio, accessibility and controls.", .action { app.settingsTab = 0; app.go(.settings) }),
            MenuItem("Quit", .action { app.requestQuit() }),
        ]
        return items
    }

    static func campaign(_ app: GameApp) -> [MenuItem] {
        app.data.tiers.map { t in
            let done = t.encounters.filter { app.save.isDefeated($0) }.count
            let unlocked = t.index <= app.save.unlockedTier || app.debug.allBosses
            let names = t.encounters.compactMap { app.data.encounters[$0]?.name }.joined(separator: " · ")
            return MenuItem("\(roman[min(t.index, 12)])  \(t.name)", value: unlocked ? "\(done)/\(t.encounters.count)" : "LOCKED", enabled: unlocked,
                            detail: "\(t.subtitle). \(names)", .action { app.startCampaign(tier: t.index) })
        }
    }

    static func bossSelect(_ app: GameApp) -> [MenuItem] {
        app.data.encounterOrder.compactMap { id -> MenuItem? in
            guard let e = app.data.encounters[id] else { return nil }
            let beaten = app.save.isDefeated(id)
            let best = app.save.bestTimes[id].map { String(format: "best %d:%02d", Int($0) / 60, Int($0) % 60) } ?? ""
            let deaths = app.save.deaths[id] ?? 0
            return MenuItem(e.name, value: beaten ? best : "???", enabled: beaten || app.debug.allBosses,
                            detail: "\(e.title). Deaths: \(deaths)", .action { app.startSingle(id) })
        }
    }

    static func prep(_ app: GameApp) -> [MenuItem] {
        var items: [MenuItem] = app.weapons.enumerated().map { (i, w) in
            MenuItem(w.name, detail: w.description, .action { app.prepWeapon = i; app.beginFight() })
        }
        items.append(MenuItem("Back", .action { app.back() }))
        return items
    }

    static func pause(_ app: GameApp) -> [MenuItem] {
        [MenuItem("Resume", .action { app.paused = false }),
         MenuItem("Retry", .action { app.retry() }),
         MenuItem("Settings", .action { app.settingsTab = 0; app.go(.settings) }),
         MenuItem("Quit to Menu", .action { app.paused = false; app.go(.main) })]
    }

    static func victory(_ app: GameApp) -> [MenuItem] {
        var items = [MenuItem("Continue", .action { app.continueAfterVictory() })]
        if app.session?.mode == .single { items.append(MenuItem("Fight Again", .action { app.retry() })) }
        return items
    }

    static func death(_ app: GameApp) -> [MenuItem] {
        [MenuItem("Retry", .action { app.retry() }),
         MenuItem("Change Weapon", .action { app.go(.prep) }),
         MenuItem("Quit to Menu", .action { app.go(.main) })]
    }

    static func settings(_ app: GameApp) -> [MenuItem] {
        let tabs = ["Graphics", "Audio", "Gameplay & Accessibility", "Controls"]
        var items: [MenuItem] = [MenuItem("Category", .choice(tabs, { app.settingsTab }, { app.settingsTab = $0 }))]
        let s = { app.settings }
        switch app.settingsTab {
        case 0:
            items += [
                MenuItem("Quality Preset", .choice(QualityPreset.allCases.map { $0.rawValue.capitalized },
                                                   { QualityPreset.allCases.firstIndex(of: s().quality) ?? 2 },
                                                   { app.settings.applyPreset(QualityPreset.allCases[$0]) })),
                MenuItem("Resolution Scale", .slider({ s().resolutionScale }, { app.settings.resolutionScale = $0 }, 0.05, 0.5, 1.0)),
                MenuItem("Upscaler", .choice(["TAA", "MetalFX"], { s().upscaler == "metalfx" ? 1 : 0 }, { app.settings.upscaler = $0 == 1 ? "metalfx" : "taa" })),
                MenuItem("FPS Cap", .choice(["60", "120", "Unlimited"], { s().fpsCap == 60 ? 0 : (s().fpsCap == 120 ? 1 : 2) },
                                            { app.settings.fpsCap = [60, 120, 0][$0] })),
                MenuItem("Show FPS", .toggle({ s().showFPS }, { app.settings.showFPS = $0 })),
                MenuItem("Shadows", .toggle({ s().shadows }, { app.settings.shadows = $0 })),
                MenuItem("Contact Shadows", .toggle({ s().contactShadows }, { app.settings.contactShadows = $0 })),
                MenuItem("Ambient Occlusion", .toggle({ s().ssao }, { app.settings.ssao = $0 })),
                MenuItem("Screen-Space Reflections", .toggle({ s().ssr }, { app.settings.ssr = $0 })),
                MenuItem("Volumetric Fog", .toggle({ s().volumetrics }, { app.settings.volumetrics = $0 })),
                MenuItem("Bloom", .toggle({ s().bloom }, { app.settings.bloom = $0 })),
                MenuItem("Motion Blur", .toggle({ s().motionBlur }, { app.settings.motionBlur = $0 })),
                MenuItem("Depth of Field", .toggle({ s().dof }, { app.settings.dof = $0 })),
                MenuItem("Chromatic Aberration", .toggle({ s().chromaticAberration }, { app.settings.chromaticAberration = $0 })),
                MenuItem("Film Grain", .toggle({ s().filmGrain }, { app.settings.filmGrain = $0 })),
                MenuItem("Vignette", .toggle({ s().vignette }, { app.settings.vignette = $0 })),
                MenuItem("Particles", .slider({ s().particles }, { app.settings.particles = $0 }, 0.05, 0.25, 1)),
                MenuItem("Cloth Simulation", .toggle({ s().cloth }, { app.settings.cloth = $0 })),
            ]
        case 1:
            items += [
                MenuItem("Master Volume", .slider({ s().masterVolume }, { app.settings.masterVolume = $0 }, 0.05, 0, 1)),
                MenuItem("Music Volume", .slider({ s().musicVolume }, { app.settings.musicVolume = $0 }, 0.05, 0, 1)),
                MenuItem("Effects Volume", .slider({ s().sfxVolume }, { app.settings.sfxVolume = $0 }, 0.05, 0, 1)),
                MenuItem("UI Volume", .slider({ s().uiVolume }, { app.settings.uiVolume = $0 }, 0.05, 0, 1)),
                MenuItem("Subtitles", .toggle({ s().subtitles }, { app.settings.subtitles = $0 })),
            ]
        case 2:
            items += [
                MenuItem("Timing Assist", detail: "Widens parry and dodge windows (1.0 = default, 2.0 = double).",
                         .slider({ s().timingAssist }, { app.settings.timingAssist = $0 }, 0.1, 1, 2)),
                MenuItem("Screen Shake", .slider({ s().shakeIntensity }, { app.settings.shakeIntensity = $0 }, 0.05, 0, 1)),
                MenuItem("Flashing Effects", detail: "Screen flashes and chromatic pulses.", .toggle({ s().flashing }, { app.settings.flashing = $0 })),
                MenuItem("Colorblind Telegraphs", detail: "Adds shapes to telegraph colors: circle, triangle, wave, diamond.",
                         .toggle({ s().colorblind }, { app.settings.colorblind = $0 })),
                MenuItem("Subtitles", .toggle({ s().subtitles }, { app.settings.subtitles = $0 })),
                MenuItem("Mouse Sensitivity", .slider({ s().mouseSensitivity }, { app.settings.mouseSensitivity = $0 }, 0.1, 0.2, 3)),
                MenuItem("Stick Sensitivity", .slider({ s().stickSensitivity }, { app.settings.stickSensitivity = $0 }, 0.1, 0.2, 3)),
                MenuItem("Invert Camera Y", .toggle({ s().invertY }, { app.settings.invertY = $0 })),
            ]
        default:
            for a in InputAction.rebindable {
                let kb = KeyNames.prompt(a, settings: app.settings, gamepad: false)
                let pad = KeyNames.prompt(a, settings: app.settings, gamepad: true)
                items.append(MenuItem(a.displayName, value: "\(kb)   |   \(pad)", detail: "Enter: rebind (press a key, mouse button or gamepad button)",
                                      .action { app.capturing = a }))
            }
            items.append(MenuItem("Reset Controls to Default", .action {
                app.settings.bindings = Settings.defaultBindings(); app.settings.save(); app.showToast("Controls reset")
            }))
        }
        items.append(MenuItem("Back", .action { app.back() }))
        return items
    }

    static func armory(_ app: GameApp) -> [MenuItem] {
        let ws = app.data.weapons
        guard !ws.isEmpty else { return [] }
        let w = ws[min(app.armoryWeapon, ws.count - 1)]
        let skins = Cosmetics.skins.filter { app.save.unlockedSkins.contains($0.id) }
        let trails = Cosmetics.trails.filter { app.save.unlockedTrails.contains($0.id) }
        var items: [MenuItem] = [
            MenuItem("Weapon", .choice(ws.map { $0.name }, { app.armoryWeapon }, { app.armoryWeapon = $0 })),
            MenuItem("Skin", .choice(skins.map { $0.name }, {
                skins.firstIndex { $0.id == (app.save.equippedSkin[w.id] ?? "default") } ?? 0
            }, { app.save.equippedSkin[w.id] = skins[$0].id; app.save.save() })),
            MenuItem("Trail", .choice(trails.map { $0.name }, {
                trails.firstIndex { $0.id == (app.save.equippedTrail[w.id] ?? "default") } ?? 0
            }, { app.save.equippedTrail[w.id] = trails[$0].id; app.save.save() })),
        ]
        for s in Cosmetics.skins where !app.save.unlockedSkins.contains(s.id) {
            items.append(MenuItem("Locked skin: \(s.name)", value: s.unlock, enabled: false, .info))
        }
        for t in Cosmetics.trails where !app.save.unlockedTrails.contains(t.id) {
            items.append(MenuItem("Locked trail: \(t.name)", value: t.unlock, enabled: false, .info))
        }
        items.append(MenuItem("Back", .action { app.back() }))
        return items
    }
}

/// Animated 3D background for the menus: the swordsman standing in an arena.
public final class MenuScene {
    public let arena: BuiltArena?
    public let fighter: Fighter?
    public private(set) var cameraPos = Vec3(0, 1.6, 4)
    public private(set) var cameraTarget = Vec3(0, 1.2, 0)
    private var t: Float = 0

    public init(data: GameDataStore) {
        let def = data.arenas["throne_of_blades"] ?? data.arenas.values.first
        arena = def.map { ContentCache.arena($0, quality: 0.8) }
        if let w = data.weapons.first {
            let f = Fighter(isPlayer: true, name: "menu", visual: PlayerLook.visual(), weapons: [w.visual], maxHealth: 100, maxPosture: 100,
                            radius: 0.4, lib: data.anims, quality: 0.9)
            f.position = Vec3(0, 0, 2)
            f.yaw = kPi * 0.95
            f.animator.teleport(position: f.position, yaw: f.yaw)
            fighter = f
        } else {
            fighter = nil
        }
    }

    public func update(dt: Float) {
        t += dt
        guard let f = fighter else { return }
        if !f.animator.isPlaying && Int(t) % 9 == 0 && t - Float(Int(t)) < dt * 1.5 {
            let rest = f.animator.library.pose("rest", grip: f.grip)
            f.animator.play(AnimTrack.pose(from: f.animator.pose, to: rest, inTime: 0.8, hold: 3.5, outTime: 0.8, end: f.animator.stance()), fade: 0.1)
        }
        f.updateAnimation(dt: dt, running: false)
        f.updateCloth(dt: dt)
        let a = t * 0.06 + kPi - 0.55
        cameraTarget = f.position + Vec3(0, 1.25, 0)
        cameraPos = f.position + Vec3(sin(a) * 3.6, 1.35 + sin(t * 0.2) * 0.15, cos(a) * 3.6 - 0.6)
    }
}
