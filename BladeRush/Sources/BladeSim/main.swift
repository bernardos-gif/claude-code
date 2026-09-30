// BladeSim — headless tool: preview renders, data validation, bot simulations, self tests.
import BladeCore
import Foundation

let args = CommandLine.arguments
Log.shared.echoToConsole = true

func outURL(_ name: String) -> URL {
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("preview", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

func previewBody(_ visual: CharacterVisual, name: String, poses: [(String, RigPose)], lib: AnimLibrary, grip: GripStyle) {
    let sk = Skeleton(visual.body)
    let built = timed("build \(name)") { CharacterBuilder.build(visual, skeleton: sk) }
    logInfo("\(name): \(built.mesh.vertices.count) verts, \(built.mesh.triangleCount) tris")
    let cols = built.materials.map { $0.color + $0.emissive * 0 }
    let em = built.materials.map { $0.emissiveStrength > 0 ? Float(1) : 0 }
    let cellW = 300, cellH = 420
    let n = poses.count + 2
    let r = PreviewRenderer(width: cellW * n, height: cellH)
    let h = visual.body.height
    let target = Vec3(0, h * 0.52, 0)
    // Bind pose front and side.
    let bindPal = sk.skinMatrices(sk.bindGlobals)
    r.render([PreviewItem(mesh: built.mesh, model: .identity, palette: bindPal, colors: cols, emissive: em)],
             eye: target + Vec3(0, 0.1, 3.6 * h / 1.8), target: target, viewport: (0, 0, cellW, cellH))
    r.render([PreviewItem(mesh: built.mesh, model: .identity, palette: bindPal, colors: cols, emissive: em)],
             eye: target + Vec3(3.6 * h / 1.8, 0.1, 0), target: target, viewport: (cellW, 0, cellW, cellH))
    for (i, (_, rp)) in poses.enumerated() {
        let res = Rig.solve(rp, skeleton: sk, grip: grip, twoHandOffset: -0.12)
        let pal = sk.skinMatrices(res.globals)
        var lines: [PreviewLine] = []
        let wpos = res.weaponR.pos
        lines.append(PreviewLine(wpos, wpos + res.weaponR.rot.rotate(Vec3(0, 0, 0.9)), Vec3(1, 0.9, 0.3)))
        r.render([PreviewItem(mesh: built.mesh, model: .identity, palette: pal, colors: cols, emissive: em)], lines: lines,
                 eye: target + Vec3(2.2, 0.6, 3.0) * (h / 1.8), target: target, viewport: (cellW * (i + 2), 0, cellW, cellH))
    }
    try? r.image.writePNG(to: outURL("\(name).png"))
}

let cmd = args.count > 1 ? args[1] : "help"
switch cmd {
case "preview-body":
    let lib = AnimLibrary()
    lib.load()
    var v = CharacterVisual()
    v.helmet = "hood"; v.cape = "scarf"; v.chest = "leather"; v.arms = "bracers"; v.extras = ["belt"]
    previewBody(v, name: "body_default", poses: [("stance", lib.stance(.twoHand))], lib: lib, grip: .twoHand)
case "preview-anims":
    let lib = AnimLibrary()
    lib.load()
    let grips: [GripStyle] = args.count > 2 ? [GripStyle(rawValue: args[2]) ?? .oneHand] : [.oneHand, .twoHand, .polearm, .dual]
    let strikes = args.count > 3 ? args[3].split(separator: ",").map(String.init) : ["slash_h", "overhead", "diag", "thrust", "low_sweep", "rising"]
    var v = CharacterVisual()
    v.helmet = "none"; v.chest = "plate"; v.arms = "gauntlets"; v.legs = "greaves"
    let sk = Skeleton(v.body)
    let built = CharacterBuilder.build(v, skeleton: sk, quality: 0.6)
    let cols = built.materials.map { $0.color }
    for grip in grips {
        let cw = 190, ch = 250
        let r = PreviewRenderer(width: cw * 5, height: ch * strikes.count)
        for (row, st) in strikes.enumerated() {
            let rs = lib.strike(st, grip: grip, side: "R")
            let keys = [lib.stance(grip), rs.windup, rs.impact, rs.end, rs.follow]
            for (col, rp) in keys.enumerated() {
                let res = Rig.solve(rp, skeleton: sk, grip: grip, twoHandOffset: grip == .polearm ? 0.4 : -0.12)
                let pal = sk.skinMatrices(res.globals)
                let len: Float = grip == .polearm ? 1.8 : (grip == .dual ? 0.35 : 0.95)
                var lines = [PreviewLine(res.weaponR.pos, res.weaponR.pos + res.weaponR.rot.rotate(Vec3(0, 0, len)), Vec3(1, 0.9, 0.2))]
                if grip == .dual {
                    lines.append(PreviewLine(res.weaponL.pos, res.weaponL.pos + res.weaponL.rot.rotate(Vec3(0, 0, len)), Vec3(0.3, 0.9, 1)))
                }
                let target = Vec3(0, 1.0, 0.2)
                r.render([PreviewItem(mesh: built.mesh, model: .identity, palette: pal, colors: cols)], lines: lines,
                         eye: target + Vec3(-3.0, 1.2, 2.2), target: target, fov: 42, viewport: (col * cw, row * ch, cw, ch))
            }
        }
        try? r.image.writePNG(to: outURL("anims_\(grip.rawValue).png"))
    }
case "preview-weapons":
    let ids = WeaponCatalog.all.keys.sorted()
    let cols = 9
    let cw = 160, ch = 300
    let rows = (ids.count + cols - 1) / cols
    let r = PreviewRenderer(width: cw * cols, height: ch * rows)
    for (i, id) in ids.enumerated() {
        var v = WeaponVisual(type: id)
        v.glowStrength = ["frost_rapier", "molten_greatblade", "storm_spear"].contains(id) ? 1 : 0
        v.glow = "#66ccff"
        let m = WeaponCatalog.mesh(v)
        let mats = WeaponCatalog.materials(v)
        let wt = WeaponCatalog.get(id)
        // Stand the weapon up: +Z (blade) -> +Y.
        let model = Mat4.rotationX(-kPi / 2)
        let len = max(wt.reach, 0.5)
        var items = [PreviewItem(mesh: m, model: model, colors: mats.map { $0.color + $0.emissive }, emissive: mats.map { $0.emissiveStrength > 0 ? 1 : 0 })]
        var lines: [PreviewLine] = []
        for hb in wt.hitboxes {
            lines.append(PreviewLine(model.transformPoint(hb.a), model.transformPoint(hb.b), Vec3(1, 0.2, 0.2)))
        }
        if let f = wt.flex {
            let head = WeaponCatalog.flexHeadMesh(v, head: f.head, radius: f.headRadius)
            items.append(PreviewItem(mesh: head, model: Mat4.translation(Vec3(0.25, 0.3, 0)) * model, colors: mats.map { $0.color }))
        }
        let target = Vec3(0, len * 0.4, 0)
        r.render(items, lines: lines, eye: target + Vec3(len * 0.9, len * 0.2, len * 1.6), target: target, fov: 40,
                 viewport: ((i % cols) * cw, (i / cols) * ch, cw, ch))
        logInfo("\(id): \(m.triangleCount) tris")
    }
    try? r.image.writePNG(to: outURL("weapons.png"))
case "app-smoke":
    // Drives the full GameApp without a window: menus, a fight with the bot, frame building and audio.
    setenv("BLADERUSH_HOME", FileManager.default.temporaryDirectory.appendingPathComponent("bladerush-smoke").path, 1)
    let app = timed("GameApp init") { GameApp() }
    timed("assets") { app.loadAssets() }
    let dt = 1.0 / 60
    var frames = 0
    var maxUI = 0, maxDraws = 0, maxParticles = 0, maxTrailVerts = 0
    func frame(_ events: [InputEvent] = [], move: Vec2 = .zero, any: Bool = false) {
        var inp = FrameInput()
        inp.events = events
        inp.move = move
        inp.anyKey = any
        app.update(dt: dt, input: inp)
        let f = app.buildFrame(width: 1920, height: 1080)
        maxUI = max(maxUI, f.ui.items.count); maxDraws = max(maxDraws, f.draws.count)
        maxParticles = max(maxParticles, f.particleSpawns.count); maxTrailVerts = max(maxTrailVerts, f.trailVertices.count)
        frames += 1
    }
    func press(_ a: InputAction) { frame([InputEvent(action: a, pressed: true, offset: 0), InputEvent(action: a, pressed: false, offset: 0.01)]) }
    frame(any: true)                       // title -> main
    print("screen after title: \(app.screen)")
    press(.confirm)                        // Campaign Rush
    print("screen: \(app.screen)")
    press(.confirm)                        // Tier I
    print("screen: \(app.screen)")
    press(.confirm)                        // begin with first weapon
    for _ in 0..<5 { frame() }             // loading -> fight
    print("screen: \(app.screen) world: \(app.world != nil)")
    let bot = PlayerBot(skill: 0.9, perfectBias: 0.6, seed: 3)
    var left = [Float](repeating: 0, count: 800), right = [Float](repeating: 0, count: 800)
    var peak: Float = 0, nan = false
    var t = 0.0
    while t < 90, app.screen == .fight {
        guard let w = app.world else { break }
        let (inputs, move) = bot.think(world: w, dt: dt)
        let evs = inputs.compactMap { ti -> InputEvent? in
            let map: [PlayerAction: InputAction] = [.light: .light, .heavy: .heavy, .ability: .ability, .parry: .parry, .dodge: .dodge, .heal: .heal]
            return map[ti.action].map { InputEvent(action: $0, pressed: ti.pressed, offset: ti.offset) }
        }
        frame(evs, move: move)
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in app.audio.mixer.render(frames: 800, left: l.baseAddress!, right: r.baseAddress!) } }
        for v in left { if !v.isFinite { nan = true }; peak = max(peak, abs(v)) }
        t += dt
    }
    print("after fight: screen \(app.screen) t=\(String(format: "%.1f", t))s frames \(frames)")
    for _ in 0..<240 { frame() }
    print("final screen: \(app.screen)")
    press(.confirm)
    for _ in 0..<10 { frame() }
    print("after continue: \(app.screen)")
    print("max ui items \(maxUI) draws \(maxDraws) particle spawns/frame \(maxParticles) trail verts \(maxTrailVerts) audio peak \(peak) nan \(nan)")
    print("save: defeated \(app.save.defeated) unlockedTier \(app.save.unlockedTier)")
case "icon":
    // Writes the app icon at every macOS iconset size: BladeSim icon <dir>
    let dir = URL(fileURLWithPath: args.count > 2 ? args[2] : "preview/AppIcon.iconset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                         ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        let url = dir.appendingPathComponent("icon_\(name).png")
        do { try IconArt.render(size: size).writePNG(to: url) } catch { print("failed \(url.path): \(error)"); exit(1) }
    }
    print("iconset written to \(dir.path)")
case "selftest":
    let results = SelfTests.runAll()
    var failed = 0
    for r in results {
        print("\(r.passed ? "PASS" : "FAIL")  \(r.name)")
        for f in r.failures { print("      \(f)") }
        if !r.passed { failed += 1 }
    }
    print("\(results.count - failed)/\(results.count) passed")
    exit(failed == 0 ? 0 : 1)
case "validate":
    let data = GameDataStore()
    print("problems: \(data.problems.count)")
    for p in data.problems { print("  - \(p)") }
    for id in data.bossOrder {
        guard let b = data.bosses[id] else { continue }
        let atk = data.resolveAttacks(b)
        let tels = Dictionary(grouping: atk, by: { $0.telegraph.rawValue }).mapValues { $0.count }
        print(String(format: "%-16@ tier %2d  hp %5.0f  posture %4.0f  attacks %2d  phases %d  %@", b.id as NSString, b.tier, b.stats.health, b.stats.posture,
                     atk.count, b.phases.count, tels.description as NSString))
    }
case "simulate":
    let data = GameDataStore()
    let target = args.count > 2 ? args[2] : "all"
    let seconds = args.count > 3 ? Double(args[3]) ?? 180 : 180
    let ids = target == "all" ? data.encounterOrder : [target]
    var summary: [String] = []
    for eid in ids {
        guard let enc = data.encounters[eid] else { print("unknown encounter \(eid)"); continue }
        let world = World(data: data, encounter: enc, playerWeapons: data.weapons, startWeapon: (eid.hashValue & 0x7fffffff) % max(1, data.weapons.count),
                          playerVisual: PlayerLook.visual(), hardMode: false, timingAssist: 1, quality: 0.3)
        let bot = PlayerBot(skill: 0.85, perfectBias: 0.5, seed: Rng.hash(eid))
        let dt = 1.0 / 60
        var t = 0.0
        var counts: [String: Int] = [:]
        var nan = false
        while t < seconds {
            let (inputs, move) = bot.think(world: world, dt: dt)
            world.update(realDt: dt, inputs: inputs, moveInput: move, look: .zero)
            for e in world.drainEvents() {
                let k = String(describing: e).split(separator: "(").first.map(String.init) ?? "?"
                counts[k, default: 0] += 1
            }
            t += dt
            if !world.player.fighter.position.x.isFinite || world.bosses.contains(where: { !$0.fighter.position.x.isFinite }) { nan = true; break }
            if world.fightPhase == .victory || world.fightPhase == .defeat { break }
        }
        let b = world.bosses.first!
        let line = String(format: "%-26@ %-8@ t=%6.1fs  player hp %5.1f  boss hp %6.1f/%6.1f phase %d  parries %d (perfect %d) hits taken %d  dodges %d%@",
                          eid as NSString, "\(world.fightPhase)" as NSString, t, world.player.fighter.health, b.fighter.health, b.fighter.maxHealth, b.phase,
                          world.player.stats.parries, world.player.stats.perfectParries, world.player.stats.hitsTaken, world.player.stats.dodges,
                          nan ? " NaN!" : "")
        print(line)
        summary.append(line)
        if target != "all" { print(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
    }
default:
    print("usage: BladeSim preview-body | preview-anims [grip] [strikes]")
}
