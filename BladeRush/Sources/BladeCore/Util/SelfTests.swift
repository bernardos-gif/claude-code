// Combat timing and systems checks. Run via XCTest (`swift test`) or, on machines with
// only the Command Line Tools (no XCTest), via `BladeSim selftest`.
import Foundation

public struct SelfTestResult {
    public var name: String
    public var failures: [String]
    public var passed: Bool { failures.isEmpty }
}

public enum SelfTests {
    public final class Checker {
        public var failures: [String] = []
        public init() {}
        func expect(_ cond: Bool, _ msg: @autoclosure () -> String, line: Int = #line) {
            if !cond { failures.append("line \(line): \(msg())") }
        }
        func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6, _ msg: String = "", line: Int = #line) {
            if abs(a - b) > eps { failures.append("line \(line): \(msg) expected \(b), got \(a)") }
        }
    }

    public static let all: [(String, (Checker) -> Void)] = [
        ("parryWindows", parryWindows),
        ("perfectParryBoundaries", perfectParryBoundaries),
        ("unblockables", unblockables),
        ("blockAfterWindow", blockAfterWindow),
        ("dodgeIFrames", dodgeIFrames),
        ("perfectDodge", perfectDodge),
        ("timingAssistAndHardMode", timingAssistAndHardMode),
        ("counterStance", counterStance),
        ("inputBuffer", inputBuffer),
        ("postureMath", postureMath),
        ("postureRecovery", postureRecovery),
        ("stamina", stamina),
        ("strikeTimeline", strikeTimeline),
        ("chainedTimeline", chainedTimeline),
        ("sweptHitboxes", sweptHitboxes),
        ("mathBasics", mathBasics),
        ("jsonDefaults", jsonDefaults),
    ]

    public static func runAll() -> [SelfTestResult] {
        all.map { (name, fn) in
            let c = Checker()
            fn(c)
            return SelfTestResult(name: name, failures: c.failures)
        }
    }

    static var windows: DefenseWindows { DefenseWindows.from(TimingTuning(), assist: 1, hardModeMult: 1) }

    static func parryWindows(_ c: Checker) {
        var st = DefenseState()
        st.parryPressTime = 10.0
        let w = windows
        c.near(w.parry, 0.150, 1e-9, "default parry window")
        c.near(w.perfectParry, 0.060, 1e-9, "default perfect window")
        c.expect(DefenseResolver.resolve(now: 10.0, telegraph: .white, isGrab: false, state: st, windows: w) == .parried(perfect: true), "hit at press = perfect")
        c.expect(DefenseResolver.resolve(now: 10.1, telegraph: .white, isGrab: false, state: st, windows: w) == .parried(perfect: false), "100ms = normal")
        c.expect(DefenseResolver.resolve(now: 10.2, telegraph: .white, isGrab: false, state: st, windows: w) == .hit, "200ms = too early -> hit")
        c.expect(DefenseResolver.resolve(now: 9.99, telegraph: .white, isGrab: false, state: st, windows: w) == .hit, "hit before press = too late")
        c.expect(DefenseResolver.classifyParry(lead: -0.01, windows: w) == "late", "late classification")
        c.expect(DefenseResolver.classifyParry(lead: 0.2, windows: w) == "early", "early classification")
    }

    static func perfectParryBoundaries(_ c: Checker) {
        var st = DefenseState()
        st.parryPressTime = 0
        let w = windows
        c.expect(DefenseResolver.resolve(now: 0.060, telegraph: .gold, isGrab: false, state: st, windows: w) == .parried(perfect: true), "60ms boundary is perfect")
        c.expect(DefenseResolver.resolve(now: 0.0605, telegraph: .gold, isGrab: false, state: st, windows: w) == .parried(perfect: false), "just past 60ms is normal")
        c.expect(DefenseResolver.resolve(now: 0.150, telegraph: .purple, isGrab: false, state: st, windows: w) == .parried(perfect: false), "150ms boundary still parries")
        c.expect(DefenseResolver.resolve(now: 0.1505, telegraph: .purple, isGrab: false, state: st, windows: w) == .hit, "past window = hit")
    }

    static func unblockables(_ c: Checker) {
        var st = DefenseState()
        st.parryPressTime = 0
        st.parryHeld = true
        let w = windows
        c.expect(DefenseResolver.resolve(now: 0.02, telegraph: .red, isGrab: false, state: st, windows: w) == .hit, "red cannot be parried")
        c.expect(DefenseResolver.resolve(now: 0.5, telegraph: .red, isGrab: false, state: st, windows: w) == .hit, "red cannot be blocked")
        c.expect(DefenseResolver.resolve(now: 0.02, telegraph: .white, isGrab: true, state: st, windows: w) == .hit, "grabs cannot be parried")
    }

    static func blockAfterWindow(_ c: Checker) {
        var st = DefenseState()
        st.parryPressTime = 0
        st.parryHeld = true
        let w = windows
        c.expect(DefenseResolver.resolve(now: 0.5, telegraph: .white, isGrab: false, state: st, windows: w) == .blocked, "held guard blocks")
        st.parryHeld = false
        c.expect(DefenseResolver.resolve(now: 0.5, telegraph: .white, isGrab: false, state: st, windows: w) == .hit, "released guard is hit")
        var held = DefenseState()
        held.parryHeld = true
        c.expect(DefenseResolver.resolve(now: 3, telegraph: .none, isGrab: false, state: held, windows: w) == .blocked, "guard without press time blocks")
    }

    static func dodgeIFrames(_ c: Checker) {
        var st = DefenseState()
        st.dodgeStartTime = 5.0
        let w = windows
        c.expect(DefenseResolver.resolve(now: 5.0, telegraph: .red, isGrab: false, state: st, windows: w) == .hit, "i-frames start after 15ms")
        c.expect(DefenseResolver.resolve(now: 5.05, telegraph: .red, isGrab: false, state: st, windows: w) == .dodged(perfect: true), "50ms into dodge = perfect")
        c.expect(DefenseResolver.resolve(now: 5.2, telegraph: .red, isGrab: false, state: st, windows: w) == .dodged(perfect: false), "200ms = still invulnerable")
        c.expect(DefenseResolver.resolve(now: 5.22, telegraph: .red, isGrab: false, state: st, windows: w) == .hit, "after i-frames = hit")
        c.expect(DefenseResolver.resolve(now: 5.1, telegraph: .red, isGrab: true, state: st, windows: w) == .dodged(perfect: true), "grabs are dodgeable")
    }

    static func perfectDodge(_ c: Checker) {
        var st = DefenseState()
        st.dodgeStartTime = 0
        let w = windows
        c.expect(DefenseResolver.resolve(now: 0.1, telegraph: .white, isGrab: false, state: st, windows: w) == .dodged(perfect: true), "100ms boundary perfect")
        c.expect(DefenseResolver.resolve(now: 0.11, telegraph: .white, isGrab: false, state: st, windows: w) == .dodged(perfect: false), "110ms not perfect")
        var inv = DefenseState()
        inv.invulnerableUntil = 1
        c.expect(DefenseResolver.resolve(now: 0.5, telegraph: .white, isGrab: false, state: inv, windows: w) == .ignored, "invulnerable ignores")
    }

    static func timingAssistAndHardMode(_ c: Checker) {
        let t = TimingTuning()
        let assisted = DefenseWindows.from(t, assist: 2, hardModeMult: 1)
        c.near(assisted.parry, 0.3, 1e-9, "assist doubles parry")
        c.near(assisted.perfectParry, 0.12, 1e-9, "assist doubles perfect")
        c.near(assisted.iframes, 0.4, 1e-9, "assist doubles i-frames")
        let hard = DefenseWindows.from(t, assist: 1, hardModeMult: 0.72)
        c.expect(hard.parry < t.parryWindow && hard.perfectParry < t.perfectParryWindow, "hard mode tightens windows")
        c.expect(hard.perfectParry <= hard.parry, "perfect never exceeds full window")
    }

    static func counterStance(_ c: Checker) {
        var st = DefenseState()
        st.counterStance = true
        c.expect(DefenseResolver.resolve(now: 1, telegraph: .red, isGrab: false, state: st, windows: windows) == .counter, "stance counters red")
        c.expect(DefenseResolver.resolve(now: 1, telegraph: .white, isGrab: true, state: st, windows: windows) == .hit, "stance does not counter grabs")
    }

    static func inputBuffer(_ c: Checker) {
        var b = InputBuffer(window: 0.15)
        b.push(.light, at: 1.0)
        c.expect(b.take(now: 1.05, allowed: { _ in false }) == nil, "not allowed yet: stays buffered")
        c.expect(b.peek(now: 1.1) == .light, "still pending")
        c.expect(b.take(now: 1.14, allowed: { _ in true }) == .light, "fires within window")
        c.expect(b.take(now: 1.14, allowed: { _ in true }) == nil, "consumed once")
        b.push(.dodge, at: 2.0)
        c.expect(b.take(now: 2.2, allowed: { _ in true }) == nil, "expired after 150ms")
        b.push(.light, at: 3.0)
        b.push(.parry, at: 3.05)
        c.expect(b.take(now: 3.1, allowed: { _ in true }) == .parry, "latest press wins")
    }

    static func postureMath(_ c: Checker) {
        let pt = PlayerTuning()
        c.near(Double(CombatMath.playerPostureDamage(outcome: .parried(perfect: true), attackPosture: 20, t: pt)), 0, 1e-6, "perfect parry costs no posture")
        c.near(Double(CombatMath.playerPostureDamage(outcome: .parried(perfect: false), attackPosture: 20, t: pt)), 7, 1e-4, "normal parry 35%")
        c.near(Double(CombatMath.playerPostureDamage(outcome: .blocked, attackPosture: 20, t: pt)), 20, 1e-4, "block full posture")
        c.near(Double(CombatMath.playerHealthDamage(outcome: .blocked, attackDamage: 50, t: pt)), 6, 1e-4, "block chip 12%")
        let bt = BossTuning()
        let normal = CombatMath.bossPostureFromParry(perfect: false, telegraph: .white, attackPosture: 10, weaponParryMult: 1, t: bt)
        let perfect = CombatMath.bossPostureFromParry(perfect: true, telegraph: .white, attackPosture: 10, weaponParryMult: 1, t: bt)
        let gold = CombatMath.bossPostureFromParry(perfect: true, telegraph: .gold, attackPosture: 10, weaponParryMult: 1, t: bt)
        c.expect(normal < perfect && perfect < gold, "parry posture ordering normal < perfect < gold")
        var m = PostureMeter(max: 100)
        c.expect(!m.add(60, now: 0), "no break at 60")
        c.expect(m.add(50, now: 0.1), "break on crossing max")
        c.expect(!m.add(10, now: 0.2), "already broken does not re-trigger")
        c.near(Double(m.value), 100, 1e-6, "clamped at max")
    }

    static func postureRecovery(_ c: Checker) {
        var m = PostureMeter(max: 100)
        _ = m.add(50, now: 0)
        m.recover(dt: 0.5, now: 0.5, delay: 1.0, rate: 20, healthFraction: 1)
        c.near(Double(m.value), 50, 1e-6, "no recovery during delay")
        m.recover(dt: 1.0, now: 2.0, delay: 1.0, rate: 20, healthFraction: 1)
        c.near(Double(m.value), 30, 1e-4, "recovers at full rate at full health")
        m.recover(dt: 1.0, now: 3.0, delay: 1.0, rate: 20, healthFraction: 0)
        c.near(Double(m.value), 23, 1e-4, "recovers slower when wounded")
    }

    static func stamina(_ c: Checker) {
        var s = StaminaMeter(max: 100)
        s.spend(30, now: 0)
        c.near(Double(s.value), 70, 1e-6, "spend")
        s.regen(dt: 0.2, now: 0.2, rate: 50, delay: 0.45)
        c.near(Double(s.value), 70, 1e-6, "no regen during delay")
        s.regen(dt: 0.5, now: 1.0, rate: 50, delay: 0.45)
        c.near(Double(s.value), 95, 1e-4, "regen after delay")
        s.spend(200, now: 2)
        c.expect(!s.canAct, "empty stamina blocks actions")
        s.regen(dt: 0.5, now: 2.5, rate: 50, delay: 0.45)
        c.near(Double(s.value), 0, 1e-6, "emptied bar waits longer")
    }

    static func strikeTimeline(_ c: Checker) {
        var s = StrikeDef()
        s.startup = 12; s.active = 6; s.recovery = 12
        var tl = StrikeTimeline(strikes: [s])
        var ev = tl.advance(0.1)
        c.expect(ev == [.strikeBegan(0)], "begins")
        c.expect(tl.phase == .startup, "startup at 0.1s")
        ev = tl.advance(0.15)
        c.expect(ev.contains(.activeBegan(0)), "active begins at 0.2s")
        c.expect(tl.phase == .active, "active at 0.25s")
        ev = tl.advance(0.1)
        c.expect(ev.contains(.activeEnded(0)), "active ends at 0.3s")
        ev = tl.advance(0.5)
        c.expect(ev.contains(.finished), "finishes")
        c.expect(tl.isDone, "done")
        var fast = StrikeTimeline(strikes: [s], speed: 2)
        _ = fast.advance(0.1)
        c.expect(fast.phase == .active, "speed 2 reaches active at 0.1s")
    }

    static func chainedTimeline(_ c: Checker) {
        var a = StrikeDef(); a.startup = 6; a.active = 6; a.recovery = 12
        var f = StrikeDef(); f.startup = 12; f.feint = true
        var tl = StrikeTimeline(strikes: [f, a, a])
        let ev = tl.advance(2.0)
        let began = ev.filter { if case .strikeBegan = $0 { return true }; return false }.count
        let actives = ev.filter { if case .activeBegan = $0 { return true }; return false }.count
        c.expect(began == 3, "three strikes began (got \(began))")
        c.expect(actives == 2, "feint has no active phase (got \(actives))")
        c.expect(ev.last == .finished, "finished last")
        // Chained strikes skip part of their recovery.
        let tl2 = StrikeTimeline(strikes: [a, a])
        c.expect(tl2.duration(0) < tl2.duration(1), "non-final strike recovery is shortened")
    }

    static func sweptHitboxes(_ c: Checker) {
        // A fast blade passing fully through a thin target between two steps must still hit.
        let from = Capsule(Vec3(-2, 1, 0), Vec3(-1, 1, 0), 0.03)
        let to = Capsule(Vec3(1, 1, 0), Vec3(2, 1, 0), 0.03)
        let target = Capsule(Vec3(0, 0, 0), Vec3(0, 2, 0), 0.05)
        c.expect(Geometry.capsuleOverlap(from, target) == nil && Geometry.capsuleOverlap(to, target) == nil, "no overlap at endpoints")
        let n = Geometry.sweepSubsteps(from: from, to: to, maxStep: 0.06)
        c.expect(Geometry.sweptCapsuleOverlap(from: from, to: to, target: target, substeps: n) != nil, "swept test catches tunneling")
        let (p, q) = Geometry.closestPointsSegments(Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0.5, 1, -1), Vec3(0.5, 1, 1))
        c.expect(vlength(p - Vec3(0.5, 0, 0)) < 1e-4 && vlength(q - Vec3(0.5, 1, 0)) < 1e-4, "segment closest points")
    }

    static func mathBasics(_ c: Checker) {
        let q = Quat(axis: Vec3(0, 1, 0), angle: kPi / 2)
        let v = q.rotate(Vec3(0, 0, 1))
        c.expect(vlength(v - Vec3(1, 0, 0)) < 1e-5, "yaw 90 maps +Z to +X")
        let m = Mat4.trs(Vec3(1, 2, 3), q, Vec3(2, 2, 2))
        let p = m.inverse.transformPoint(m.transformPoint(Vec3(0.3, -0.7, 1.1)))
        c.expect(vlength(p - Vec3(0.3, -0.7, 1.1)) < 1e-4, "matrix inverse round trip")
        c.near(Double(abs(wrapAngle(3 * kPi))), Double(kPi), 1e-5, "wrap angle")
        c.near(Double(wrapAngle(0.5 + kTwoPi)), 0.5, 1e-5, "wrap angle 2")
        let lr = Quat.lookRotation(forward: Vec3(0, 0, 1))
        c.expect(abs(lr.w) > 0.9999, "look rotation identity")
    }

    static func jsonDefaults(_ c: Checker) {
        let json = "// comment\n{ \"timing\": { \"parryWindow\": 0.2, }, }"
        do {
            let t = try JSONUtil.decodeMerged(CombatTuning.self, from: Data(json.utf8), defaults: CombatTuning())
            c.near(t.timing.parryWindow, 0.2, 1e-9, "override applied")
            c.near(t.timing.perfectParryWindow, 0.06, 1e-9, "missing keys keep defaults")
        } catch {
            c.expect(false, "decode failed: \(error)")
        }
        do {
            let s = try JSONUtil.decode(StrikeDef.self, from: Data("{\"damage\": 5}".utf8))
            c.expect(s.damage == 5 && s.startup == 18, "strike defaults")
        } catch {
            c.expect(false, "strike decode failed: \(error)")
        }
    }
}
