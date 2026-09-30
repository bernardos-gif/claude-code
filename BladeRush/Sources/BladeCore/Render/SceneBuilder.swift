// Converts the game state (menu scene or fight) into a RenderFrame for the renderer.
import Foundation

public struct SceneBuilder {
    private var prevModels: [String: Mat4] = [:]
    private var prevPalettes: [Int: [Mat4]] = [:]
    private var envKey = ""
    private var env = EnvironmentParams()
    private var skyVersion = 0
    public var cameraCut = true
    private var linkMeshCache: [String: MeshData] = [:]

    public init() {}

    mutating func prev(_ key: String, _ m: Mat4) -> Mat4 {
        let p = cameraCut ? m : (prevModels[key] ?? m)
        prevModels[key] = m
        return p
    }

    // MARK: Environment

    mutating func environment(arena: ArenaDef, lighting: String, blend: Float, lightning: Float, time: Float) -> EnvironmentParams {
        let q = Int(blend * 20)
        let key = "\(arena.id)|\(lighting)|\(q)"
        if key != envKey {
            envKey = key
            skyVersion += 1
            var e = EnvironmentParams()
            var sunColor = parseColor(arena.sunColor)
            var sunI = arena.sunIntensity
            var fogColor = parseColor(arena.fogColor)
            var fogDensity = arena.fogDensity
            var sky = SkyPreset.named(arena.sky)
            var rim = parseColor(arena.rimColor)
            if let sh = arena.shifts[lighting], blend > 0 {
                if !sh.sunColor.isEmpty { sunColor = vlerp(sunColor, parseColor(sh.sunColor), blend) }
                if let si = sh.sunIntensity { sunI = lerpf(sunI, si, blend) }
                if !sh.fogColor.isEmpty { fogColor = vlerp(fogColor, parseColor(sh.fogColor), blend) }
                if let fd = sh.fogDensity { fogDensity = lerpf(fogDensity, fd, blend) }
                if !sh.sky.isEmpty && blend > 0.5 { sky = SkyPreset.named(sh.sky) }
                if !sh.rimColor.isEmpty { rim = vlerp(rim, parseColor(sh.rimColor), blend) }
            }
            let sunDir = vnormalize(arena.sunDir)
            e.sky = sky.params(sunDir: sunDir, sunColor: sunColor)
            e.sunDirection = sunDir
            e.sunColor = sunColor
            e.sunIntensity = sunI
            e.ambientIntensity = arena.ambient
            let ground = parseColor(arena.floorColor)
            var shc = SkyMath.irradianceSH(sky: e.sky, sunDir: sunDir, sunIntensity: sunI, ambientScale: arena.ambient * 2.2, groundColor: ground)
            if !arena.ambientColor.isEmpty {
                let tint = parseColor(arena.ambientColor)
                shc = shc.map { Vec4($0.xyz * (tint * 0.6 + Vec3(0.4, 0.4, 0.4)), 0) }
            }
            e.sh = shc
            e.fogColor = fogColor
            e.fogDensity = fogDensity
            e.fogHeight = arena.fogHeight
            e.fogScatter = arena.fogScatter
            e.rimColor = rim
            e.rimIntensity = arena.rimIntensity
            e.wetness = arena.wet
            e.floorMaterial = ArenaBuilder.floorMaterial(arena)
            env = e
        }
        var out = env
        out.lightning = lightning
        out.sky.params.z = time
        out.sky.params.w = lightning
        return out
    }

    // MARK: Build

    public mutating func build(app: GameApp, width: Float, height: Float) -> RenderFrame {
        var f = RenderFrame()
        f.settings = app.settings.renderSettings()
        f.time = Float(app.time)
        // Simulation delta for GPU particles: follows hitstop / slow motion and stops while paused.
        let inFight = app.screen == .fight || app.screen == .victory || app.screen == .death
        f.dt = app.paused && app.screen == .fight ? 0 : Float(app.lastDt) * Float(inFight ? min(1, (app.world?.timeScale ?? 1) * 1.5 + 0.1) : 1)
        f.cameraCut = cameraCut
        let aspect = width / max(height, 1)
        var arenaDef: ArenaDef?
        var built: BuiltArena?
        if let w = app.world, app.screen == .fight || app.screen == .victory || app.screen == .death {
            let cam = w.camera
            f.view = cam.viewMatrix
            f.proj = cam.projection(aspect: aspect)
            f.cameraPosition = cam.eye
            f.fovY = cam.fov + cam.fovKick
            built = w.arena
            arenaDef = w.arena.def
            f.env = environment(arena: w.arena.def, lighting: w.lighting, blend: w.lightingBlend, lightning: app.fx.lightning, time: f.time)
            addWorld(&f, app: app, world: w)
        } else {
            let ms = app.menuScene
            f.view = Mat4.lookAt(eye: ms.cameraPos, target: ms.cameraTarget, up: Vec3(0, 1, 0))
            f.proj = Mat4.perspective(fovyRadians: 40 * kDeg2Rad, aspect: aspect, near: 0.08, far: 600)
            f.cameraPosition = ms.cameraPos
            f.fovY = 40
            built = ms.arena
            arenaDef = ms.arena?.def
            if let a = ms.arena?.def { f.env = environment(arena: a, lighting: "", blend: 0, lightning: app.fx.lightning, time: f.time) }
            if let fi = ms.fighter { addFighter(&f, fighter: fi, key: "menu", app: app, telegraph: .none, telegraphI: 0, cloth: app.settings.cloth) }
        }
        f.skyVersion = skyVersion
        if let a = built { addArena(&f, a) }
        f.lights = app.fx.lightList(arena: built, world: app.world)
        f.particleSpawns = app.fx.takeSpawns()
        f.decals = app.fx.decalList()
        for ai in app.fx.afterimages {
            let a = ai.life / ai.maxLife
            let idx = f.skinPalettes.count
            f.skinPalettes.append(ai.palette)
            f.prevSkinPalettes.append(ai.palette)
            let inst = InstanceGPU(model: ai.model, prevModel: ai.model, tint: Vec4(ai.color, a * 0.6), params: Vec4(0, 1, 0, 0))
            f.draws.append(DrawCall(mesh: ai.mesh, materials: ai.materials, instances: [inst], skin: idx, castShadow: false, layer: .ghost))
        }
        // Post.
        var post = PostParams()
        if let a = arenaDef {
            let g = a.grading
            post.exposure = g.exposure
            post.contrast = g.contrast
            post.saturation = g.saturation
            post.tint = parseColor(g.tint)
            post.shadows = parseColor(g.shadows)
            post.highlights = parseColor(g.highlights)
            post.splitStrength = g.splitStrength
            post.vignette = f.settings.vignette ? g.vignette : 0
            post.bloomStrength = f.settings.bloom ? g.bloom : 0
            if let w = app.world, let sh = a.shifts[w.lighting], !sh.tint.isEmpty {
                post.tint = vlerp(post.tint, parseColor(sh.tint), w.lightingBlend)
            }
        }
        post.grain = f.settings.filmGrain ? 0.035 : 0
        post.chromatic = f.settings.chromaticAberration ? min(1, app.fx.chromatic) : 0
        post.flash = app.settings.flashing ? app.fx.flash : app.fx.flash * Vec4(1, 1, 1, 0.3)
        post.motionBlur = f.settings.motionBlur ? 0.6 : 0
        if let w = app.world {
            let vp = f.proj * f.view
            let c = vp.transformPointProjective(app.fx.radialWorld)
            if c.w > 0.05 { post.radialCenter = Vec2(c.x / c.w * 0.5 + 0.5, 1 - (c.y / c.w * 0.5 + 0.5)) }
            post.radialBlur = f.settings.flashing ? app.fx.radial : app.fx.radial * 0.3
            post.lowHealth = saturatef(1 - w.player.fighter.healthFraction / 0.35)
            let ts = w.timeScale
            post.slowmo = ts < 0.9 && !app.radialOpen ? Float(1 - ts) : 0
            if w.camera.mode == .cinematic && f.settings.dof {
                post.dofStrength = 1
                post.dofFocus = vlength(w.camera.cineFocus - w.camera.eye)
                post.dofRange = 1.2
                post.letterbox = 1
            }
            if w.fightPhase == .intro { post.letterbox = 1 }
            if w.fightPhase == .defeat { post.desaturate = min(1, Float(w.phaseTime)) * 0.8 }
        } else {
            post.dofStrength = f.settings.dof ? 0.6 : 0
            post.dofFocus = vlength(app.menuScene.cameraTarget - app.menuScene.cameraPos)
            post.dofRange = 1.5
        }
        f.post = post
        // UI.
        var ub = UIBuilder()
        let (ui, hits) = ub.build(app: app, viewProj: f.proj * f.view, width: width, height: height)
        f.ui = ui
        app.hitRects = hits
        cameraCut = false
        return f
    }

    mutating func addArena(_ f: inout RenderFrame, _ a: BuiltArena) {
        for set in a.sets {
            // params.w = 1000 flags the arena floor (procedural floor patterns + SSR mask in Mesh.metal).
            let flag: Float = set.name == "floor" ? 1000 : 0
            let inst = set.transforms.map { m in
                InstanceGPU(model: m, prevModel: m, params: Vec4(0, 0, 0, flag))
            }
            f.draws.append(DrawCall(mesh: set.mesh, materials: set.materials, instances: inst, castShadow: set.castShadow, doubleSided: set.name == "backdrop"))
        }
    }

    mutating func addWorld(_ f: inout RenderFrame, app: GameApp, world w: World) {
        let pf = w.player.fighter
        let invisible = pf.visibility < 0.99
        addFighter(&f, fighter: pf, key: "p", app: app, telegraph: .none, telegraphI: 0, cloth: app.settings.cloth, alpha: invisible ? max(0.25, pf.visibility) : 1)
        for b in w.bosses {
            addFighter(&f, fighter: b.fighter, key: "b\(b.fighter.id)", app: app, telegraph: b.telegraph, telegraphI: b.telegraphIntensity, cloth: app.settings.cloth)
        }
        // Weapon trails.
        let playerTrail = app.save.equippedTrail[w.player.weapon.id].flatMap { id in Cosmetics.trails.first { $0.id == id && id != "default" } }
        var styles: [ObjectIdentifier: TrailBuilder.Style] = [:]
        func style(for weapon: WeaponInstance, player: Bool) -> TrailBuilder.Style {
            if player {
                if let t = playerTrail { return TrailBuilder.Style(head: t.head, tail: t.tail, intensity: t.intensity) }
                let cs = w.player.weapon.trail.map { parseColor($0) }
                return TrailBuilder.Style(head: cs.first ?? Vec3(1, 1, 1), tail: cs.last ?? Vec3(0.4, 0.6, 1), intensity: 3.2)
            }
            if weapon.visual.element != .none {
                let c = FXSystem.elementColor(weapon.visual.element)
                return TrailBuilder.Style(head: vlerp(c, Vec3(1, 1, 1), 0.5), tail: c, intensity: 3.5)
            }
            if weapon.glow > 0.05 {
                let c = parseColor(weapon.visual.glow)
                return TrailBuilder.Style(head: vlerp(c, Vec3(1, 1, 1), 0.5), tail: c, intensity: 3)
            }
            return TrailBuilder.Style(head: Vec3(0.95, 0.95, 1), tail: Vec3(0.5, 0.55, 0.7), intensity: 1.6)
        }
        styles[ObjectIdentifier(pf.weapon)] = style(for: pf.weapon, player: true)
        if let o = pf.offhand { styles[ObjectIdentifier(o)] = style(for: o, player: true) }
        for b in w.bosses {
            styles[ObjectIdentifier(b.fighter.weapon)] = style(for: b.fighter.weapon, player: false)
            if let o = b.fighter.offhand { styles[ObjectIdentifier(o)] = style(for: o, player: false) }
        }
        w.trails.build(time: w.now, styleFor: { styles[$0] }, vertices: &f.trailVertices, indices: &f.trailIndices)

        // Debug hitboxes.
        if app.debug.hitboxes {
            for fi in [pf] + w.bosses.map({ $0.fighter }) {
                for (_, c) in fi.hurtboxes() { capsuleLines(&f.debugLines, c, Vec4(0.2, 1, 0.3, 0.9)) }
                if let mv = fi.move, let st = mv.strike {
                    let active = mv.isActive
                    let col = active ? Vec4(1, 0.15, 0.1, 1) : Vec4(1, 0.8, 0.2, 0.5)
                    for wpn in [fi.weapon] + (fi.offhand.map { [$0] } ?? []) {
                        for c in wpn.capsules(at: wpn.frame, reach: mv.reach * st.reach) { capsuleLines(&f.debugLines, c, col) }
                    }
                    if st.aoeRadius > 0 { sphereLines(&f.debugLines, fi.weapon.trailTipWorld, st.aoeRadius, Vec4(1, 0.4, 1, 0.8)) }
                    if st.hitbox == .body || st.hitbox == .weaponAndBody { capsuleLines(&f.debugLines, fi.bodyCapsule(inflate: 0.15), col) }
                }
            }
            for h in w.hazards { sphereLines(&f.debugLines, h.center, h.radius, Vec4(1, 0.5, 0, 0.8)) }
        }
    }

    mutating func addFighter(_ f: inout RenderFrame, fighter fi: Fighter, key: String, app: GameApp, telegraph: Telegraph, telegraphI: Float, cloth: Bool,
                             alpha: Float = 1) {
        let palette = fi.animator.skinPalette()
        let prevPal = cameraCut ? palette : (prevPalettes[fi.id] ?? palette)
        prevPalettes[fi.id] = palette
        let idx = f.skinPalettes.count
        f.skinPalettes.append(palette)
        f.prevSkinPalettes.append(prevPal)
        let model = fi.animator.worldMatrix
        let telKind: Float
        switch telegraph {
        case .none: telKind = 0
        case .white: telKind = 1
        case .red: telKind = 2
        case .purple: telKind = 3
        case .gold: telKind = 4
        }
        var mats = fi.materials
        if fi.glow > 0 && mats.count > 7 { mats[7].emissiveStrength = max(mats[7].emissiveStrength, 4 + fi.glow * 8) }
        if fi.glow > 0 && mats.count > 3 && mats[3].runes > 0 { mats[3].emissiveStrength *= (1 + fi.glow) }
        let inst = InstanceGPU(model: model, prevModel: prev("\(key)body", model), tint: Vec4(1, 1, 1, alpha),
                               params: Vec4(fi.hitFlash, 0, telegraphI, 0), flash: Vec4(fi.flashColor, telKind))
        f.draws.append(DrawCall(mesh: fi.mesh, materials: mats, instances: [inst], skin: idx, castShadow: true, layer: alpha < 0.99 ? .ghost : .opaque))
        // Weapons.
        func addWeapon(_ w: WeaponInstance, _ wk: String) {
            let m = w.frame.matrix
            var wm = w.materials
            if w.glow > 0 {
                let g = parseColor(w.visual.glow)
                wm[3] = MaterialDesc.emissive(g, strength: 3 + w.glow * 6)
                if w.visual.element != .none { wm[7].emissiveStrength = max(wm[7].emissiveStrength, 2 + w.glow * 4) }
            }
            let wi = InstanceGPU(model: m, prevModel: prev("\(key)\(wk)", m), tint: Vec4(1, 1, 1, alpha), params: Vec4(fi.hitFlash * 0.5, 0, telegraphI, 0),
                                 flash: Vec4(fi.flashColor, telKind))
            f.draws.append(DrawCall(mesh: w.mesh, materials: wm, instances: [wi], castShadow: true, layer: alpha < 0.99 ? .ghost : .opaque))
            // Flexible: chain links + head.
            if let ch = w.chain, let link = w.linkMesh, let head = w.flexHead {
                var links: [InstanceGPU] = []
                let pts = ch.points
                for i in 0..<(pts.count - 1) {
                    let a = pts[i], b = pts[i + 1]
                    let d = b - a
                    let len = vlength(d)
                    if len < 1e-4 { continue }
                    let rot = Quat.fromTo(Vec3(0, 0, 1), d / len) * Quat(axis: Vec3(0, 0, 1), angle: Float(i % 2) * kPi / 2)
                    let baseLen: Float = w.visual.type == "meteor_hammer" ? 0.12 : 0.045
                    let lm = Mat4.trs((a + b) * 0.5, rot, Vec3(1, 1, max(0.3, len / baseLen)))
                    links.append(InstanceGPU(model: lm, prevModel: lm, tint: Vec4(1, 1, 1, alpha)))
                }
                if !links.isEmpty { f.draws.append(DrawCall(mesh: link, materials: wm, instances: links, castShadow: true)) }
                let n = pts.count
                let dir = vnormalize(pts[n - 1] - pts[max(0, n - 2)], fallback: Vec3(0, -1, 0))
                let hm = Mat4.trs(pts[n - 1], Quat.fromTo(Vec3(0, 0, 1), dir))
                f.draws.append(DrawCall(mesh: head, materials: wm, instances: [InstanceGPU(model: hm, prevModel: prev("\(key)\(wk)h", hm),
                                                                                           tint: Vec4(1, 1, 1, alpha), params: Vec4(0, 0, telegraphI, 0),
                                                                                           flash: Vec4(fi.flashColor, telKind))], castShadow: true))
            }
        }
        addWeapon(fi.weapon, "wR")
        if let o = fi.offhand { addWeapon(o, "wL") }
        // Cloth.
        if cloth, let c = fi.cape {
            let m = c.mesh()
            f.draws.append(DrawCall(mesh: m, materials: [MaterialDesc](repeating: c.material, count: 8),
                                    instances: [InstanceGPU(model: .identity, prevModel: .identity, tint: Vec4(1, 1, 1, alpha))],
                                    castShadow: true, dynamic: true, doubleSided: true))
        }
    }

    func capsuleLines(_ out: inout [DebugLine], _ c: Capsule, _ col: Vec4) {
        let axis = vnormalize(c.b - c.a, fallback: Vec3(0, 1, 0))
        var u = vcross(axis, Vec3(0, 1, 0))
        if vlengthSq(u) < 1e-4 { u = vcross(axis, Vec3(1, 0, 0)) }
        u = vnormalize(u)
        let v = vcross(axis, u)
        let n = 10
        for end in [c.a, c.b] {
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * kTwoPi, a1 = Float(i + 1) / Float(n) * kTwoPi
                out.append(DebugLine(end + (u * cos(a0) + v * sin(a0)) * c.radius, end + (u * cos(a1) + v * sin(a1)) * c.radius, col))
            }
        }
        for k in 0..<4 {
            let a = Float(k) / 4 * kTwoPi
            let o = (u * cos(a) + v * sin(a)) * c.radius
            out.append(DebugLine(c.a + o, c.b + o, col))
        }
    }

    func sphereLines(_ out: inout [DebugLine], _ c: Vec3, _ r: Float, _ col: Vec4) {
        let n = 16
        for i in 0..<n {
            let a0 = Float(i) / Float(n) * kTwoPi, a1 = Float(i + 1) / Float(n) * kTwoPi
            out.append(DebugLine(c + Vec3(cos(a0), 0, sin(a0)) * r, c + Vec3(cos(a1), 0, sin(a1)) * r, col))
            out.append(DebugLine(c + Vec3(cos(a0), sin(a0), 0) * r, c + Vec3(cos(a1), sin(a1), 0) * r, col))
        }
    }
}
