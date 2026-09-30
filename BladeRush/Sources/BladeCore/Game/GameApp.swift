// Top-level game: screens, modes (Campaign Rush, Boss Select, Endless Gauntlet, Hard Mode),
// progression, unlocks, autosave, debug tools. Platform code feeds `FrameInput` in and
// renders the `RenderFrame` that `buildFrame` returns.
import Foundation

public struct InputEvent {
    public var action: InputAction
    public var pressed: Bool
    public var offset: Double
    public init(action: InputAction, pressed: Bool, offset: Double) { self.action = action; self.pressed = pressed; self.offset = offset }
}

public struct FrameInput {
    public var events: [InputEvent] = []
    public var move = Vec2.zero            // x right, y forward
    public var look = Vec2.zero            // radians this frame
    public var freeMove = Vec3.zero
    public var mouse = Vec2.zero           // pixels (top-left origin)
    public var mouseMoved = false
    public var click = false
    public var gamepad = false             // last used device
    public var captured: String?           // raw input id while rebinding
    public var radial = Vec2.zero          // accumulated radial selection direction
    public var anyKey = false
    public init() {}
    public func pressed(_ a: InputAction) -> Bool { events.contains { $0.action == a && $0.pressed } }
}

public enum Screen: Equatable {
    case title, main, campaign, bossSelect, armory, stats, settings, prep, loading, fight, victory, death, endlessOver, credits
}

public enum RunMode: Equatable { case campaign(Int), single, endless }

public final class RunSession {
    public let mode: RunMode
    public var queue: [String]
    public var index = 0
    public var weaponIndex: Int
    public var score = 0
    public var cleared = 0
    public var hard: Bool
    public var carryHealth: Float?
    public var carryFlasks: Int?
    public var lastFightStats = FightStats()
    public var lastTime: Double = 0
    public var unlocks: [String] = []

    public init(mode: RunMode, queue: [String], weaponIndex: Int, hard: Bool) {
        self.mode = mode; self.queue = queue; self.weaponIndex = weaponIndex; self.hard = hard
    }
    public var current: String? { index < queue.count ? queue[index] : nil }
}

public struct DebugState {
    public var overlay = false
    public var hitboxes = false
    public var frameData = false
    public var ai = false
    public var freeCam = false
    public var invincible = false
    public var slowmoLevel = 0          // 0 = 1x, 1 = 0.5x, 2 = 0.25x
    public var allBosses = false
    public var gpuPasses: [(String, Double)] = []
    public var gpuTotal: Double = 0
    public var drawCalls = 0
    public var triangles = 0
    public var particles = 0
    public var renderSize = Vec2.zero
    public var cpu = CPUProfiler()
    public var fps: Double = 0
    public var frameMs: Double = 0
}

public final class GameApp {
    public let data: GameDataStore
    public var settings: Settings
    public var save: SaveData
    public let audio = AudioDirector()
    public let fx = FXSystem()
    public let watcher = FileWatcher()
    public private(set) var screen: Screen = .title
    public private(set) var world: World?
    public private(set) var session: RunSession?
    public var paused = false
    public var debug = DebugState()
    public var time: Double = 0
    public var menuCursor: [String: Int] = [:]
    public var settingsTab = 0
    public var armoryWeapon = 0
    public var capturing: InputAction?
    public var captureRequested: Bool { capturing != nil }
    public var quitRequested = false
    public var screenshotRequested = false
    public var hitRects: [(Vec4, Int)] = []       // menu item rects for mouse hit testing
    public var screenTime: Double = 0
    public var prepWeapon = 0
    public let menuScene: MenuScene
    private var pendingEncounter: String?
    private var swapHeldSince: Double?
    public private(set) var radialOpen = false
    public private(set) var radialSelection = 0
    public var lastInput = FrameInput()
    public var toast: (String, Double)?
    public var sceneBuilder = SceneBuilder()
    public var statsScroll = 0

    public init() {
        Paths.ensureDirectories()
        data = GameDataStore()
        settings = Settings.load()
        save = SaveData.load()
        menuScene = MenuScene(data: data)
        prepWeapon = max(0, data.weapons.firstIndex { $0.id == save.lastWeapon } ?? 0)
        fx.flashingEnabled = settings.flashing
        watcher.watch(data.tuning.url) { [weak self] _ in self?.data.tuning.reload(); self?.showToast("Tuning reloaded") }
        watcher.watch(Paths.dataFile("animations.json")) { [weak self] _ in self?.data.anims.load(); self?.showToast("Animations reloaded") }
        for f in ["weapons.json", "attacks.json", "bosses.json", "arenas.json"] {
            watcher.watch(Paths.dataFile(f)) { [weak self] _ in
                self?.data.reloadAll()
                ContentCache.clear()
                self?.showToast("\(f) reloaded (applies to the next fight)")
            }
        }
    }

    /// Heavy one-time setup (sound synthesis); call after the window is visible.
    public func loadAssets() {
        audio.load()
        audio.setVolumes(settings)
        audio.enterMenu()
    }

    public func showToast(_ s: String) { toast = (s, time + 2.5) }

    // MARK: - Flow

    public func go(_ s: Screen) {
        if s != screen { screenTime = 0 }
        screen = s
        if s == .main || s == .title { audio.enterMenu(); world = nil; fx.reset() }
    }

    public var weapons: [PlayerWeaponDef] {
        // Apply equipped skins.
        data.weapons.map { w in
            var w2 = w
            if let sid = save.equippedSkin[w.id], let skin = Cosmetics.skins.first(where: { $0.id == sid }) { skin.apply(&w2.visual) }
            return w2
        }
    }

    public func startCampaign(tier: Int) {
        guard let t = data.tiers.first(where: { $0.index == tier }) else { return }
        var queue = t.encounters
        if let firstUndefeated = queue.firstIndex(where: { !save.isDefeated($0) }) { queue = Array(queue[firstUndefeated...]) }
        session = RunSession(mode: .campaign(tier), queue: queue, weaponIndex: prepWeapon, hard: settings.hardMode && save.hardModeUnlocked)
        go(.prep)
        preloadCurrent()
    }

    public func startSingle(_ encounter: String) {
        session = RunSession(mode: .single, queue: [encounter], weaponIndex: prepWeapon, hard: settings.hardMode && save.hardModeUnlocked)
        go(.prep)
        preloadCurrent()
    }

    public func startEndless() {
        var pool = data.encounterOrder.filter { save.isDefeated($0) && data.encounters[$0]?.kind == "boss" }
        if pool.count < 3 { pool = data.encounterOrder.filter { (data.encounters[$0]?.tier ?? 99) <= max(2, save.unlockedTier) && data.encounters[$0]?.kind == "boss" } }
        var rng = Rng(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        rng.shuffle(&pool)
        var queue: [String] = []
        for i in 0..<200 { queue.append(pool[i % max(1, pool.count)]) }
        session = RunSession(mode: .endless, queue: queue, weaponIndex: prepWeapon, hard: settings.hardMode && save.hardModeUnlocked)
        go(.prep)
        preloadCurrent()
    }

    private func preloadCurrent() {
        guard let id = session?.current, let enc = data.encounters[id] else { return }
        ContentCache.preload(encounter: enc, data: data, quality: meshQuality, playerVisual: PlayerLook.visual())
    }

    public var meshQuality: Float {
        switch settings.quality {
        case .low: return 0.6
        case .medium: return 0.8
        case .high: return 1.0
        case .ultra: return 1.2
        }
    }

    /// Begins the current encounter (shows the loading screen for a frame first).
    public func beginFight() {
        guard let s = session, let id = s.current else { return }
        pendingEncounter = id
        s.weaponIndex = prepWeapon
        save.lastWeapon = data.weapons[safe: prepWeapon]?.id ?? "katana"
        go(.loading)
    }

    private func buildWorld(_ id: String) {
        guard let enc = data.encounters[id], let s = session else { return }
        fx.reset()
        let w = World(data: data, encounter: enc, playerWeapons: weapons, startWeapon: s.weaponIndex, playerVisual: PlayerLook.visual(),
                      hardMode: s.hard, timingAssist: Double(settings.timingAssist), quality: meshQuality,
                      flasks: s.mode == .endless ? s.carryFlasks : nil)
        if s.mode == .endless, let hp = s.carryHealth { w.player.fighter.health = max(30, hp) }
        w.player.invincible = debug.invincible
        w.debugTimeScale = debugTimeScale
        world = w
        audio.enterArena(w.arena.def)
        save.attempts[id, default: 0] += 1
        paused = false
        sceneBuilder.cameraCut = true
        go(.fight)
        logInfo("fight started: \(id) (\(enc.name)) weapon=\(weapons[safe: s.weaponIndex]?.id ?? "?") hard=\(s.hard)", "game")
    }

    public func retry() {
        guard session != nil else { return }
        beginFight()
    }

    private var debugTimeScale: Double { [1.0, 0.5, 0.25][debug.slowmoLevel] }

    private func onVictory(_ w: World) {
        guard let s = session, let id = s.current else { return }
        let st = w.player.stats
        s.lastFightStats = st
        s.lastTime = st.time
        s.unlocks = []
        s.cleared += 1
        let enc = data.encounters[id]
        if !save.defeated.contains(id) { save.defeated.append(id) }
        if s.hard && !save.hardDefeated.contains(id) { save.hardDefeated.append(id) }
        if save.bestTimes[id].map({ st.time < $0 }) ?? true { save.bestTimes[id] = st.time }
        save.stats.bossesDefeated += 1
        accumulate(st)
        // Tier progression.
        if case .campaign(let tier) = s.mode, let t = data.tiers.first(where: { $0.index == tier }),
           t.encounters.allSatisfy({ save.isDefeated($0) }), save.unlockedTier <= tier {
            save.unlockedTier = tier + 1
            s.unlocks.append("Unlocked: \(data.tiers.first(where: { $0.index == tier + 1 })?.name ?? "the next tier")")
        }
        // Achievements.
        func award(_ a: String, skin: String? = nil, trail: String? = nil, text: String) {
            var any = save.achieve(a)
            if let sk = skin, save.unlock(skin: sk) { any = true }
            if let tr = trail, save.unlock(trail: tr) { any = true }
            if any { s.unlocks.append(text) }
        }
        if st.hitsTaken == 0 { award("nohit", skin: "spectral", text: "No-hit victory! Unlocked skin: Spectral") }
        if st.parries >= 5 && st.parries == st.perfectParries { award("perfectOnly", trail: "prism", text: "Only perfect parries! Unlocked trail: Prism") }
        if save.stats.deathblows >= 10 { award("deathblows10", skin: "frost", text: "Unlocked skin: Rimeglass") }
        if save.stats.perfectParries >= 100 { award("perfect100", skin: "storm", trail: "lightning", text: "100 perfect parries! Unlocked Stormcaller + Lightning trail") }
        let tierClears: [(Int, String?, String?, String)] = [(3, "crimson", nil, "Crimson Temper"), (5, "ember", "ember", "Ember Forged + Ember trail"),
                                                             (6, nil, "frost", "Frost trail"), (7, "gilded", nil, "Gilded Court"), (9, "obsidian", "void", "Obsidian Eclipse + Void trail")]
        for (tier, skin, trail, name) in tierClears {
            if let t = data.tiers.first(where: { $0.index == tier }), t.encounters.allSatisfy({ save.isDefeated($0) }) {
                award("tier\(tier)", skin: skin, trail: trail, text: "Unlocked: \(name)")
            }
        }
        if enc?.kind == "final" {
            save.hardModeUnlocked = true
            award("sovereign", skin: "sovereign", trail: "sovereign", text: "Hard Mode unlocked! Unlocked Sovereign skin and trail")
            if s.hard { award("sovereignHard", skin: "void", text: "Unlocked skin: Voidborn") }
        }
        if s.mode == .endless {
            let tier = enc?.tier ?? 1
            s.score += 1000 * tier + max(0, Int(600 - st.time * 5)) + (st.hitsTaken == 0 ? 1500 : 0) + st.perfectParries * 50
            s.carryHealth = w.player.fighter.health
            s.carryFlasks = min(3, w.player.flasks + 1)
        }
        save.save()
    }

    private func onDefeat(_ w: World) {
        guard let s = session, let id = s.current else { return }
        save.deaths[id, default: 0] += 1
        save.stats.deaths += 1
        accumulate(w.player.stats)
        if s.mode == .endless {
            if s.score > save.endlessBest { save.endlessBest = s.score; s.unlocks = ["New personal best!"] }
            save.endlessBestBosses = max(save.endlessBestBosses, s.cleared)
        }
        save.save()
    }

    private func accumulate(_ st: FightStats) {
        save.stats.parries += st.parries
        save.stats.perfectParries += st.perfectParries
        save.stats.perfectDodges += st.perfectDodges
        save.stats.dodges += st.dodges
        save.stats.hitsTaken += st.hitsTaken
        save.stats.damageDealt += st.damageDealt
        save.stats.playTime += st.time
        if let w = world { save.stats.deathblows += w.bosses.reduce(0) { $0 + $1.stats.deathblows } }
    }

    public func continueAfterVictory() {
        guard let s = session else { go(.main); return }
        s.index += 1
        switch s.mode {
        case .campaign:
            if s.current != nil { go(.prep); preloadCurrent() } else {
                if data.encounters[s.queue.last ?? ""]?.kind == "final" { go(.credits) } else { go(.campaign) }
            }
        case .single:
            go(.bossSelect)
        case .endless:
            go(.prep); preloadCurrent()
        }
        world = nil
        audio.enterMenu()
    }

    // MARK: - Update

    public func update(dt: Double, input: FrameInput) {
        time += dt
        screenTime += dt
        lastInput = input
        watcher.poll(dt: dt)
        debug.cpu.begin()
        handleGlobal(input)
        switch screen {
        case .loading:
            if screenTime > 0.05, let id = pendingEncounter {
                pendingEncounter = nil
                timed("build world \(id)", "load") { buildWorld(id) }
            }
        case .fight:
            updateFight(dt: dt, input: input)
        case .victory, .death:
            if let w = world { w.update(realDt: dt, inputs: [], moveInput: .zero, look: .zero); drainWorldEvents(w) }
            handleMenuInput(input)
        default:
            menuScene.update(dt: Float(dt))
            handleMenuInput(input)
        }
        let camPos = world?.camera.eye ?? menuScene.cameraPos
        let camFwd = world.map { $0.camera.lookAt - $0.camera.eye } ?? (menuScene.cameraTarget - menuScene.cameraPos)
        fx.particleScale = settings.particles
        fx.flashingEnabled = settings.flashing
        debug.cpu.measure("fx") {
            fx.update(dt: Float(dt), world: world, arena: world?.arena ?? menuScene.arena, cameraPos: camPos,
                      timeScale: Float(world?.timeScale ?? 1))
        }
        audio.update(world: world, cameraPos: camPos, cameraForward: camFwd, fx: fx)
        debug.cpu.end()
    }

    private func handleGlobal(_ input: FrameInput) {
        for e in input.events where e.pressed {
            switch e.action {
            case .debugOverlay: debug.overlay.toggle()
            case .debugHitboxes: debug.hitboxes.toggle()
            case .debugFrameData: debug.frameData.toggle()
            case .debugAI: debug.ai.toggle()
            case .debugFreeCam:
                debug.freeCam.toggle()
                if let w = world {
                    w.camera.mode = debug.freeCam ? .free : .follow
                    w.camera.freePos = w.camera.position
                }
                showToast(debug.freeCam ? "Free camera ON (WASD + mouse, Space/Ctrl up/down)" : "Free camera OFF")
            case .debugInvincible:
                debug.invincible.toggle()
                world?.player.invincible = debug.invincible
                showToast(debug.invincible ? "Invincibility ON" : "Invincibility OFF")
            case .debugSlowmo:
                debug.slowmoLevel = (debug.slowmoLevel + 1) % 3
                world?.debugTimeScale = debugTimeScale
                showToast("Time scale \(debugTimeScale)x")
            case .debugBossSelect:
                debug.allBosses.toggle()
                showToast(debug.allBosses ? "Boss select cheat: all bosses unlocked" : "Boss select cheat off")
                if screen != .fight { go(.bossSelect) }
            case .debugReload:
                data.reloadAll(); data.tuning.reload(); ContentCache.clear()
                showToast("All data reloaded")
            case .debugDump:
                if let w = world { logInfo(w.debugDump(), "dump"); Log.shared.flush(); showToast("State dumped to log") }
            case .debugKillBoss:
                world?.debugKillBoss()
            case .screenshot:
                screenshotRequested = true
            default: break
            }
        }
    }

    private func updateFight(dt: Double, input: FrameInput) {
        guard let w = world else { go(.main); return }
        if input.pressed(.pause) && !radialOpen {
            paused.toggle()
            menuCursor["pause"] = 0
            audio.ui(paused ? "ui_confirm" : "ui_back")
        }
        if paused {
            handleMenuInput(input)
            return
        }
        // Translate inputs; lock-on and the radial menu are handled here.
        var timed: [TimedInput] = []
        for e in input.events {
            if e.action == .lockOn && e.pressed { w.toggleLockOn(); continue }
            if e.action == .swapNext {
                if e.pressed { swapHeldSince = time; continue }
                if let since = swapHeldSince {
                    swapHeldSince = nil
                    if radialOpen {
                        radialOpen = false
                        w.radialOpen = false
                        w.player.swap(to: radialSelection, ctx: w)
                        continue
                    }
                    if time - since < 0.25 {
                        timed.append(TimedInput(action: .swapNext, pressed: true, offset: e.offset))
                        timed.append(TimedInput(action: .swapNext, pressed: false, offset: e.offset))
                    }
                }
                continue
            }
            if let pa = e.action.playerAction { timed.append(TimedInput(action: pa, pressed: e.pressed, offset: e.offset)) }
            if w.fightPhase == .intro && e.pressed && e.action == .confirm { w.skipIntro() }
        }
        if let since = swapHeldSince, time - since >= 0.25, !radialOpen {
            radialOpen = true
            w.radialOpen = true
            radialSelection = w.player.weapon.id == weapons[safe: radialSelection]?.id ? radialSelection : (weapons.firstIndex { $0.id == w.player.weapon.id } ?? 0)
        }
        if radialOpen && vlength2(input.radial) > 0.35 {
            let a = atan2(input.radial.x, -input.radial.y)
            let n = weapons.count
            radialSelection = (Int(((a / kTwoPi + 1).truncatingRemainder(dividingBy: 1)) * Float(n) + 0.5)) % n
        }
        let look = debug.freeCam || !radialOpen ? input.look : .zero
        debug.cpu.measure("sim") {
            w.update(realDt: dt, inputs: timed, moveInput: debug.freeCam ? .zero : input.move, look: look, freeMove: input.freeMove)
        }
        drainWorldEvents(w)
        switch w.fightPhase {
        case .victory where w.phaseTime > 3.2:
            onVictory(w)
            go(.victory)
            menuCursor["victory"] = 0
        case .defeat where w.phaseTime > 2.2:
            onDefeat(w)
            go(session?.mode == .endless ? .endlessOver : .death)
            menuCursor["death"] = 0
        default: break
        }
    }

    private func drainWorldEvents(_ w: World) {
        let events = w.drainEvents()
        fx.process(events, world: w)
        audio.handle(events, world: w)
        for e in events {
            if case let .subtitle(speaker, text, duration) = e, settings.subtitles {
                w.subtitles.append((speaker, text, w.realTime + duration))
            }
            if case let .phaseStart(_, _, _, lighting) = e { w.lighting = lighting }
        }
    }

    // MARK: - Menu input

    private func moveCursor(_ key: String, _ delta: Int, count: Int, enabled: (Int) -> Bool) {
        guard count > 0 else { return }
        var c = menuCursor[key] ?? 0
        for _ in 0..<count {
            c = (c + delta + count) % count
            if enabled(c) { break }
        }
        menuCursor[key] = c
        audio.ui("ui_move")
    }

    private func handleMenuInput(_ input: FrameInput) {
        if let cap = capturing {
            if let id = input.captured {
                if id == "key:53" { capturing = nil; return }   // Esc cancels
                rebind(cap, to: id)
                capturing = nil
                audio.ui("ui_confirm")
            }
            return
        }
        if screen == .title {
            if input.anyKey || input.click || input.pressed(.confirm) { go(.main); audio.ui("ui_confirm") }
            return
        }
        let (key, items) = MenuBuilder.items(for: self)
        guard !items.isEmpty else { return }
        var cursor = min(menuCursor[key] ?? 0, items.count - 1)
        if !items[cursor].enabled, let first = items.firstIndex(where: { $0.enabled }) { cursor = first; menuCursor[key] = first }
        // Mouse hover / click.
        if input.mouseMoved || input.click {
            for (r, idx) in hitRects where input.mouse.x >= r.x && input.mouse.x <= r.x + r.z && input.mouse.y >= r.y && input.mouse.y <= r.y + r.w {
                if idx < items.count && items[idx].enabled && idx != cursor { menuCursor[key] = idx; cursor = idx }
                if input.click && idx < items.count && items[idx].enabled { activate(items[idx], dir: 0) }
            }
        }
        for e in input.events where e.pressed {
            switch e.action {
            case .menuUp: moveCursor(key, -1, count: items.count) { items[$0].enabled }
            case .menuDown: moveCursor(key, 1, count: items.count) { items[$0].enabled }
            case .menuLeft: activate(items[min(menuCursor[key] ?? 0, items.count - 1)], dir: -1)
            case .menuRight: activate(items[min(menuCursor[key] ?? 0, items.count - 1)], dir: 1)
            case .confirm: activate(items[min(menuCursor[key] ?? 0, items.count - 1)], dir: 0)
            case .back: back()
            default: break
            }
        }
        if screen == .prep, let c = menuCursor["prep"], c < data.weapons.count { prepWeapon = c }
    }

    private func activate(_ item: MenuItem, dir: Int) {
        guard item.enabled else { return }
        switch item.kind {
        case .action(let f):
            if dir == 0 { audio.ui("ui_confirm"); f() }
        case .toggle(let get, let set):
            set(!get()); audio.ui("ui_move"); applySettings()
        case .slider(let get, let set, let step, let lo, let hi):
            let d = dir == 0 ? 1 : dir
            var v = get() + step * Float(d)
            if dir == 0 && v > hi + 1e-4 { v = lo }
            set(clampf(v, lo, hi)); audio.ui("ui_move"); applySettings()
        case .choice(let options, let get, let set):
            let d = dir == 0 ? 1 : dir
            set((get() + d + options.count) % options.count); audio.ui("ui_move"); applySettings()
        case .info:
            break
        }
    }

    public func back() {
        audio.ui("ui_back")
        switch screen {
        case .fight: paused = false
        case .campaign, .bossSelect, .armory, .stats: go(.main)
        case .settings: go(paused && world != nil ? .fight : .main)
        case .prep:
            switch session?.mode {
            case .campaign?: go(.campaign)
            case .single?: go(.bossSelect)
            default: go(.main)
            }
        case .death, .endlessOver, .credits: go(.main)
        case .main: break
        default: go(.main)
        }
    }

    public func applySettings() {
        audio.setVolumes(settings)
        fx.flashingEnabled = settings.flashing
        world?.timingAssist = Double(settings.timingAssist)
        world?.camera.shakeScale = settings.shakeIntensity
        settings.save()
    }

    private func rebind(_ action: InputAction, to id: String) {
        var list = settings.bindings[action.rawValue] ?? []
        let isPad = id.hasPrefix("pad:")
        list.removeAll { ($0.hasPrefix("pad:")) == isPad }
        list.insert(id, at: 0)
        settings.bindings[action.rawValue] = list
        settings.save()
        showToast("\(action.displayName) -> \(KeyNames.name(id))")
    }

    public func requestQuit() { quitRequested = true }

    public func buildFrame(width: Int, height: Int) -> RenderFrame {
        debug.cpu.measure("build") { sceneBuilder.build(app: self, width: Float(width), height: Float(height)) }
    }
}

extension Array {
    public subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

/// Human-readable names for input ids.
public enum KeyNames {
    static let keys: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
        53: "Esc", 55: "Cmd", 56: "Shift", 57: "Caps", 58: "Option", 59: "Ctrl", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]

    public static func name(_ id: String) -> String {
        var mods = ""
        var rest = id
        for m in ["ctrl+", "shift+", "alt+"] where rest.hasPrefix(m) {
            mods += m.dropLast().capitalized + "+"
            rest = String(rest.dropFirst(m.count))
        }
        if rest.hasPrefix("key:"), let c = Int(rest.dropFirst(4)) { return mods + (keys[c] ?? "Key\(c)") }
        if rest.hasPrefix("mouse:") {
            switch rest.dropFirst(6) {
            case "0": return mods + "LMB"
            case "1": return mods + "RMB"
            case "2": return mods + "MMB"
            default: return mods + "Mouse\(rest.dropFirst(6))"
            }
        }
        if rest == "wheel:up" { return mods + "Wheel Up" }
        if rest == "wheel:down" { return mods + "Wheel Down" }
        if rest.hasPrefix("pad:") {
            let n = String(rest.dropFirst(4))
            let map = ["buttonA": "A/Cross", "buttonB": "B/Circle", "buttonX": "X/Square", "buttonY": "Y/Triangle", "leftShoulder": "LB/L1",
                       "rightShoulder": "RB/R1", "leftTrigger": "LT/L2", "rightTrigger": "RT/R2", "buttonMenu": "Menu",
                       "rightThumbstickButton": "R3", "leftThumbstickButton": "L3", "dpadLeft": "D-Left", "dpadRight": "D-Right",
                       "dpadUp": "D-Up", "dpadDown": "D-Down"]
            return map[n] ?? n
        }
        return id
    }

    /// First keyboard/mouse binding and first gamepad binding for an action.
    public static func prompt(_ a: InputAction, settings: Settings, gamepad: Bool) -> String {
        let list = settings.bindings[a.rawValue] ?? []
        let pick = list.first { gamepad ? $0.hasPrefix("pad:") : !$0.hasPrefix("pad:") } ?? list.first
        return pick.map { name($0) } ?? "?"
    }
}
