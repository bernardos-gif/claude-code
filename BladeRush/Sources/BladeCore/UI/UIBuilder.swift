// Lays out menus, the fight HUD and debug overlays into a UIDrawList.
import Foundation

public struct UIBuilder {
    var d = UIDrawList()
    var hit: [(Vec4, Int)] = []
    var viewProj = Mat4.identity

    public init() {}

    var s: Float { d.s }
    var W: Float { d.width }
    var H: Float { d.height }

    // MARK: Helpers

    func project(_ p: Vec3) -> Vec2? {
        let c = viewProj.transformPointProjective(p)
        guard c.w > 0.05 else { return nil }
        let n = c.xyz / c.w
        guard abs(n.x) < 1.2 && abs(n.y) < 1.2 else { return nil }
        return Vec2((n.x * 0.5 + 0.5) * W, (1 - (n.y * 0.5 + 0.5)) * H)
    }

    mutating func panel(_ x: Float, _ y: Float, _ w: Float, _ h: Float, alpha: Float = 0.78) {
        d.rect(x, y, w, h, Vec4(0.03, 0.028, 0.035, alpha), c2: Vec4(0.015, 0.012, 0.018, alpha), radius: 6 * s, border: 1, borderColor: UIColors.panelBorder)
    }

    mutating func list(_ items: [MenuItem], cursor: Int, x: Float, y: Float, w: Float, row: Float, size: Float, maxRows: Int = 99, showValues: Bool = true) -> Float {
        var yy = y
        let first = max(0, min(cursor - maxRows / 2, items.count - maxRows))
        for (i, it) in items.enumerated() where i >= first && i < first + maxRows {
            let sel = i == cursor
            if sel {
                d.rect(x, yy, w, row, UIColors.selected, c2: Vec4(0.9, 0.3, 0.15, 0.05), radius: 3 * s)
                d.rect(x, yy + row * 0.15, 3 * s, row * 0.7, UIColors.accent, radius: 1.5 * s, glow: 0.6)
            }
            let col = !it.enabled ? Vec4(0.45, 0.43, 0.42, 1) : (sel ? UIColors.text : Vec4(0.78, 0.75, 0.7, 1))
            d.text(it.label, x + 16 * s, yy + row * 0.5 - size * 0.55, size: size, col)
            let v = it.valueText
            if showValues && !v.isEmpty {
                let vc = sel ? UIColors.gold : UIColors.dim
                if case .slider(let g, _, _, let lo, let hi) = it.kind {
                    let bw = 160 * s
                    d.bar(x + w - bw - 90 * s, yy + row * 0.42, bw, 5 * s, fill: (g() - lo) / max(hi - lo, 1e-4), color: UIColors.gold)
                }
                d.text(v, x + w - 14 * s, yy + row * 0.5 - size * 0.5, size: size * 0.9, vc, align: .right)
            }
            hit.append((Vec4(x, yy, w, row), i))
            yy += row
        }
        return yy
    }

    mutating func title(_ t: String, _ x: Float, _ y: Float, size: Float, align: UIAlign = .left, color: Vec4 = UIColors.text) {
        d.text(t, x, y, size: size, color, font: .title, align: align, tracking: size * 0.08)
    }

    mutating func footer(_ app: GameApp, _ hint: String) {
        d.text(hint, W / 2, H - 40 * s, size: 16 * s, UIColors.dim, align: .center)
        _ = app
    }

    // MARK: Build

    public mutating func build(app: GameApp, viewProj vp: Mat4, width: Float, height: Float) -> (UIDrawList, [(Vec4, Int)]) {
        d = UIDrawList()
        d.width = width
        d.height = height
        hit = []
        viewProj = vp
        let (key, items) = MenuBuilder.items(for: app)
        let cursor = min(app.menuCursor[key] ?? 0, max(0, items.count - 1))
        switch app.screen {
        case .title: titleScreen(app)
        case .main: mainMenu(app, items, cursor)
        case .campaign: listScreen(app, "CAMPAIGN RUSH", "Choose a tier. Each tier is a rush of bosses fought back to back.", items, cursor)
        case .bossSelect: listScreen(app, "BOSS SELECT", "Replay any defeated boss.", items, cursor, rows: 14)
        case .prep: prep(app, items, cursor)
        case .loading: loading(app)
        case .fight:
            if let w = app.world { hud(app, w) }
            if app.paused { pauseMenu(app, items, cursor) }
        case .victory:
            if let w = app.world { hud(app, w) }
            victory(app, items, cursor)
        case .death:
            if let w = app.world { hud(app, w) }
            death(app, items, cursor)
        case .endlessOver: endlessOver(app, items, cursor)
        case .armory: listScreen(app, "ARMORY", "Skins and trails are earned through achievements.", items, cursor, rows: 12)
        case .stats: stats(app, items, cursor)
        case .settings: settingsScreen(app, items, cursor)
        case .credits: credits(app, items, cursor)
        }
        overlays(app)
        return (d, hit)
    }

    // MARK: Screens

    mutating func titleScreen(_ app: GameApp) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.35), c2: Vec4(0, 0, 0, 0.75))
        let pulse = 0.55 + 0.45 * Float(sin(app.time * 2.2))
        title("BLADE RUSH", W / 2, H * 0.34, size: 150 * s, align: .center)
        d.rect(W / 2 - 260 * s, H * 0.34 + 170 * s, 520 * s, 2 * s, Vec4(0.9, 0.25, 0.15, 0.9), glow: 1)
        d.text("FIFTY BLADES  ·  ONE DUELIST", W / 2, H * 0.34 + 190 * s, size: 22 * s, UIColors.dim, align: .center, tracking: 6 * s)
        d.text("Press any key", W / 2, H * 0.78, size: 24 * s, UIColors.text * Vec4(1, 1, 1, pulse), align: .center)
    }

    mutating func mainMenu(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        d.rect(0, 0, W * 0.5, H, Vec4(0, 0, 0, 0.72), c2: Vec4(0, 0, 0, 0.5))
        title("BLADE RUSH", 90 * s, 90 * s, size: 84 * s)
        d.rect(90 * s, 190 * s, 300 * s, 2 * s, UIColors.accent, glow: 0.8)
        _ = list(items, cursor: cursor, x: 80 * s, y: 250 * s, w: 520 * s, row: 52 * s, size: 26 * s)
        if cursor < items.count { d.text(items[cursor].detail, 96 * s, H - 150 * s, size: 18 * s, UIColors.dim) }
        let sv = app.save
        let beaten = sv.defeated.count
        d.text("Bosses defeated: \(beaten)/\(app.data.encounters.count)   ·   Tier \(min(sv.unlockedTier, 12)) unlocked", 96 * s, H - 110 * s, size: 17 * s, UIColors.dim)
        footer(app, "↑↓ select   ·   Enter confirm   ·   Esc back   ·   F1 debug overlay")
    }

    mutating func listScreen(_ app: GameApp, _ t: String, _ sub: String, _ items: [MenuItem], _ cursor: Int, rows: Int = 12) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.55))
        title(t, 90 * s, 70 * s, size: 64 * s)
        d.text(sub, 94 * s, 150 * s, size: 19 * s, UIColors.dim)
        panel(80 * s, 200 * s, 900 * s, Float(rows) * 50 * s + 20 * s)
        _ = list(items, cursor: cursor, x: 90 * s, y: 210 * s, w: 880 * s, row: 50 * s, size: 24 * s, maxRows: rows)
        if cursor < items.count {
            panel(1020 * s, 200 * s, W - 1100 * s, 260 * s)
            d.text(items[cursor].label, 1045 * s, 225 * s, size: 30 * s, UIColors.text, font: .title)
            wrap(items[cursor].detail, x: 1045 * s, y: 280 * s, width: W - 1150 * s, size: 19 * s, color: UIColors.dim)
        }
        footer(app, "↑↓ select   ·   ←→ change   ·   Enter confirm   ·   Esc back")
    }

    mutating func wrap(_ text: String, x: Float, y: Float, width: Float, size: Float, color: Vec4, lineHeight: Float = 1.35) {
        var line = ""
        var yy = y
        for word in text.split(separator: " ") {
            let cand = line.isEmpty ? String(word) : line + " " + word
            if d.measure(cand, size: size) > width && !line.isEmpty {
                d.text(line, x, yy, size: size, color)
                yy += size * lineHeight
                line = String(word)
            } else { line = cand }
        }
        if !line.isEmpty { d.text(line, x, yy, size: size, color) }
    }

    mutating func prep(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.5))
        guard let sess = app.session, let id = sess.current, let enc = app.data.encounters[id] else { return }
        // Mode banner.
        var mode = ""
        switch sess.mode {
        case .campaign(let t): mode = "CAMPAIGN · \(app.data.tiers.first { $0.index == t }?.name ?? "") · \(sess.index + 1)/\(sess.queue.count)"
        case .single: mode = "BOSS SELECT"
        case .endless: mode = "ENDLESS GAUNTLET · Boss \(sess.cleared + 1) · Score \(sess.score)"
        }
        if sess.hard { mode += " · HARD MODE" }
        d.text(mode, 90 * s, 60 * s, size: 18 * s, UIColors.gold, tracking: 3 * s)
        title("CHOOSE YOUR BLADE", 90 * s, 90 * s, size: 48 * s)
        panel(80 * s, 170 * s, 620 * s, 420 * s)
        _ = list(items, cursor: cursor, x: 90 * s, y: 180 * s, w: 600 * s, row: 58 * s, size: 26 * s, showValues: false)
        let wsel = app.weapons[safe: min(cursor, app.weapons.count - 1)] ?? app.weapons[0]
        panel(80 * s, 610 * s, 620 * s, 330 * s)
        d.text(wsel.name, 105 * s, 630 * s, size: 30 * s, UIColors.text, font: .title)
        wrap(wsel.description, x: 105 * s, y: 675 * s, width: 570 * s, size: 17 * s, color: UIColors.dim)
        let st = wsel.stats
        let rows: [(String, Float)] = [("Damage", st.damage / 1.6), ("Posture", st.posture / 1.7), ("Speed", st.speed / 1.3),
                                       ("Reach", WeaponCatalog.effectiveReach(wsel.visual) / 2.2), ("Stamina cost", st.staminaLight / 14)]
        var yy = 720 * s
        for (n, v) in rows {
            d.text(n, 105 * s, yy, size: 17 * s, UIColors.dim)
            d.bar(260 * s, yy + 6 * s, 400 * s, 8 * s, fill: v, color: UIColors.gold)
            yy += 30 * s
        }
        d.text("Ability: \(wsel.ability.name)   ·   Perfect parry: \(bonusText(wsel.perfectParryBonus))   ·   Perfect dodge: \(bonusText(wsel.perfectDodgeBonus))",
               105 * s, yy + 8 * s, size: 15 * s, UIColors.text)
        // Boss card.
        let bx = 760 * s
        panel(bx, 170 * s, W - bx - 80 * s, 770 * s)
        let tierName = app.data.tiers.first { $0.encounters.contains(id) }?.name ?? ""
        d.text(tierName.uppercased(), bx + 30 * s, 195 * s, size: 17 * s, UIColors.gold, tracking: 4 * s)
        title(enc.name, bx + 30 * s, 225 * s, size: 50 * s)
        d.text(enc.title, bx + 32 * s, 290 * s, size: 24 * s, UIColors.accent)
        var by = 345 * s
        for bid in enc.bosses {
            guard let b = app.data.bosses[bid] else { continue }
            if enc.bosses.count > 1 {
                d.text("\(b.name) — \(b.title)", bx + 30 * s, by, size: 21 * s, UIColors.text)
                by += 32 * s
            }
            wrap("\u{201C}\(b.lore)\u{201D}", x: bx + 30 * s, y: by, width: W - bx - 150 * s, size: 19 * s, color: Vec4(0.85, 0.82, 0.76, 1))
            by += 90 * s
            d.text("Weapon: \(WeaponCatalog.get(b.weapons.first?.type ?? "").name)" + (b.weapons.count > 1 ? " + \(b.weapons.count - 1) more" : "")
                   + "   ·   Phases: \(b.phases.count)   ·   Signature: \(b.signature)", bx + 30 * s, by, size: 17 * s, UIColors.dim)
            by += 32 * s
            if app.save.isDefeated(id) || app.debug.allBosses {
                for wk in b.weaknesses.prefix(3) {
                    d.text("•  \(wk)", bx + 40 * s, by, size: 16 * s, Vec4(0.7, 0.85, 0.7, 1))
                    by += 26 * s
                }
            } else {
                d.text("Weaknesses revealed after the first victory.", bx + 40 * s, by, size: 16 * s, UIColors.dim)
                by += 26 * s
            }
            by += 14 * s
        }
        let deaths = app.save.deaths[id] ?? 0
        d.text("Deaths here: \(deaths)" + (app.save.bestTimes[id].map { String(format: "   ·   Best time %d:%02d", Int($0) / 60, Int($0) % 60) } ?? ""),
               bx + 30 * s, 900 * s, size: 17 * s, UIColors.dim)
        footer(app, "↑↓ choose weapon   ·   Enter begin   ·   Esc back")
    }

    func bonusText(_ b: String) -> String {
        switch b {
        case "doublePosture": return "double posture damage"
        case "counterSlash": return "free counter-slash"
        case "stagger": return "staggers the boss"
        case "instantCharge": return "instant charged heavy"
        case "riposte": return "riposte flurry"
        case "invisibility": return "afterimage decoy"
        case "pushback": return "push back + thrust"
        case "autoLunge": return "auto-lunge"
        case "disarm": return "disarm"
        case "chainLash": return "chain lash"
        default: return b
        }
    }

    mutating func loading(_ app: GameApp) {
        d.rect(0, 0, W, H, Vec4(0.01, 0.01, 0.012, 1))
        let name = app.session?.current.flatMap { app.data.encounters[$0]?.name } ?? ""
        title(name, W / 2, H * 0.42, size: 56 * s, align: .center)
        d.text("Forging the arena…", W / 2, H * 0.42 + 80 * s, size: 20 * s, UIColors.dim, align: .center)
    }

    mutating func pauseMenu(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.6))
        title("PAUSED", W / 2, H * 0.28, size: 60 * s, align: .center)
        panel(W / 2 - 220 * s, H * 0.38, 440 * s, Float(items.count) * 54 * s + 20 * s)
        _ = list(items, cursor: cursor, x: W / 2 - 210 * s, y: H * 0.38 + 10 * s, w: 420 * s, row: 54 * s, size: 26 * s)
    }

    mutating func victory(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        let a = min(1, Float(app.screenTime) * 2)
        d.rect(0, H * 0.3, W, H * 0.4, Vec4(0, 0, 0, 0.7 * a))
        title("VICTORY", W / 2, H * 0.33, size: 90 * s, align: .center, color: UIColors.gold * Vec4(1, 1, 1, a))
        guard let sess = app.session else { return }
        let st = sess.lastFightStats
        let line = String(format: "Time %d:%02d   ·   Perfect parries %d/%d   ·   Perfect dodges %d   ·   Hits taken %d",
                          Int(st.time) / 60, Int(st.time) % 60, st.perfectParries, st.parries, st.perfectDodges, st.hitsTaken)
        d.text(line, W / 2, H * 0.33 + 110 * s, size: 20 * s, UIColors.text, align: .center)
        var yy = H * 0.33 + 150 * s
        for u in sess.unlocks {
            d.text(u, W / 2, yy, size: 20 * s, UIColors.gold, align: .center)
            yy += 30 * s
        }
        _ = list(items, cursor: cursor, x: W / 2 - 200 * s, y: H * 0.72, w: 400 * s, row: 50 * s, size: 24 * s)
    }

    mutating func death(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        let a = min(1, Float(app.screenTime) * 1.5)
        d.rect(0, 0, W, H, Vec4(0.08, 0, 0, 0.55 * a))
        title("DEFEATED", W / 2, H * 0.34, size: 110 * s, align: .center, color: Vec4(0.75, 0.08, 0.06, a))
        if let w = app.world, let b = w.bosses.first {
            d.text(String(format: "%@ remained at %.0f%% health", b.def.name, b.fighter.healthFraction * 100), W / 2, H * 0.34 + 130 * s,
                   size: 20 * s, UIColors.dim * Vec4(1, 1, 1, a), align: .center)
        }
        _ = list(items, cursor: cursor, x: W / 2 - 200 * s, y: H * 0.6, w: 400 * s, row: 52 * s, size: 26 * s)
        footer(app, "Enter: instant retry")
    }

    mutating func endlessOver(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.7))
        title("THE GAUNTLET ENDS", W / 2, H * 0.3, size: 70 * s, align: .center)
        let sc = app.session?.score ?? 0
        d.text("Score \(sc)   ·   Bosses defeated \(app.session?.cleared ?? 0)   ·   Best \(app.save.endlessBest)", W / 2, H * 0.3 + 100 * s,
               size: 24 * s, UIColors.gold, align: .center)
        _ = list(items, cursor: cursor, x: W / 2 - 200 * s, y: H * 0.55, w: 400 * s, row: 52 * s, size: 26 * s)
    }

    mutating func stats(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.65))
        title("STATISTICS", 90 * s, 70 * s, size: 64 * s)
        let st = app.save.stats
        let lines = [
            "Bosses defeated: \(st.bossesDefeated)", "Deaths: \(st.deaths)", "Parries: \(st.parries)  (perfect \(st.perfectParries))",
            "Dodges: \(st.dodges)  (perfect \(st.perfectDodges))", "Deathblows: \(st.deathblows)", "Hits taken: \(st.hitsTaken)",
            String(format: "Damage dealt: %.0f", st.damageDealt), String(format: "Time in combat: %.0f min", st.playTime / 60),
            "Endless best: \(app.save.endlessBest) (\(app.save.endlessBestBosses) bosses)",
            "Achievements: \(app.save.achievements.count)",
        ]
        panel(80 * s, 180 * s, 560 * s, 470 * s)
        var yy = 200 * s
        for l in lines { d.text(l, 105 * s, yy, size: 21 * s, UIColors.text); yy += 42 * s }
        panel(680 * s, 180 * s, W - 760 * s, H - 300 * s)
        d.text("BOSS", 705 * s, 195 * s, size: 16 * s, UIColors.gold)
        d.text("DEATHS", W - 460 * s, 195 * s, size: 16 * s, UIColors.gold)
        d.text("BEST TIME", W - 300 * s, 195 * s, size: 16 * s, UIColors.gold)
        var y2 = 225 * s
        let ids = app.data.encounterOrder.filter { app.save.attempts[$0] != nil || app.save.isDefeated($0) }
        for id in ids.prefix(Int((H - 360 * s) / (28 * s))) {
            let n = app.data.encounters[id]?.name ?? id
            d.text(n, 705 * s, y2, size: 18 * s, app.save.isDefeated(id) ? UIColors.text : UIColors.dim)
            d.text("\(app.save.deaths[id] ?? 0)", W - 460 * s, y2, size: 18 * s, UIColors.text)
            d.text(app.save.bestTimes[id].map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "—", W - 300 * s, y2, size: 18 * s, UIColors.text)
            y2 += 28 * s
        }
        if ids.isEmpty { d.text("No fights yet.", 705 * s, y2, size: 18 * s, UIColors.dim) }
        _ = list(items, cursor: cursor, x: 90 * s, y: 680 * s, w: 300 * s, row: 50 * s, size: 24 * s)
    }

    mutating func settingsScreen(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, app.world != nil ? 0.75 : 0.6))
        title("SETTINGS", 90 * s, 60 * s, size: 60 * s)
        panel(80 * s, 150 * s, 1100 * s, H - 230 * s)
        let rows = Int((H - 260 * s) / (44 * s))
        _ = list(items, cursor: cursor, x: 90 * s, y: 160 * s, w: 1080 * s, row: 44 * s, size: 21 * s, maxRows: rows)
        if cursor < items.count, !items[cursor].detail.isEmpty {
            panel(1220 * s, 150 * s, W - 1300 * s, 200 * s)
            wrap(items[cursor].detail, x: 1240 * s, y: 170 * s, width: W - 1350 * s, size: 18 * s, color: UIColors.dim)
        }
        if let cap = app.capturing {
            d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.7))
            d.text("Press a key, mouse button or gamepad button for", W / 2, H * 0.42, size: 24 * s, UIColors.text, align: .center)
            d.text(cap.displayName, W / 2, H * 0.42 + 44 * s, size: 34 * s, UIColors.gold, font: .title, align: .center)
            d.text("Esc to cancel", W / 2, H * 0.42 + 100 * s, size: 18 * s, UIColors.dim, align: .center)
        }
        footer(app, "↑↓ select   ·   ←→ adjust   ·   Enter toggle / rebind   ·   Esc back")
    }

    mutating func credits(_ app: GameApp, _ items: [MenuItem], _ cursor: Int) {
        d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.8))
        title("THE RUSH IS YOURS", W / 2, H * 0.25, size: 72 * s, align: .center, color: UIColors.gold)
        let lines = ["The Blade Sovereign has fallen.", "Every blade you carried, you carried first.", "",
                     "Hard Mode is now unlocked from the main menu.", "", "BLADE RUSH — everything you saw and heard was generated in code."]
        var yy = H * 0.25 + 120 * s
        for l in lines { d.text(l, W / 2, yy, size: 22 * s, UIColors.text, align: .center); yy += 36 * s }
        _ = list(items, cursor: cursor, x: W / 2 - 220 * s, y: H * 0.75, w: 440 * s, row: 52 * s, size: 24 * s)
    }

    // MARK: HUD

    mutating func hud(_ app: GameApp, _ w: World) {
        let p = w.player
        let pf = p.fighter
        let cb = app.settings.colorblind
        let fade: Float = w.fightPhase == .intro ? saturatef(Float(w.phaseTime) - 1.5) : 1
        // Boss intro title card.
        if w.fightPhase == .intro, let b = w.bosses.first {
            let a = saturatef(Float(w.phaseTime) * 1.5) * saturatef(Float(2.8 - w.phaseTime) * 2)
            d.rect(0, H * 0.66, W, 150 * s, Vec4(0, 0, 0, 0.55 * a))
            title(w.bosses.count > 1 ? w.encounter.name : b.def.name, W / 2, H * 0.66 + 18 * s, size: 64 * s, align: .center, color: UIColors.text * Vec4(1, 1, 1, a))
            d.text(w.bosses.count > 1 ? w.encounter.title : b.def.title, W / 2, H * 0.66 + 100 * s, size: 24 * s, UIColors.accent * Vec4(1, 1, 1, a), align: .center, tracking: 4 * s)
        }
        // Boss bars (top center).
        let alive = w.bosses
        for (i, b) in alive.enumerated() where !(b.fighter.dead && w.fightPhase == .victory && w.phaseTime > 2) {
            let bw: Float = (alive.count > 1 ? 560 : 900) * s
            let bx = alive.count > 1 ? (i == 0 ? W / 2 - bw - 20 * s : W / 2 + 20 * s) : (W - bw) / 2
            let by: Float = 54 * s
            d.text(b.def.name.uppercased(), bx, by - 32 * s, size: 22 * s, UIColors.text * Vec4(1, 1, 1, fade), font: .title, tracking: 3 * s)
            d.text(b.def.title, bx + bw, by - 28 * s, size: 16 * s, UIColors.dim * Vec4(1, 1, 1, fade), align: .right)
            d.bar(bx, by, bw, 11 * s, fill: b.fighter.healthFraction, color: UIColors.health * Vec4(1, 1, 1, fade), radius: 2 * s)
            // Phase pips.
            for k in 1..<max(1, b.def.phases.count) {
                let px = bx + bw * b.def.phases[k].threshold
                d.rect(px - 1 * s, by - 2 * s, 2 * s, 15 * s, Vec4(1, 0.9, 0.7, 0.7 * fade))
            }
            let post = b.fighter.posture.fraction
            if post > 0.01 || b.state == .staggered {
                let pc = b.state == .staggered ? Vec4(1, 0.2, 0.1, 1) : mixColor(UIColors.posture, Vec4(1, 0.25, 0.1, 1), post)
                d.bar(bx + bw * 0.25, by + 20 * s, bw * 0.5, 6 * s, fill: b.state == .staggered ? 1 : post, color: pc, centered: true, radius: 1.5 * s)
            }
            // Deathblow prompt.
            if b.canBeDeathblowed, let sp = project(b.fighter.center + Vec3(0, 0.3, 0)) {
                let pulse = 0.7 + 0.3 * Float(sin(app.time * 10))
                d.diamond(sp.x, sp.y, 20 * s * pulse, Vec4(0.9, 0.05, 0.05, 0.9), border: 2 * s, borderColor: Vec4(1, 0.8, 0.6, 1), glow: 1)
                d.text("DEATHBLOW  [\(KeyNames.prompt(.light, settings: app.settings, gamepad: app.lastInput.gamepad))]", sp.x, sp.y + 30 * s,
                       size: 18 * s, UIColors.text, align: .center)
            }
            // Telegraph shapes for colorblind mode.
            if cb && b.telegraphIntensity > 0.2, let sp = project(b.fighter.headPosition + Vec3(0, 0.5, 0)) {
                telegraphIcon(b.telegraph, at: sp, size: 22 * s, alpha: b.telegraphIntensity)
            }
        }
        // Lock-on reticle.
        if let lt = p.lockTarget, !lt.dead, let sp = project(lt.center) {
            d.diamond(sp.x, sp.y, 6 * s, Vec4(1, 1, 1, 0.85), border: 1.5 * s, borderColor: Vec4(0, 0, 0, 0.6))
        }
        // Player bars (bottom left).
        let x0: Float = 60 * s, y0 = H - 150 * s
        let hpW: Float = 420 * s * (pf.maxHealth / 100)
        d.bar(x0, y0, hpW, 12 * s, fill: pf.healthFraction, color: UIColors.health * Vec4(1, 1, 1, fade))
        d.bar(x0, y0 + 20 * s, 300 * s, 6 * s, fill: p.stamina.fraction, color: UIColors.stamina * Vec4(1, 1, 1, fade))
        let ab = p.abilityMeter / max(1, w.tuning.player.abilityMax)
        let ready = p.abilityReady
        let wcol = p.weapon.trail.last.map { Vec4(parseColor($0) * 1.4, 1) } ?? UIColors.gold
        d.bar(x0, y0 + 34 * s, 300 * s, 6 * s, fill: ab, color: ready ? wcol : wcol * Vec4(0.6, 0.6, 0.6, 1))
        if ready { d.text("ABILITY READY [\(KeyNames.prompt(.ability, settings: app.settings, gamepad: app.lastInput.gamepad))]", x0 + 310 * s, y0 + 27 * s, size: 14 * s, wcol) }
        // Flasks.
        for k in 0..<p.maxFlasks {
            let full = k < p.flasks
            d.rect(x0 + Float(k) * 26 * s, y0 + 52 * s, 18 * s, 26 * s, full ? Vec4(0.95, 0.7, 0.25, 0.95) : Vec4(0.2, 0.18, 0.15, 0.6),
                   radius: 6 * s, border: 1.5 * s, borderColor: Vec4(1, 0.9, 0.7, 0.4), glow: full ? 0.5 : 0)
        }
        // Weapon.
        d.text(p.weapon.name.uppercased(), x0 + 100 * s, y0 + 56 * s, size: 20 * s, UIColors.text, font: .title, tracking: 2 * s)
        d.text("\(p.weapon.ability.name)", x0 + 100 * s, y0 + 82 * s, size: 14 * s, UIColors.dim)
        // Player posture (bottom center).
        if pf.posture.fraction > 0.01 {
            let pc = mixColor(UIColors.posture, Vec4(1, 0.15, 0.08, 1), pf.posture.fraction)
            d.bar(W / 2 - 180 * s, H - 70 * s, 360 * s, 7 * s, fill: pf.posture.fraction, color: pc, centered: true)
        }
        // Charge indicator.
        if p.state == .charging {
            let lv = p.chargeLevel
            for k in 0..<max(1, p.weapon.stats.chargeLevels) {
                d.diamond(W / 2 - 30 * s + Float(k) * 30 * s, H * 0.6, 9 * s, k <= lv ? UIColors.gold : Vec4(0.3, 0.3, 0.3, 0.7), glow: k <= lv ? 1 : 0)
            }
        }
        // Popups.
        for pu in app.fx.popups {
            guard let sp = project(pu.position) else { continue }
            let a = saturatef(pu.life / pu.maxLife * 2)
            d.text(pu.text, sp.x, sp.y, size: pu.size * s, pu.color * Vec4(1, 1, 1, a), font: .title, align: .center, tracking: 3 * s)
        }
        // Radial weapon menu.
        if app.radialOpen {
            let cx = W / 2, cy = H / 2
            d.rect(0, 0, W, H, Vec4(0, 0, 0, 0.35))
            let n = max(1, app.weapons.count)
            for (i, wd) in app.weapons.enumerated() {
                let a0 = Float(i) / Float(n) * kTwoPi - kPi / Float(n)
                let sel = i == app.radialSelection
                d.arc(cx, cy, 170 * s, start: a0 + 0.04, end: a0 + kTwoPi / Float(n) - 0.04, thickness: sel ? 64 * s : 52 * s,
                      sel ? Vec4(0.9, 0.3, 0.15, 0.85) : Vec4(0.08, 0.07, 0.08, 0.8), glow: sel ? 0.8 : 0)
                let am = a0 + kPi / Float(n)
                d.text(wd.name, cx + sin(am) * 170 * s, cy - cos(am) * 170 * s - 10 * s, size: 18 * s, sel ? UIColors.text : UIColors.dim, align: .center)
            }
            d.text("Release to swap", cx, cy - 10 * s, size: 16 * s, UIColors.dim, align: .center)
        }
        // Subtitles.
        if app.settings.subtitles {
            var yy = H - 210 * s
            for (who, text, _) in w.subtitles.suffix(2) {
                let full = "\(who): \(text)"
                let tw = d.measure(full, size: 22 * s)
                d.rect(W / 2 - tw / 2 - 16 * s, yy - 6 * s, tw + 32 * s, 36 * s, Vec4(0, 0, 0, 0.55), radius: 4 * s)
                d.text(full, W / 2, yy, size: 22 * s, UIColors.text, align: .center)
                yy -= 44 * s
            }
        }
        // Low health vignette hint and controls reminder in the first seconds.
        if w.fightPhase == .fighting && w.phaseTime < 6 && app.save.stats.bossesDefeated == 0 {
            let g = app.lastInput.gamepad
            let hint = "\(KeyNames.prompt(.light, settings: app.settings, gamepad: g)) attack · \(KeyNames.prompt(.heavy, settings: app.settings, gamepad: g)) heavy · "
                + "\(KeyNames.prompt(.parry, settings: app.settings, gamepad: g)) parry · \(KeyNames.prompt(.dodge, settings: app.settings, gamepad: g)) dodge · "
                + "\(KeyNames.prompt(.lockOn, settings: app.settings, gamepad: g)) lock on · \(KeyNames.prompt(.heal, settings: app.settings, gamepad: g)) heal"
            d.text(hint, W / 2, H - 40 * s, size: 16 * s, UIColors.dim, align: .center)
        }
    }

    mutating func telegraphIcon(_ t: Telegraph, at p: Vec2, size: Float, alpha: Float) {
        let c = UIColors.telegraph(t) * Vec4(1, 1, 1, alpha)
        switch t {
        case .white, .none: d.arc(p.x, p.y, size * 0.6, start: 0, end: kTwoPi, thickness: size * 0.25, c, glow: 0.5)
        case .red:
            d.diamond(p.x, p.y, size * 0.7, Vec4(0, 0, 0, 0.6 * alpha), border: 3, borderColor: c)
            d.text("!", p.x, p.y - size * 0.55, size: size * 1.1, c, font: .title, align: .center)
        case .purple: d.text("~", p.x, p.y - size * 0.7, size: size * 1.6, c, font: .title, align: .center)
        case .gold: d.diamond(p.x, p.y, size * 0.6, c, glow: 0.8)
        }
    }

    func mixColor(_ a: Vec4, _ b: Vec4, _ t: Float) -> Vec4 { vlerp4(a, b, saturatef(t)) }

    // MARK: Overlays

    mutating func overlays(_ app: GameApp) {
        if let (t, until) = app.toast, app.time < until {
            let tw = d.measure(t, size: 20 * s)
            d.rect(W / 2 - tw / 2 - 20 * s, 18 * s, tw + 40 * s, 40 * s, Vec4(0, 0, 0, 0.7), radius: 6 * s, border: 1, borderColor: UIColors.panelBorder)
            d.text(t, W / 2, 26 * s, size: 20 * s, UIColors.text, align: .center)
        }
        if app.settings.showFPS || app.debug.overlay {
            let c = app.debug.fps >= 58 ? Vec4(0.6, 1, 0.6, 0.9) : (app.debug.fps >= 40 ? Vec4(1, 0.9, 0.4, 0.9) : Vec4(1, 0.4, 0.3, 0.9))
            d.text(String(format: "%.0f FPS", app.debug.fps), W - 16 * s, 12 * s, size: 16 * s, c, font: .mono, align: .right)
        }
        if app.debug.overlay { debugOverlay(app) }
        if app.debug.frameData, let w = app.world { frameData(app, w) }
        if app.debug.ai, let w = app.world { aiDebug(w) }
    }

    mutating func debugOverlay(_ app: GameApp) {
        let x = W - 470 * s, y: Float = 40 * s
        var lines: [String] = []
        let dbg = app.debug
        lines.append(String(format: "frame %.2f ms (%.0f fps)   GPU %.2f ms", dbg.frameMs, dbg.fps, dbg.gpuTotal))
        for (n, ms) in dbg.gpuPasses { lines.append(String(format: "  gpu %-14@ %6.2f ms", n as NSString, ms)) }
        for (n, ms) in dbg.cpu.sections { lines.append(String(format: "  cpu %-14@ %6.2f ms", n as NSString, ms)) }
        lines.append("draw calls \(dbg.drawCalls)   tris \(dbg.triangles / 1000)k   particles \(dbg.particles)")
        lines.append(String(format: "render %.0fx%.0f   scale %.2f   %@", dbg.renderSize.x, dbg.renderSize.y, app.settings.resolutionScale,
                            app.settings.upscaler as NSString))
        if let w = app.world {
            lines.append(String(format: "sim steps/frame %d   timescale %.2f   hitstop %.0f ms", w.lastStepsPerFrame, w.timeScale, max(0, w.hitstopRemaining) * 1000))
        }
        lines.append("F2 hitboxes  F3 frame data  F4 AI  F5 freecam  F6 invincible \(dbg.invincible ? "ON" : "off")")
        lines.append("F7 slowmo \([1.0, 0.5, 0.25][dbg.slowmoLevel])x  F8 boss cheat  F9 reload  F10 dump  F11 kill  F12 shot")
        let h = Float(lines.count) * 20 * s + 20 * s
        d.rect(x - 10 * s, y - 10 * s, 460 * s, h, Vec4(0, 0, 0, 0.72), radius: 4 * s)
        var yy = y
        for l in lines { d.text(l, x, yy, size: 14 * s, Vec4(0.85, 0.95, 0.85, 1), font: .mono, shadow: false); yy += 20 * s }
        // Log tail.
        let log = Log.shared.recentLines().suffix(8)
        var ly = H - 30 * s - Float(log.count) * 18 * s
        d.rect(10 * s, ly - 8 * s, W * 0.55, Float(log.count) * 18 * s + 16 * s, Vec4(0, 0, 0, 0.6), radius: 4 * s)
        for l in log { d.text(String(l.prefix(140)), 20 * s, ly, size: 12 * s, Vec4(0.8, 0.8, 0.8, 1), font: .mono, shadow: false); ly += 18 * s }
    }

    mutating func timelineBar(_ label: String, x: Float, y: Float, w: Float, st: StrikeDef?, time: Double, speed: Double) {
        d.text(label, x, y - 18 * s, size: 13 * s, UIColors.text, font: .mono, shadow: false)
        guard let st = st else { d.rect(x, y, w, 10 * s, Vec4(0.2, 0.2, 0.2, 0.7)); return }
        let total = max(st.totalTime, 1e-3)
        let su = Float(st.startupTime / total), au = Float(st.activeTime / total)
        d.rect(x, y, w * su, 10 * s, Vec4(0.9, 0.8, 0.2, 0.85))
        if !st.feint { d.rect(x + w * su, y, w * au, 10 * s, Vec4(1, 0.2, 0.15, 0.95)) }
        d.rect(x + w * (su + au), y, w * max(0, 1 - su - au), 10 * s, Vec4(0.3, 0.5, 1, 0.8))
        let cur = Float(time / total)
        d.rect(x + w * saturatef(cur) - 1 * s, y - 3 * s, 2 * s, 16 * s, Vec4(1, 1, 1, 1))
        d.text(String(format: "f%.0f  startup %.0f%@ active %.0f recovery %.0f  %@", time * 60, st.startup, st.delay > 0 ? "+\(Int(st.delay))" as NSString : "" as NSString,
                      st.active, st.recovery, st.telegraph.rawValue as NSString), x, y + 14 * s, size: 12 * s, UIColors.dim, font: .mono, shadow: false)
    }

    mutating func frameData(_ app: GameApp, _ w: World) {
        let x: Float = 20 * s, y: Float = 150 * s, bw: Float = 420 * s
        d.rect(x - 10 * s, y - 40 * s, bw + 20 * s, 330 * s, Vec4(0, 0, 0, 0.72), radius: 4 * s)
        let p = w.player
        d.text("PLAYER \(p.state.rawValue) t=\(Int(p.stateTime * 1000))ms", x, y - 34 * s, size: 14 * s, UIColors.gold, font: .mono, shadow: false)
        timelineBar("move", x: x, y: y, w: bw, st: p.fighter.move?.strike, time: p.fighter.move?.strikeTime ?? 0, speed: 1)
        // Parry / dodge windows relative to now.
        let win = w.windows
        var yy = y + 60 * s
        if let tp = p.defense.parryPressTime {
            let e = w.now - tp
            d.text(String(format: "parry window %.0f/%.0f ms (perfect %.0f)", e * 1000, win.parry * 1000, win.perfectParry * 1000), x, yy - 16 * s, size: 12 * s, UIColors.text, font: .mono, shadow: false)
            d.rect(x, yy, bw, 8 * s, Vec4(0.2, 0.2, 0.2, 0.8))
            d.rect(x, yy, bw * Float(win.perfectParry / 0.3), 8 * s, Vec4(1, 0.85, 0.3, 0.9))
            d.rect(x + bw * Float(win.perfectParry / 0.3), yy, bw * Float((win.parry - win.perfectParry) / 0.3), 8 * s, Vec4(0.8, 0.8, 0.8, 0.8))
            d.rect(x + bw * saturatef(Float(e / 0.3)), yy - 3 * s, 2 * s, 14 * s, Vec4(1, 1, 1, 1))
        }
        yy += 36 * s
        if let ds = p.defense.dodgeStartTime {
            let e = w.now - ds
            d.text(String(format: "dodge %.0f ms (i-frames %.0f-%.0f, perfect <%.0f)", e * 1000, win.iframeStart * 1000, (win.iframeStart + win.iframes) * 1000,
                          win.perfectDodge * 1000), x, yy - 16 * s, size: 12 * s, UIColors.text, font: .mono, shadow: false)
            d.rect(x, yy, bw, 8 * s, Vec4(0.2, 0.2, 0.2, 0.8))
            d.rect(x + bw * Float(win.iframeStart / 0.5), yy, bw * Float(win.iframes / 0.5), 8 * s, Vec4(0.4, 0.7, 1, 0.9))
            d.rect(x + bw * saturatef(Float(e / 0.5)), yy - 3 * s, 2 * s, 14 * s, Vec4(1, 1, 1, 1))
        }
        yy += 34 * s
        if let b = w.bosses.first {
            timelineBar("BOSS \(b.state.rawValue): \(b.currentAttack?.name ?? "-")", x: x, y: yy, w: bw, st: b.fighter.move?.strike,
                        time: b.fighter.move?.strikeTime ?? 0, speed: b.fighter.move?.timeline.speed ?? 1)
            if let mv = b.fighter.move {
                d.text(String(format: "strike %d/%d  speed x%.2f  time-to-hit %.0f ms", mv.timeline.index + 1, mv.timeline.strikes.count, mv.timeline.speed,
                              max(0, mv.timeline.timeToActive / mv.timeline.speed) * 1000), x, yy + 30 * s, size: 12 * s, UIColors.dim, font: .mono, shadow: false)
            }
        }
        yy += 64 * s
        for (t, when) in w.defenseLog.suffix(4) {
            let a = saturatef(Float(8 - (w.realTime - when)) / 2)
            d.text(t, x, yy, size: 13 * s, Vec4(0.9, 0.95, 1, a), font: .mono, shadow: false)
            yy += 18 * s
        }
    }

    mutating func aiDebug(_ w: World) {
        let x = W - 470 * s
        var y = H * 0.45
        for b in w.bosses {
            let ai = b.ai
            var lines = ["\(b.def.name): \(b.state.rawValue) phase \(b.phase)/\(b.def.phases.count)",
                         "mode \(ai.mode.rawValue)  next attack in \(String(format: "%.2f", max(0, ai.nextAttackTime - w.now)))s",
                         "chosen: \(ai.lastChoice)",
                         String(format: "habits parry %.1f dodge %.1f  aggression %.2f  speed x%.2f", ai.habits.parry, ai.habits.dodge, b.aggression, b.speedMult)]
            for (n, wt) in ai.lastWeights.prefix(7) { lines.append(String(format: "  %5.2f  %@", wt, n as NSString)) }
            let h = Float(lines.count) * 18 * s + 16 * s
            d.rect(x - 10 * s, y - 8 * s, 460 * s, h, Vec4(0, 0, 0, 0.72), radius: 4 * s)
            for l in lines { d.text(l, x, y, size: 13 * s, Vec4(1, 0.85, 0.8, 1), font: .mono, shadow: false); y += 18 * s }
            y += 24 * s
        }
    }
}
